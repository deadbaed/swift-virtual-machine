// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "swift-virtual-machine",
    platforms: [
        .macOS(.init("27.0"))
    ],
    products: [
        .executable(name: "swift-virtual-machine", targets: ["swift-virtual-machine"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "swift-virtual-machine",
            dependencies: [
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ],
            linkerSettings: [
                .linkedFramework("Virtualization")
            ]
        )
    ]
)
