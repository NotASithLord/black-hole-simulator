// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BlackHoleDesk",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "BlackHoleDesk", targets: ["BlackHoleDesk"])],
    targets: [
        .executableTarget(
            name: "BlackHoleDesk",
            linkerSettings: [.linkedFramework("SwiftUI"), .linkedFramework("MetalKit"), .linkedFramework("AppKit")]
        )
    ]
)
