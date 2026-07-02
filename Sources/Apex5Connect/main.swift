import AppKit
import IOKit.hid
import SwiftUI

private let exampleControllerAddress = "00:11:22:33:44:55"
private let legacyControllerAddressKey = "controllerAddress"
private let appSupportDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Apex5Connect", isDirectory: true)
private let configURL = appSupportDirectoryURL.appendingPathComponent("config.json")
private let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Apex5Connect.log")
private let popoverContentSize = NSSize(width: 420, height: 424)

@main
struct Apex5ConnectApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class ConnectionModel: ObservableObject {
    enum Operation {
        case reconnect
        case unregister
        case statusCheck
    }

    enum Phase {
        case idle
        case working
        case bluetoothOnly
        case connected
        case failed

        var title: String {
            switch self {
            case .idle: "待機中"
            case .working: "接続処理中"
            case .bluetoothOnly: "Bluetoothのみ接続"
            case .connected: "接続済み"
            case .failed: "接続失敗"
            }
        }
    }

    @Published var phase: Phase = .idle
    @Published var status = "APEX5をペアリングモードにしてから、ペアリングし直してください。"
    @Published var detail = "アプリは終了せず、メニューバーからいつでも実行できます。"
    @Published var isRunning = false
    @Published private(set) var currentOperation: Operation?
    @Published var controllerAddress: String {
        didSet {
            configStore.save(controllerAddress: Self.normalizedAddress(controllerAddress))
        }
    }
    var onPhaseChanged: ((Phase) -> Void)?

    private let runner = BlueutilRunner(logURL: logURL)
    private let configStore = ConfigStore(configURL: configURL)
    private var operationTask: Task<Void, Never>?

    init() {
        controllerAddress = Self.normalizedAddress(configStore.loadControllerAddress())
    }

    func reconnect() {
        guard !isRunning else { return }
        controllerAddress = Self.normalizedAddress(controllerAddress)
        guard isValidAddress else {
            phase = .failed
            status = "MACアドレスの形式が正しくありません。"
            detail = "例: \(exampleControllerAddress)"
            onPhaseChanged?(phase)
            return
        }

        isRunning = true
        currentOperation = .reconnect
        phase = .working
        onPhaseChanged?(phase)
        status = "Bluetooth状態を確認中..."
        detail = "APEX5側はペアリングモードのままにしてください。"

        operationTask = Task {
            do {
                try await runner.repairAndConnect(controllerAddress: controllerAddress) { message in
                    Task { @MainActor in
                        self.status = message
                    }
                }
                phase = .connected
                onPhaseChanged?(phase)
                status = "APEX5に接続しました。"
                detail = "次に切断したら、APEX5をペアリングモードにしてからもう一度実行してください。"
            } catch is CancellationError {
                phase = .idle
                onPhaseChanged?(phase)
                status = "接続処理を中止しました。"
                detail = "必要ならAPEX5をペアリングモードにしてから再実行してください。"
            } catch {
                phase = .failed
                onPhaseChanged?(phase)
                status = "接続できませんでした。"
                detail = error.localizedDescription
            }
            finishOperation()
        }
    }

    func unregister() {
        guard !isRunning else { return }
        controllerAddress = Self.normalizedAddress(controllerAddress)
        guard isValidAddress else {
            phase = .failed
            status = "MACアドレスの形式が正しくありません。"
            detail = "例: \(exampleControllerAddress)"
            onPhaseChanged?(phase)
            return
        }

        isRunning = true
        currentOperation = .unregister
        phase = .working
        onPhaseChanged?(phase)
        status = "Mac側の登録情報を削除中..."
        detail = "APEX5のBluetooth登録を解除しています。"

        operationTask = Task {
            do {
                try await runner.unregister(controllerAddress: controllerAddress) { message in
                    Task { @MainActor in
                        self.status = message
                    }
                }
                phase = .idle
                onPhaseChanged?(phase)
                status = "登録を解除しました。"
                detail = "APEX5を使うには、ペアリングモードにしてから再接続してください。"
            } catch is CancellationError {
                phase = .idle
                onPhaseChanged?(phase)
                status = "登録解除を中止しました。"
                detail = ""
            } catch {
                phase = .failed
                onPhaseChanged?(phase)
                status = "登録解除できませんでした。"
                detail = error.localizedDescription
            }
            finishOperation()
        }
    }

    func cancelConnection() {
        guard currentOperation == .reconnect else { return }
        status = "接続処理を中止しています..."
        detail = "実行中のblueutilコマンドを終了しています。"
        operationTask?.cancel()
    }

