// swift-tools-version:5.10
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "TabDisplay",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CPrivate", path: "Sources/CPrivate"),
        .target(name: "CLibUSB", path: "Sources/CLibUSB"),
        .executableTarget(
            name: "TabDisplay",
            dependencies: ["CPrivate", "CLibUSB"],
            path: "Sources/TabDisplay",
            linkerSettings: [
                // libusb is LGPL: link the bundled dylib (Contents/Frameworks) so it stays replaceable.
                .unsafeFlags(["-L\(root)/Vendor/libusb", "-lusb-1.0", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
            ]
        ),
    ]
)
