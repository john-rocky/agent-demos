// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DualProfileChat",
    platforms: [.macOS("27.0")],
    dependencies: [
        // coreai-kit pulls in its patched coreai-models fork transitively, so a clean
        // external `swift run` resolves the whole chain. Pinned to an exact revision for
        // reproducibility (coreai-kit is not tagged yet).
        .package(
            url: "https://github.com/john-rocky/coreai-kit",
            revision: "3a9520309d3e01d89c4a08ea35b0cdbbb08088bc"
        )
    ],
    targets: [
        .executableTarget(
            name: "DualProfileChat",
            dependencies: [.product(name: "CoreAIKit", package: "coreai-kit")]
        )
    ]
)
