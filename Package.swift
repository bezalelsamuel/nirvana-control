// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BoatMenuBar",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "BoatMenuBar",
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("Cocoa")
            ]
        )
    ]
)
