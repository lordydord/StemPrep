// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AbletonStemPrep",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "StemPrep", targets: ["StemPrepApp"])
    ],
    targets: [
        .executableTarget(
            name: "StemPrepApp",
            path: "Sources/StemPrepApp"
        ),
        .testTarget(
            name: "StemPrepAppTests",
            dependencies: ["StemPrepApp"],
            path: "Tests/StemPrepAppTests"
        )
    ]
)
