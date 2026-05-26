import AppKit
import SwiftUI

private let exampleControllerAddress = "00:11:22:33:44:55"
private let legacyControllerAddressKey = "controllerAddress"
private let appSupportDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Apex5Connect", isDirectory: true)
private let configURL = appSupportDirectoryURL.appendingPathComponent("config.json")
private let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Apex5Connect.log")

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
    enum Phase {
        case idle
        case working
        case connected
        case failed

        var title: String {
            switch self {
            case .idle: "待機中"
            case .working: "接続処理中"
            case .connected: "接続済み"
            case .failed: "接続失敗"
            }
        }
    }

    @Published var phase: Phase = .idle
    @Published var status = "APEX5をペアリングモードにしてから、ペアリングし直してください。"
    @Published var detail = "アプリは終了せず、メニューバーからいつでも実行できます。"
    @Published var isRunning = false
    @Published var controllerAddress: String {
        didSet {
            configStore.save(controllerAddress: Self.normalizedAddress(controllerAddress))
        }
    }
    var onPhaseChanged: ((Phase) -> Void)?

    private let runner = BlueutilRunner(logURL: logURL)
    private let configStore = ConfigStore(configURL: configURL)

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
        phase = .working
        onPhaseChanged?(phase)
        status = "Bluetooth状態を確認中..."
        detail = "APEX5側はペアリングモードのままにしてください。"

        Task {
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
            } catch {
                phase = .failed
                onPhaseChanged?(phase)
                status = "接続できませんでした。"
                detail = error.localizedDescription
            }
            isRunning = false
        }
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
        phase = .working
        onPhaseChanged?(phase)
        status = "接続状態を確認中..."
        detail = ""

        Task {
            do {
                let connected = try await runner.isConnected(controllerAddress: controllerAddress)
                phase = connected ? .connected : .idle
                onPhaseChanged?(phase)
                status = connected ? "APEX5は接続済みです。" : "APEX5は未接続です。"
                detail = connected ? "切断問題が出た場合は、登録削除からペアリングし直してください。" : "APEX5をペアリングモードにしてからペアリングし直してください。"
            } catch {
                phase = .failed
                onPhaseChanged?(phase)
                status = "状態を確認できませんでした。"
                detail = error.localizedDescription
            }
            isRunning = false
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
                let connected = try await runner.isConnected(controllerAddress: controllerAddress, logOutput: false)
                phase = connected ? .connected : .idle
                status = connected ? "APEX5は接続済みです。" : "APEX5は未接続です。"
                detail = connected ? "接続状態は自動確認されています。" : "APEX5をペアリングモードにしてからペアリングし直してください。"
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
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 58, alignment: .topLeading)

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
        .padding(18)
        .frame(width: 360)
    }

    @ViewBuilder
    private var statusDot: some View {
        let color: Color = switch model.phase {
        case .idle: .secondary
        case .working: .orange
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
        popover.contentSize = NSSize(width: 360, height: 340)
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
        if try await isConnected(controllerAddress: controllerAddress) {
            appendLog("Already connected. Disconnecting first.")
            update("既存接続を切断中...")
            _ = try await runBlueutil(["--disconnect", controllerAddress])
            try await Task.sleep(for: .seconds(1))
        }

        update("Mac側の登録情報を削除中...")
        do {
            _ = try await runBlueutil(["--unpair", controllerAddress])
        } catch {
            appendLog("Unpair failed or pair did not exist: \(error.localizedDescription)")
        }

        try await Task.sleep(for: .seconds(1))

        update("APEX5を新規ペアリング中...")
        for attempt in 1...5 {
            appendLog("Pair/connect attempt \(attempt)/5")
            do {
                _ = try await runBlueutil(["--pair", controllerAddress], timeout: 12)
            } catch {
                appendLog("Pair command failed: \(error.localizedDescription)")
            }

            try await Task.sleep(for: .seconds(1))

            do {
                _ = try await runBlueutil(["--connect", controllerAddress], timeout: 8)
            } catch {
                appendLog("Connect command failed: \(error.localizedDescription)")
            }

            try await Task.sleep(for: .seconds(2))
            if try await isConnected(controllerAddress: controllerAddress) {
                appendLog("Connected")
                return
            }

            update("APEX5を新規ペアリング中... \(attempt)/5")
        }

        appendLog("Connection failed")
        throw AppError.connectionFailed(logURL.path)
    }

    func isConnected(controllerAddress: String, logOutput: Bool = true) async throws -> Bool {
        let output = try await runBlueutil(["--is-connected", controllerAddress], logOutput: logOutput).trimmingCharacters(in: .whitespacesAndNewlines)
        return output == "1"
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

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            let completion = ProcessCompletion(continuation)

            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                if logOutput {
                    appendLog(output.trimmingCharacters(in: .whitespacesAndNewlines))
                }

                if process.terminationStatus == 0 {
                    completion.finish(.success(output))
                } else {
                    completion.finish(.failure(AppError.commandFailed(output.isEmpty ? "blueutil failed" : output)))
                }
            }

            do {
                try process.run()
                let workItem = DispatchWorkItem {
                    if process.isRunning {
                        process.terminate()
                    }
                    completion.finish(.failure(AppError.commandTimedOut(arguments.joined(separator: " "))))
                }
                completion.setTimeoutWorkItem(workItem)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: workItem)
            } catch {
                completion.finish(.failure(error))
            }
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
