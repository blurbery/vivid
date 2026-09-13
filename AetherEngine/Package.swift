// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AetherEngine",
    platforms: [.iOS(.v18), .tvOS("26.0")],
    products: [.library(name: "AetherEngine", targets: ["AetherEngine"])],
    dependencies: [
        .package(url: "https://github.com/superuser404notfound/FFmpegBuild",
                 revision: "4e58942403d37cceff3a3212e3e026f4205146a2"),
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
