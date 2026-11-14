// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "wisp-macos",
    platforms: [
        .macOS(.v14),
    ],
    // Only the app and its developer tools are products; the modules are internal layers.
    products: [
        .executable(name: "Wisp", targets: ["WispApp"]),
        .executable(name: "capture-smoke", targets: ["CaptureSmoke"]),
        .executable(name: "panel-snapshots", targets: ["PanelSnapshots"]),
    ],
    targets: [
        .target(
            name: "WispDomain",
            path: "Sources/WispDomain"
        ),
        .target(
            name: "WispApplication",
            dependencies: ["WispDomain"],
            path: "Sources/WispApplication"
        ),
        .target(
            name: "WispCapture",
            dependencies: ["WispDomain", "WispApplication"],
            path: "Sources/WispCapture"
        ),
        .target(
            name: "WispPersistence",
            dependencies: ["WispDomain", "WispApplication"],
            path: "Sources/WispPersistence"
        ),
        .target(
            name: "WispUI",
            dependencies: ["WispDomain", "WispApplication"],
            path: "Sources/WispUI"
        ),
        .executableTarget(
            name: "WispApp",
            dependencies: [
                "WispDomain",
                "WispApplication",
                "WispCapture",
                "WispPersistence",
                "WispUI",
            ],
            path: "Sources/WispApp"
        ),
        .executableTarget(
            name: "CaptureSmoke",
            dependencies: [
                "WispDomain",
                "WispApplication",
                "WispCapture",
                "WispPersistence",
            ],
            path: "Tools/CaptureSmoke"
        ),
        .executableTarget(
            name: "PanelSnapshots",
            dependencies: ["WispDomain", "WispApplication", "WispUI"],
            path: "Tools/PanelSnapshots"
        ),
        .testTarget(
            name: "WispDomainTests",
            dependencies: ["WispDomain"],
            path: "Tests/WispDomainTests"
        ),
        .testTarget(
            name: "WispApplicationTests",
            dependencies: ["WispApplication", "WispDomain"],
            path: "Tests/WispApplicationTests"
        ),
        .testTarget(
            name: "WispUITests",
            dependencies: ["WispUI", "WispApplication", "WispDomain"],
            path: "Tests/WispUITests"
        ),
        .testTarget(
            name: "WispCaptureTests",
            dependencies: ["WispCapture", "WispApplication", "WispDomain"],
            path: "Tests/WispCaptureTests"
        ),
        .testTarget(
            name: "WispPersistenceTests",
            dependencies: ["WispPersistence", "WispDomain", "WispApplication"],
            path: "Tests/WispPersistenceTests"
        ),
    ]
)
