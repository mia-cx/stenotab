// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TabCompletionsEverywhere",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CompletionCore", targets: ["CompletionCore"]),
        .executable(name: "TabCompletionsEverywhere", targets: ["TabCompletionsEverywhere"])
    ],
    targets: [
        .target(name: "CompletionCore"),
        .executableTarget(
            name: "TabCompletionsEverywhere",
            dependencies: ["CompletionCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit")
            ]
        ),
        .testTarget(
            name: "CompletionCoreTests",
            dependencies: ["CompletionCore"]
        )
    ]
)
