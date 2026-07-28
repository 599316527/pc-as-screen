// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PCScreenSender",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "PCScreenKit",
            targets: ["PCScreenKit"]
        ),
        .executable(
            name: "PCScreenSender",
            targets: ["PCScreenSender"]
        ),
    ],
    targets: [
        .target(
            name: "PrivateVirtualDisplayShim",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .target(
            name: "PCScreenKit",
            dependencies: ["PrivateVirtualDisplayShim"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Network"),
                .linkedFramework("OSLog"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
            ]
        ),
        .executableTarget(
            name: "PCScreenSender",
            dependencies: ["PCScreenKit"]
        ),
        .testTarget(
            name: "PCScreenKitTests",
            dependencies: ["PCScreenKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