    func checkStatus() {
        guard !isRunning else { return }
        controllerAddress = Self.normalizedAddress(controllerAddress)
        guard isValidAddress else {
            phase = .failed
            status = "MACアドレスの形式が正しくありません。"
            detail = "例: \(exampleControllerAddress)"
            onPhaseChanged?(phase)
            return
        }

        isRunning = true
        currentOperation = .statusCheck
        phase = .working
        onPhaseChanged?(phase)
        status = "接続状態を確認中..."
        detail = ""

        operationTask = Task {
            do {
                let connectionStatus = try await runner.connectionStatus(controllerAddress: controllerAddress)
                phase = connectionStatus.phase
                onPhaseChanged?(phase)
                status = connectionStatus.status
                detail = connectionStatus.detail
            } catch {
                phase = .failed
                onPhaseChanged?(phase)
                status = "状態を確認できませんでした。"
                detail = error.localizedDescription
            }
            finishOperation()
        }
    }

    func openLog() {
        NSWorkspace.shared.open(logURL)
    }

    func refreshStatusInBackground() {
        guard !isRunning else { return }
        controllerAddress = Self.normalizedAddress(controllerAddress)
        guard isValidAddress else {
            phase = .failed
            onPhaseChanged?(phase)
            return
        }

        Task {
            do {
                let connectionStatus = try await runner.connectionStatus(controllerAddress: controllerAddress, logOutput: false)
                phase = connectionStatus.phase
                status = connectionStatus.status
                detail = connectionStatus.detail
            } catch {
                phase = .failed
                status = "状態を確認できませんでした。"
                detail = "Bluetooth権限、またはAPEX5のMACアドレスを確認してください。"
            }
            onPhaseChanged?(phase)
        }
    }

    var isValidAddress: Bool {
        Self.isValidAddress(controllerAddress)
    }

    var canCancelConnection: Bool {
        currentOperation == .reconnect
    }

    private func finishOperation() {
        isRunning = false
        currentOperation = nil
        operationTask = nil
    }

    private static func normalizedAddress(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func isValidAddress(_ address: String) -> Bool {
        let pattern = #"^[0-9A-F]{2}(:[0-9A-F]{2}){5}$"#
        return address.range(of: pattern, options: .regularExpression) != nil
    }
}

struct ContentView: View {
    @ObservedObject var model: ConnectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                statusDot
                VStack(alignment: .leading, spacing: 2) {
                    Text("APEX5 Connect")
                        .font(.headline)
                    Text(model.phase.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(model.status)
                    .font(.body)
                    .lineLimit(2)
                Text(model.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(height: 72, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 6) {
                Text("APEX5のMACアドレス")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(exampleControllerAddress, text: $model.controllerAddress)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                if !model.isValidAddress {
                    Text("XX:XX:XX:XX:XX:XX の形式で入力してください。")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .frame(height: 72, alignment: .topLeading)

            Button {
                model.reconnect()
            } label: {
                HStack {
                    if model.isRunning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "dot.radiowaves.left.and.right")
                    }
                    Text(model.isRunning ? "処理中..." : "登録削除してペアリング")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isRunning || !model.isValidAddress)

            HStack {
                Button {
                    model.unregister()
                } label: {
                    Label("登録解除", systemImage: "trash")
                }
                .disabled(model.isRunning || !model.isValidAddress)

                Button {
                    model.cancelConnection()
                } label: {
                    Label("接続処理を中止", systemImage: "xmark.circle")
                }
                .disabled(!model.canCancelConnection)
            }
            .buttonStyle(.bordered)

            HStack {
                Button {
                    model.checkStatus()
                } label: {
                    Label("確認", systemImage: "checkmark.circle")
                }
                .disabled(model.isRunning)

                Button {
                    model.openLog()
                } label: {
                    Label("ログ", systemImage: "doc.text.magnifyingglass")
                }

                Spacer()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("終了", systemImage: "power")
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(width: popoverContentSize.width, height: popoverContentSize.height, alignment: .topLeading)
    }

    @ViewBuilder
    private var statusDot: some View {
        let color: Color = switch model.phase {
        case .idle: .secondary
        case .working: .orange
        case .bluetoothOnly: .yellow
        case .connected: .green
        case .failed: .red
        }

        Circle()
            .fill(color)
            .frame(width: 12, height: 12)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = ConnectionModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var statusTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "A5"
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item
        model.onPhaseChanged = { [weak self] phase in
            self?.updateStatusItem(for: phase)
        }
        updateStatusItem(for: model.phase)

        popover.behavior = .transient
        popover.contentSize = popoverContentSize
        popover.contentViewController = NSHostingController(rootView: ContentView(model: model))
        popover.delegate = self

        appendLog("Apex5Connect launched")
        startStatusPolling()
        model.refreshStatusInBackground()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.refreshStatusInBackground()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func startStatusPolling() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.model.refreshStatusInBackground()
            }
        }
    }

    private func updateStatusItem(for phase: ConnectionModel.Phase) {
        guard let button = statusItem?.button else { return }

        let symbolName: String
        let tooltip: String
        switch phase {
        case .idle:
            symbolName = "gamecontroller"
            tooltip = "APEX5: 未接続"
        case .working:
            symbolName = "arrow.triangle.2.circlepath"
            tooltip = "APEX5: 処理中"
        case .bluetoothOnly:
            symbolName = "exclamationmark.triangle"
            tooltip = "APEX5: Bluetoothのみ接続"
        case .connected:
            symbolName = "gamecontroller.fill"
            tooltip = "APEX5: 接続済み"
        case .failed:
            symbolName = "exclamationmark.triangle"
            tooltip = "APEX5: 状態確認失敗"
        }

        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)
        button.toolTip = tooltip
    }
}

struct BlueutilRunner {
    let logURL: URL

