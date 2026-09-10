// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AetherEngine",
    platforms: [.iOS(.v18), .tvOS("26.0")],
    products: [.library(name: "AetherEngine", targets: ["AetherEngine"])],
    dependencies: [
        .package(url: "https://github.com/superuser404notfound/FFmpegBuild",
                 revision: "421e13be7061de67d91b85ac34a6b22a002b164f"),
        .package(url: "https://github.com/superuser404notfound/LibDovi", exact: "2.1.0")
    ],
    targets: [
        .target(name: "AetherEngine", dependencies: [
            .product(name: "AetherFFmpegBuild", package: "FFmpegBuild"),
            .product(name: "Dovi", package: "LibDovi")
        ], linkerSettings: [
            .linkedFramework("AVFoundation"), .linkedFramework("AVKit"),
            .linkedFramework("CoreMedia"), .linkedFramework("CoreVideo"),
            .linkedFramework("VideoToolbox"), .linkedFramework("AudioToolbox")
        ])
    ]
)
