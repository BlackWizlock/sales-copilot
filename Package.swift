// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "AxisCopilot",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "AxisCopilot", targets: ["AxisCopilot"])],
    targets: [
        .target(name: "CopilotCore"),
        .executableTarget(name: "AxisCopilot", dependencies: ["CopilotCore"]),
        .executableTarget(name: "CoreChecks", dependencies: ["CopilotCore"], path: "Tests/CopilotCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
