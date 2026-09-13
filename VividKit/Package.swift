// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
import PackageDescription

let package = Package(
    name: "VividKit",
    platforms: [.iOS(.v18), .tvOS("26.0")],
    products: [.library(name: "VividKit", targets: ["VividKit"])],
    dependencies: [
        .package(url: "https://github.com/superuser404notfound/FFmpegBuild",
                 revision: "4e58942403d37cceff3a3212e3e026f4205146a2")
    ],
    targets: [
        .binaryTarget(name: "libass", path: "Vendor/libass.xcframework"),
        .binaryTarget(name: "libfreetype", path: "Vendor/libfreetype.xcframework"),
        .binaryTarget(name: "libfribidi", path: "Vendor/libfribidi.xcframework"),
        .binaryTarget(name: "libharfbuzz", path: "Vendor/libharfbuzz.xcframework"),
        .target(name: "CVividMedia", dependencies: [
            .product(name: "AetherFFmpegBuild", package: "FFmpegBuild"),
            "libass", "libfreetype", "libfribidi", "libharfbuzz"
        ], linkerSettings: [
            .linkedFramework("VideoToolbox"), .linkedFramework("CoreVideo"),
            .linkedFramework("CoreMedia"), .linkedFramework("AudioToolbox"),
            .linkedFramework("CoreText"), .linkedLibrary("z"), .linkedLibrary("bz2"), .linkedLibrary("iconv")
        ]),
        .target(name: "VividKit", dependencies: ["CVividMedia"]),
        .testTarget(name: "VividKitTests", dependencies: ["VividKit"])
    ],
    swiftLanguageModes: [.v5]
)
