// swift-tools-version: 6.2
import PackageDescription

// Rules and seams that need no hardware and no models. FluidAudio is not a dependency, so importing it here
// fails the build, and scripts/test.sh never compiles it.
let package = Package(
    name: "DictationCore",
    platforms: [.macOS("26.0")],
    products: [.library(name: "DictationCore", targets: ["DictationCore"])],
    targets: [
        .target(name: "DictationCore"),
        .testTarget(name: "DictationCoreTests", dependencies: ["DictationCore"]),
    ]
)
