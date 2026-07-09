// swift-tools-version: 6.0
import Foundation
import PackageDescription

let developerDirectories = [
    ProcessInfo.processInfo.environment["DEVELOPER_DIR"],
    "/Applications/Xcode.app/Contents/Developer",
    "/Library/Developer/CommandLineTools"
].compactMap { $0 }

let swiftTestingSupport = developerDirectories.compactMap { developerDirectory -> (frameworks: String, libraries: String)? in
    let frameworks = "\(developerDirectory)/Library/Developer/Frameworks"
    guard FileManager.default.fileExists(atPath: "\(frameworks)/Testing.framework") else { return nil }
    return (frameworks, "\(developerDirectory)/Library/Developer/usr/lib")
}.first

let swiftTestingSwiftSettings: [SwiftSetting] = swiftTestingSupport.map { support in
    [.unsafeFlags(["-F", support.frameworks], .when(platforms: [.macOS]))]
} ?? []

let swiftTestingLinkerSettings: [LinkerSetting] = swiftTestingSupport.map { support in
    [
        .unsafeFlags(
            [
                "-F", support.frameworks,
                "-Xlinker", "-rpath", "-Xlinker", support.frameworks,
                "-Xlinker", "-rpath", "-Xlinker", support.libraries
            ],
            .when(platforms: [.macOS])
        )
    ]
} ?? []

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
        ),
        .testTarget(
            name: "MoDictTests",
            dependencies: ["MoDict"],
            path: "Tests/MoDictTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ] + swiftTestingSwiftSettings,
            linkerSettings: swiftTestingLinkerSettings
        )
    ]
)
