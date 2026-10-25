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
        // `MLX` turns on the Title model; without it Title compiles as a stub.
        .package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "4.1.0", traits: ["MLX"]),
    ],
    targets: [
        .executableTarget(
            name: "ATCStudio",
            dependencies: ["RestorationStation"],
            resources: [.copy("Resources/AppIcon.svg")]
        ),
        .target(
            name: "RestorationStation",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "DesertAnt", package: "desert-ant-core"),
                .product(name: "Clear", package: "desert-ant-core"),
                .product(name: "Voz", package: "desert-ant-core"),
                .product(name: "Who", package: "desert-ant-core"),
                .product(name: "Align", package: "desert-ant-core"),
                .product(name: "Uhm", package: "desert-ant-core"),
                .product(name: "Title", package: "desert-ant-core"),
            ]
        ),
        .testTarget(
            name: "RestorationStationTests",
            dependencies: ["RestorationStation"]
        ),
    ]
)
