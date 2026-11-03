// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "ChatGPTNavigator",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "ChatGPTNavigator", targets: ["ChatGPTNavigator"]),
    ],
    targets: [
        .executableTarget(
            name: "ChatGPTNavigator",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .testTarget(
            name: "ChatGPTNavigatorTests",
            dependencies: ["ChatGPTNavigator"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
