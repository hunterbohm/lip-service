// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Dictation",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(path: "DictationCore"),
        .package(path: "Vendor/FluidAudio", traits: []),
    ],
    targets: [
        .executableTarget(
            name: "Dictation",
            dependencies: ["DictationCore", .product(name: "FluidAudio", package: "FluidAudio")]
        ),
    ]
)
