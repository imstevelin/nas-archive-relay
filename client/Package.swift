// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "NASRelay", platforms: [.macOS(.v14)], products: [.executable(name: "NASRelay", targets: ["NASRelay"])], targets: [
    .target(name: "RelayCore"),
    .executableTarget(name: "NASRelay", dependencies: ["RelayCore"]),
    .testTarget(name: "RelayCoreTests", dependencies: ["RelayCore"], resources: [.copy("Fixtures")])
])
