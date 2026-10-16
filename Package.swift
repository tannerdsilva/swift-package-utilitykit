// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-package-utilitykit",
    platforms: [.macOS(.v15)],
    products: [
        .plugin(name: "NormalizeSyntax", targets: ["NormalizeSyntaxPlugin"]),
        .plugin(name: "GitMetadataPlugin", targets: ["GitMetadataPlugin"]),
        .executable(name: "swift-package-tool", targets: ["swift-package-tool"]),
        .executable(name: "normalizer-tool", targets: ["normalizer-tool"]),
        .executable(name: "git-metadata-tool", targets: ["git-metadata-tool"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        // swift-syntax 603: the range swift-mcp's macro target pins; a 600
        // range cannot resolve alongside it.
        .package(url: "https://github.com/swiftlang/swift-syntax", from: "603.0.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"),
        // the MCP facade: one-shot stdin tool host + generated tool schemas +
        // the arc plugin manifest format. 2.1.2 is the release whose subprocess
        // transport follows the child's placement — which is what lets a plugin
        // host installed from this package be reached by the owner's single
        // group signal instead of escaping into a group of its own.
        .package(url: "https://github.com/tannerdsilva/swift-mcp.git", "2.1.2"..<"3.0.0"),
        // subprocess execution. SwiftSlash 6 makes process-group placement part
        // of the spawn contract; every spawn in this package goes through
        // SubprocessCore, which is a thin adapter over this.
        .package(url:"https://github.com/tannerdsilva/SwiftSlash.git", "6.0.0"..<"7.0.0"),
    ],
    targets: [
        // the one subprocess entry point for this package: swift-slash owns the
        // spawn, the concurrent stream drain, and the reap. plugins cannot link
        // it (SwiftPM forbids library deps in plugin targets), which is why the
        // two plugin adapters spawn directly.
        .target(
            name: "SubprocessCore",
            dependencies: [.product(name: "SwiftSlash", package: "SwiftSlash")]
        ),
        .target(name: "NormalizerCore"),
        .target(
            name: "BuildOutputParsing",
            // the pure text parser for `swift build`/`swift test` output,
            // extracted so it can be unit-tested (an executable target cannot
            // be imported by a test).  follows the package's established
            // pattern: NormalizerCore + normalizer-tool, GitMetadataCore +
            // git-metadata-tool.  BuildCommand.swift is the only other surface
            // that consumes it.
            dependencies: []
        ),
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
        // git provenance: a library with the probe/renderer logic, a thin tool
        // the plugin invokes, and the build tool plugin that wires them into a
        // target's build. see Plugins/GitMetadataPlugin for the design notes.
        .target(name: "GitMetadataCore", dependencies: ["SubprocessCore"]),
        .executableTarget(
            name: "git-metadata-tool",
            dependencies: [
                "GitMetadataCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .plugin(
            name: "GitMetadataPlugin",
            capability: .buildTool(),
            dependencies: ["git-metadata-tool"]
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
                "SubprocessCore",
                "BuildOutputParsing",
            ],
            // generates GitProvenance.swift, which AppVersion reads so
            // `--version` reports the commit the binary was built from
            plugins: [.plugin(name: "GitMetadataPlugin")]
        ),
        .testTarget(
            name: "NormalizerCoreTests",
            dependencies: ["NormalizerCore", "SubprocessCore"]
        ),
        .testTarget(
            name: "BuildOutputParsingTests",
            dependencies: ["BuildOutputParsing"],
            // golden capture lines are read from the source tree at runtime via
            // #filePath, so they are excluded from the compile step, not made
            // bundle resources.
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "SwiftPackageToolTests",
            dependencies: ["SubprocessCore"]
        ),
        .testTarget(
            name: "GitMetadataCoreTests",
            dependencies: ["GitMetadataCore", "SubprocessCore"]
        ),
    ]
)
