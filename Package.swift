// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "AxisCopilot",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "AxisCopilot", targets: ["AxisCopilot"])],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.12.4")],
    targets: [
        .target(name: "CopilotCore"),
        .executableTarget(name: "AxisCopilot", dependencies: ["CopilotCore", .product(name: "FluidAudio", package: "FluidAudio")]),
        .executableTarget(name: "CoreChecks", dependencies: ["CopilotCore"], path: "Tests/CopilotCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
