// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "herdr-block-sleep",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "herdr-block-sleep", targets: ["herdr-block-sleep"]),
        .library(name: "HerdrBlockSleepCore", targets: ["HerdrBlockSleepCore"]),
    ],
    targets: [
        .target(name: "HerdrBlockSleepCore"),
        .executableTarget(
            name: "herdr-block-sleep",
            dependencies: ["HerdrBlockSleepCore"]
        ),
        .testTarget(
            name: "HerdrBlockSleepCoreTests",
            dependencies: ["HerdrBlockSleepCore"],
            path: "tests/HerdrBlockSleepCoreTests"
        ),
    ]
)
