// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FilterCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FilterCore", targets: ["FilterCore"])
    ],
    targets: [
        .target(name: "FilterCore"),
        .testTarget(name: "FilterCoreTests", dependencies: ["FilterCore"]),
    ]
)
