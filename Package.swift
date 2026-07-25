// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "StenoTab",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "CompletionCore", targets: ["CompletionCore"]),
        .executable(name: "StenoTab", targets: ["StenoTab"]),
        .executable(
            name: "PersonalizationBenchmark",
            targets: ["PersonalizationBenchmark"]
        )
    ],
    targets: [
        .target(
            name: "CompletionCore",
            resources: [
                .copy("Resources/Prompts")
            ]
        ),
        .target(
            name: "StenoTabPersistence",
            dependencies: ["CompletionCore"],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "StenoTab",
            dependencies: ["CompletionCore", "StenoTabPersistence"],
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
        .executableTarget(
            name: "PersonalizationBenchmark",
            dependencies: ["CompletionCore"],
            path: "Benchmarks/PersonalizationBenchmark",
            linkerSettings: [
                .linkedFramework("NaturalLanguage")
            ]
        ),
        .testTarget(
            name: "CompletionCoreTests",
            dependencies: ["CompletionCore"]
        ),
        .testTarget(
            name: "StenoTabPersistenceTests",
            dependencies: ["CompletionCore", "StenoTabPersistence"]
        ),
        .testTarget(
            name: "StenoTabTests",
            dependencies: [
                "CompletionCore",
                "StenoTab",
                "StenoTabPersistence",
            ]
        )
    ]
)
