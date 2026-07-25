// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "StenoTab",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "CompletionCore", targets: ["CompletionCore"]),
        .executable(name: "StenoTab", targets: ["StenoTab"])
    ],
    targets: [
        .target(
            name: "CompletionCore",
            resources: [
                .copy("Resources/Prompts")
            ]
        ),
        .executableTarget(
            name: "StenoTab",
            dependencies: ["CompletionCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision")
            ]
        ),
        .testTarget(
            name: "CompletionCoreTests",
            dependencies: ["CompletionCore"]
        )
    ]
)