    func repairAndConnect(controllerAddress: String, update: @escaping @Sendable (String) -> Void) async throws {
        appendLog("Repair flow started for \(maskedAddress(controllerAddress))")

        update("Bluetoothをオンにしています...")
        try await ensureBluetoothPoweredOn()

        update("既存接続を確認中...")
        switch try await connectionStatus(controllerAddress: controllerAddress) {
        case .hidBluetooth:
            appendLog("Controller is already available as Bluetooth HID.")
            update("APEX5はゲームコントローラーとして接続済みです。")
            return
        case .bluetoothOnly:
            appendLog("Bluetooth link exists but HID controller is missing. Disconnecting stale link.")
            update("Bluetoothのみ接続の状態を解除中...")
            _ = try? await runBlueutil(["--disconnect", controllerAddress], timeout: 8)
            try await Task.sleep(for: .seconds(2))
        case .disconnected:
            break
        }

        update("通常接続を試行中...")
        do {
            _ = try await runBlueutil(["--connect", controllerAddress], timeout: 12)
            if try await waitForControllerReady(controllerAddress: controllerAddress, timeout: 6) {
                appendLog("Controller connected without unpairing")
                return
            }
        } catch {
            appendLog("Initial connect failed: \(error.localizedDescription)")
        }

        update("Mac側の登録情報を削除中...")
        do {
            _ = try await runBlueutil(["--unpair", controllerAddress])
        } catch {
            appendLog("Unpair failed or pair did not exist: \(error.localizedDescription)")
        }

        try await Task.sleep(for: .seconds(3))

        update("APEX5を新規ペアリング中...")
        for attempt in 1...5 {
            appendLog("Pair/connect attempt \(attempt)/5")
            update("APEX5を検出中... \(attempt)/5")
            do {
                appendLog("blueutil --inquiry 4")
                _ = try await runBlueutil(["--inquiry", "4"], timeout: 8, logOutput: false)
            } catch {
                appendLog("Inquiry failed: \(error.localizedDescription)")
            }

            do {
                update("APEX5を新規ペアリング中... \(attempt)/5")
                _ = try await runBlueutil(["--pair", controllerAddress], timeout: 25)
            } catch {
                appendLog("Pair command failed: \(error.localizedDescription)")
            }

            try await Task.sleep(for: .seconds(1))

            do {
                update("APEX5へ接続中... \(attempt)/5")
                _ = try await runBlueutil(["--connect", controllerAddress], timeout: 12)
            } catch {
                appendLog("Connect command failed: \(error.localizedDescription)")
            }

            do {
                _ = try await runBlueutil(["--wait-connect", controllerAddress, "6"], timeout: 8)
            } catch {
                appendLog("Wait-connect failed: \(error.localizedDescription)")
            }

            if try await waitForControllerReady(controllerAddress: controllerAddress, timeout: 6) {
                appendLog("Controller connected")
                return
            }

            if try await isConnected(controllerAddress: controllerAddress) {
                appendLog("Bluetooth connected but HID controller is still missing")
                _ = try? await runBlueutil(["--disconnect", controllerAddress], timeout: 8)
                try await Task.sleep(for: .seconds(2))
            }
        }

        appendLog("Connection failed")
        throw AppError.connectionFailed(logURL.path)
    }

