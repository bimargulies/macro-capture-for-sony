// swift-tools-version:5.9
import PackageDescription
import Foundation

// Absolute path of this package, for linker flags (SwiftPM does not guarantee cwd).
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "Viewfinder",
    platforms: [.macOS(.v13)],
    targets: [
        // Objective-C++ shim around Sony's C++ Camera Remote SDK.
        .target(
            name: "CCameraShim",
            path: "Sources/CCameraShim",
            cxxSettings: [
                .headerSearchPath("../../sdk/app/CRSDK"),
                .unsafeFlags(["-std=c++17"]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(root)/sdk/external/crsdk", "-lCr_Core",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path",
                ]),
            ]
        ),
        // Pure Swift (no camera, no UI): marker ARW writer, ExifTool wrapper, delivery pipeline.
        .target(
            name: "CaptureCore",
            path: "Sources/CaptureCore"
        ),
        .executableTarget(
            name: "Viewfinder",
            dependencies: ["CCameraShim", "CaptureCore"],
            path: "Sources/Viewfinder"
        ),
        .testTarget(
            name: "CaptureCoreTests",
            dependencies: ["CaptureCore"],
            path: "Tests/CaptureCoreTests"
        ),
    ]
)
