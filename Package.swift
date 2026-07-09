// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MoDict",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MoDict", targets: ["MoDict"])
    ],
    dependencies: [
        // Pre-1.0 SDK: the ASR API changes between minor versions. Bump deliberately,
        // re-checking signatures against the checked-out sources (see Docs/ARCHITECTURE.md).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5")
    ],
    targets: [
        .executableTarget(
            name: "MoDict",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/MoDict",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