    func unregister(controllerAddress: String, update: @escaping @Sendable (String) -> Void) async throws {
        appendLog("Unregister flow started for \(maskedAddress(controllerAddress))")

        update("Bluetooth接続を解除中...")
        _ = try? await runBlueutil(["--disconnect", controllerAddress], timeout: 8)
        try Task.checkCancellation()

        update("Mac側の登録情報を削除中...")
        _ = try await runBlueutil(["--unpair", controllerAddress])

        appendLog("Unregister flow finished")
    }

    func isConnected(controllerAddress: String, logOutput: Bool = true) async throws -> Bool {
        let output = try await runBlueutil(["--is-connected", controllerAddress], logOutput: logOutput).trimmingCharacters(in: .whitespacesAndNewlines)
        return output == "1"
    }

    func connectionStatus(controllerAddress: String, logOutput: Bool = true) async throws -> ControllerConnectionStatus {
        let hidConnected = HIDControllerDetector.isBluetoothControllerConnected(address: controllerAddress)
        if hidConnected {
            if logOutput {
                appendLog("IOHID Bluetooth controller matched \(maskedAddress(controllerAddress))")
            }
            return .hidBluetooth
        }

        do {
            if try await isConnected(controllerAddress: controllerAddress, logOutput: logOutput) {
                if logOutput {
                    appendLog("Bluetooth connected but IOHID controller did not match \(maskedAddress(controllerAddress))")
                }
                return .bluetoothOnly
            }
        } catch {
            throw error
        }

        return .disconnected
    }

    private func waitForControllerReady(controllerAddress: String, timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if try await connectionStatus(controllerAddress: controllerAddress, logOutput: false).isControllerReady {
                return true
            }
            try await Task.sleep(for: .milliseconds(500))
        } while Date() < deadline

        return false
    }

    private func ensureBluetoothPoweredOn() async throws {
        let power = try await runBlueutil(["-p"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if power == "0" {
            _ = try await runBlueutil(["-p", "1"])
            try await Task.sleep(for: .seconds(1))
        }
    }

    private func runBlueutil(_ arguments: [String], timeout: TimeInterval = 8, logOutput: Bool = true) async throws -> String {
        let executable = try blueutilURL()
        if logOutput {
            appendLog("blueutil \(redactedArguments(arguments).joined(separator: " "))")
        }

        let processBox = RunningProcessBox()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                let pipe = Pipe()
                let completion = ProcessCompletion(continuation)

                process.executableURL = executable
                process.arguments = arguments
                process.standardOutput = pipe
                process.standardError = pipe
                process.terminationHandler = { process in
                    processBox.clear(process)
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    if logOutput {
                        appendLog(output.trimmingCharacters(in: .whitespacesAndNewlines))
                    }

                    if process.terminationStatus == 0 {
                        completion.finish(.success(output))
                    } else if processBox.isCancelled {
                        completion.finish(.failure(CancellationError()))
                    } else {
                        completion.finish(.failure(AppError.commandFailed(output.isEmpty ? "blueutil failed" : output)))
                    }
                }

                do {
                    try process.run()
                    processBox.set(process)
                    if processBox.isCancelled, process.isRunning {
                        process.terminate()
                    }
                    let workItem = DispatchWorkItem {
                        if process.isRunning {
                            process.terminate()
                        }
                        completion.finish(.failure(AppError.commandTimedOut(redactedArguments(arguments).joined(separator: " "))))
                    }
                    completion.setTimeoutWorkItem(workItem)
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: workItem)
                } catch {
                    completion.finish(.failure(error))
                }
            }
        } onCancel: {
            processBox.terminate()
        }
    }

    private func blueutilURL() throws -> URL {
        let fileManager = FileManager.default
        var candidates: [URL] = []

        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(executableDirectory.appendingPathComponent("blueutil"))
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/blueutil"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/blueutil"))

        if let url = candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
            return url
        }

        throw AppError.missingBlueutil
    }
}

final class RunningProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var wasCancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wasCancelled
    }

    func set(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func clear(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        wasCancelled = true
        let process = process
        lock.unlock()

        if process?.isRunning == true {
            process?.terminate()
        }
    }
}

enum ControllerConnectionStatus {
    case disconnected
    case bluetoothOnly
    case hidBluetooth

    var isControllerReady: Bool {
        switch self {
        case .hidBluetooth:
            true
        case .disconnected, .bluetoothOnly:
            false
        }
    }

    var phase: ConnectionModel.Phase {
        switch self {
        case .disconnected:
            .idle
        case .bluetoothOnly:
            .bluetoothOnly
        case .hidBluetooth:
            .connected
        }
    }

