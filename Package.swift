// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Apex5Connect",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Apex5Connect", targets: ["Apex5Connect"])
    ],
    targets: [
        .executableTarget(name: "Apex5Connect")
    ]
)
