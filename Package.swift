// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BlackHoleDesk",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "BlackHoleDesk", targets: ["BlackHoleDesk"])],
    targets: [
        .target(name: "BlackHolePhysics"),
        .executableTarget(
            name: "BlackHoleDesk",
            dependencies: ["BlackHolePhysics"],
            linkerSettings: [.linkedFramework("SwiftUI"), .linkedFramework("MetalKit"), .linkedFramework("AppKit")]
        )
    ]
)
