// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MSub",
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .executable(name: "MSub", targets: ["MSub"])
    ],
    dependencies: [
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "bf14ae0c26e4e85553dd989571cae29d70fa6735")
    ],
    targets: [
        .executableTarget(
            name: "MSub",
            dependencies: [.product(name: "MLXAudioSTT", package: "mlx-audio-swift")],
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
