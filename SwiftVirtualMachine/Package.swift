// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "swift-virtual-machine",
    platforms: [
        .macOS(.init("27.0"))
    ],
    targets: [
        .executableTarget(
            name: "swift-virtual-machine",
            linkerSettings: [
                .linkedFramework("Virtualization")
            ]
        )
    ]
)
