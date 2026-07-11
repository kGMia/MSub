// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MSub",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "MSub", targets: ["MSub"])
    ],
    targets: [
        .executableTarget(
            name: "MSub",
            path: "Sources/MSub",
            exclude: [
                "Media.xcassets"
            ],
            resources: [
                .process("Localizable.xcstrings"),
                .copy("ffmpeg")
            ]
        ),
        .testTarget(
            name: "MSubTests",
            dependencies: ["MSub"],
            path: "Tests/MSubTests"
        )
    ]
)
