// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "IPadReceiver",
    platforms: [
        .iOS(.v15),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "IPadReceiverCore",
            targets: ["IPadReceiverCore"]
        ),
        .executable(
            name: "IPadReceiverApp",
            targets: ["IPadReceiverApp"]
        ),
    ],
    targets: [
        .target(
            name: "IPadReceiverCore",
            linkerSettings: [
                .linkedFramework("AVFoundation", .when(platforms: [.iOS, .macOS])),
                .linkedFramework("CoreMedia", .when(platforms: [.iOS, .macOS])),
                .linkedFramework("Network", .when(platforms: [.iOS, .macOS])),
                .linkedFramework("VideoToolbox", .when(platforms: [.iOS, .macOS])),
            ]
        ),
        .executableTarget(
            name: "IPadReceiverApp",
            dependencies: ["IPadReceiverCore"],
            linkerSettings: [
                .linkedFramework("SwiftUI", .when(platforms: [.iOS])),
            ]
        ),
        .testTarget(
            name: "IPadReceiverCoreTests",
            dependencies: ["IPadReceiverCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