    var status: String {
        switch self {
        case .disconnected:
            "APEX5は未接続です。"
        case .bluetoothOnly:
            "APEX5はBluetoothのみ接続されています。"
        case .hidBluetooth:
            "APEX5は接続済みです。"
        }
    }

    var detail: String {
        switch self {
        case .disconnected:
            "APEX5をペアリングモードにしてからペアリングし直してください。"
        case .bluetoothOnly:
            "ゲームコントローラーとして認識されていません。APEX5をペアリングモードにしてから修復を実行してください。"
        case .hidBluetooth:
            "Bluetooth HID入力として認識されています。"
        }
    }
}

struct HIDControllerDetector {
    static func isBluetoothControllerConnected(address: String) -> Bool {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matchingDictionaries: [[String: Int]] = [
            [
                kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey as String: kHIDUsage_GD_GamePad
            ],
            [
                kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Joystick
            ],
            [
                kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey as String: kHIDUsage_GD_MultiAxisController
            ]
        ]

        IOHIDManagerSetDeviceMatchingMultiple(manager, matchingDictionaries as CFArray)
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            appendLog("IOHIDManagerOpen failed: \(openResult)")
            return false
        }
        defer {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return false
        }

        let normalizedTarget = normalizedAddress(address)
        return devices.contains { device in
            let transport = propertyString(kIOHIDTransportKey, for: device)
            let serialNumber = propertyString(kIOHIDSerialNumberKey, for: device)
            return transport == "Bluetooth" && normalizedAddress(serialNumber ?? "") == normalizedTarget
        }
    }

    private static func propertyString(_ key: String, for device: IOHIDDevice) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private static func normalizedAddress(_ address: String) -> String {
        address
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: ":")
            .uppercased()
    }
}

struct AppConfig: Codable {
    var controllerAddress: String
}

struct ConfigStore {
    let configURL: URL

    func loadControllerAddress() -> String {
        if let data = try? Data(contentsOf: configURL),
           let config = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return config.controllerAddress
        }

        if let legacyAddress = UserDefaults.standard.string(forKey: legacyControllerAddressKey),
           !legacyAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            save(controllerAddress: legacyAddress)
            UserDefaults.standard.removeObject(forKey: legacyControllerAddressKey)
            return legacyAddress
        }

        return ""
    }

    func save(controllerAddress: String) {
        do {
            try FileManager.default.createDirectory(at: appSupportDirectoryURL, withIntermediateDirectories: true)
            let config = AppConfig(controllerAddress: controllerAddress)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: configURL, options: .atomic)
        } catch {
            appendLog("Failed to save config: \(error.localizedDescription)")
        }
    }
}

final class ProcessCompletion: @unchecked Sendable {
    private let continuation: CheckedContinuation<String, Error>
    private let lock = NSLock()
    private var didFinish = false
    private var timeoutWorkItem: DispatchWorkItem?

    init(_ continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func setTimeoutWorkItem(_ workItem: DispatchWorkItem) {
        lock.lock()
        timeoutWorkItem = workItem
        lock.unlock()
    }

    func finish(_ result: Result<String, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else { return }
        didFinish = true
        timeoutWorkItem?.cancel()

        switch result {
        case .success(let output):
            continuation.resume(returning: output)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

enum AppError: LocalizedError {
    case missingBlueutil
    case commandFailed(String)
    case commandTimedOut(String)
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingBlueutil:
            "blueutilが見つかりません。アプリ内、/opt/homebrew/bin、/usr/local/binのいずれかに配置してください。"
        case .commandFailed(let message):
            message
        case .commandTimedOut(let command):
            "blueutil \(command) がタイムアウトしました。"
        case .connectionFailed(let path):
            "APEX5がペアリングモードか確認してください。ログ: \(path)"
        }
    }
}

private func appendLog(_ message: String) {
    let line = "[\(Date())] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }

    if !FileManager.default.fileExists(atPath: logURL.path) {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
    }

    if let handle = try? FileHandle(forWritingTo: logURL) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.close()
    }
}

private func redactedArguments(_ arguments: [String]) -> [String] {
    arguments.map { isBluetoothAddress($0) ? maskedAddress($0) : $0 }
}

private func maskedAddress(_ address: String) -> String {
    let parts = address.split(separator: ":")
    guard parts.count == 6 else { return "<address>" }
    return "\(parts[0]):\(parts[1]):**:**:**:\(parts[5])"
}

private func isBluetoothAddress(_ value: String) -> Bool {
    value.range(of: #"^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$"#, options: .regularExpression) != nil
}
