// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "tabscreen",
    platforms: [.macOS(.v13)],
    targets: [
        // Declaraciones de la API privada CGVirtualDisplay (vive en CoreGraphics).
        .target(
            name: "CVirtualDisplay",
            path: "Sources/CVirtualDisplay",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        .executableTarget(
            name: "tabscreen",
            dependencies: ["CVirtualDisplay"],
            path: "Sources/tabscreen",
            resources: [.copy("Web")],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Network"),
            ]
        ),
    ]
)
