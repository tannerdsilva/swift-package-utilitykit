// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-package-utilitykit",
    platforms: [.macOS(.v13)],
    products: [
        .plugin(name: "NormalizeSyntax", targets: ["NormalizeSyntaxPlugin"]),
        .executable(name: "swift-code-query", targets: ["swift-code-query"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax", from: "600.0.0"),
    ],
    targets: [
        .target(name: "Examples"),
        .target(name: "NormalizerCore"),
        .executableTarget(
            name: "normalizer-tool",
            dependencies: ["NormalizerCore"]
        ),
        .plugin(
            name: "NormalizeSyntaxPlugin",
            capability: .command(
                intent: .custom(
                    verb: "normalize-syntax",
                    description: "Normalizes file syntax across the package's source files."
                ),
                permissions: [
                    .writeToPackageDirectory(
                        reason: "Rewrites source files in place to normalize their syntax."
                    )
                ]
            ),
            dependencies: ["normalizer-tool"]
        ),
        .executableTarget(
            name: "swift-code-query",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                "NormalizerCore",
            ]
        ),
        .testTarget(
            name: "NormalizerCoreTests",
            dependencies: ["NormalizerCore"]
        ),
    ]
)
