// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ATCStudio",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ATCStudio", targets: ["ATCStudio"]),
        .library(name: "RestorationStation", targets: ["RestorationStation"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // Milestone 3 adds desert-ant-core (Clear, Voz, Who, Align, Uhm, Title).
    ],
    targets: [
        .executableTarget(
            name: "ATCStudio",
            dependencies: ["RestorationStation"]
        ),
        .target(
            name: "RestorationStation",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "RestorationStationTests",
            dependencies: ["RestorationStation"]
        ),
    ]
)
