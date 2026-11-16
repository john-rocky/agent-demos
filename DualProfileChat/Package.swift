// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DualProfileChat",
    platforms: [.macOS("27.0")],
    dependencies: [
        // coreai-kit pulls in its patched coreai-models fork transitively, so a clean
        // external `swift run` resolves the whole chain. It uses an exact revision for
        // reproducibility.
        .package(
            url: "https://github.com/john-rocky/coreai-kit",
            revision: "d18bb42f169a553b8aae7d524966a25b301c3a8a"
        )
    ],
    targets: [
        .executableTarget(
            name: "DualProfileChat",
            dependencies: [.product(name: "CoreAIKit", package: "coreai-kit")]
        )
    ]
)
