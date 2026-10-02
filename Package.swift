// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-package-utilitykit",
    platforms: [.macOS(.v15)],
    products: [
        .plugin(name: "NormalizeSyntax", targets: ["NormalizeSyntaxPlugin"]),
        .executable(name: "swift-package-tool", targets: ["swift-package-tool"]),
        .executable(name: "normalizer-tool", targets: ["normalizer-tool"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        // swift-syntax 603: the range swift-mcp's macro target pins; a 600
        // range cannot resolve alongside it.
        .package(url: "https://github.com/swiftlang/swift-syntax", from: "603.0.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"),
        // the MCP facade: one-shot stdin tool host + generated tool schemas +
        // the arc plugin manifest format. path pin while co-developing; the
        // URL/version pin replaces it when swift-mcp tags.
        .package(path: "../swift-mcp"),
    ],
    targets: [
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
            name: "swift-package-tool",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "MCP", package: "swift-mcp"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftParserDiagnostics", package: "swift-syntax"),
                "NormalizerCore",
            ]
        ),
        .testTarget(
            name: "NormalizerCoreTests",
            dependencies: ["NormalizerCore"]
        ),
        .testTarget(
            name: "SwiftPackageToolTests",
            dependencies: []
        ),
    ]
)
