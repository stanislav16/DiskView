// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskView",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "DiskView",
            path: "Sources/DiskView",
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
        )
    ],
    swiftLanguageModes: [.v5]
)
