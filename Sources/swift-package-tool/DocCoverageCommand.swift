//===----------------------------------------------------------------------===//
//
// swift-package-utilitykit
//
// Copyright (c) 2024 and the swift-package-utilitykit project authors
// Licensed under the MIT License
//
// See LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParser

/// inventory a package's DocC catalogs and measure doc-comment coverage.
///
/// ports the package-inspector's `docc_check` into the CLI: it walks for
/// `*.docc` catalogs, reads the manifest's docc-plugin wiring, and measures
/// `///` coverage over the package's `Sources/` — preferring the AST-backed
/// `api --include-internal` declaration list, with the line-heuristic parser
/// as the fallback.  this is the *coverage* tool; `docc-check` remains the
/// symbol-reference validator.
struct DocCoverageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doc-coverage",
        abstract: "Inventory DocC catalogs and measure /// doc-comment coverage."
    )

    @Argument(help: "Package directory or any path inside it.")
    var path: String = "."

    @Option(name: .long, help: "Maximum uncovered symbols to list (uncovered_symbol_count is always the full total).")
    var limit: Int?

    @Option(name: .long, help: "Output format: json, compact.")
    var outputFormat: OutputFormat = .compact

    @Flag(name: .long, inversion: .prefixedNo, help: "Pretty-print JSON output.")
    var prettyPrint = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    @Option(name: .customLong("output"), help: "Write output to file instead of stdout.")
    var outputPath: String = ""

    func run() throws {
        if schema {
            print(DocCoverageReport.jsonSchema)
            return
        }
        let target = try resolveExistingPath(path)
        let package = packageFileURL(for: target)
        let packageDir = package.deletingLastPathComponent()

        func emit(_ payload: some Encodable & Sendable) throws {
            let fmt: OutputFormat = prettyPrint ? .json : outputFormat
            try writeOutput(try formatObject(payload, format: fmt), to: outputPath)
        }

        guard FileManager.default.fileExists(atPath: package.path) else {
            try emit(DocCoverageFailureReport(
                ok: false, target: target, error: "no Package.swift at \(package.path)"
            ))
            throw ExitCode(1)
        }

        let manifestText = readSwiftSource(package.path) ?? ""
        let catalogs = DocCoverageCommand.findCatalogs(in: packageDir.path)
        let manifest = DocCoverageCommand.manifestFacts(manifestText)

        var coverage: DocCoverageStats?
        let sourcesDir = packageDir.appendingPathComponent("Sources")
        var isDir: ObjCBool = false
        var sourceRoots: [String] = []
        if FileManager.default.fileExists(atPath: sourcesDir.path, isDirectory: &isDir), isDir.boolValue {
            sourceRoots = DocCoverageCommand.subdirectories(of: sourcesDir.path)
        }
        if !sourceRoots.isEmpty {
            coverage = DocCoverageCommand.apiCoverage(
                sourcesPath: sourcesDir.path, limit: limit
            ) ?? DocCoverageCommand.heuristicCoverage(
                sourcesPath: sourcesDir.path, limit: limit
            )
        }

        let summary: String
        if let coverage, coverage.declarations > 0 {
            let percent = String(format: "%.0f", (coverage.coverage ?? 0) * 100)
            summary = "\(catalogs.count) DocC catalog(s); " +
                "\(coverage.documented)/\(coverage.declarations) declarations documented " +
                "(\(percent)%); \(coverage.undocumented) uncovered"
        } else {
            summary = "\(catalogs.count) DocC catalog(s); no public declarations to document"
        }

        let report = DocCoverageReport(
            ok: true, target: target, packagePath: packageDir.path,
            catalogs: catalogs, catalogCount: catalogs.count,
            manifest: manifest, coverage: coverage, summary: summary
        )
        try emit(report)
    }

    // MARK: - catalogs

    /// every `*.docc` catalog (directory or file) under the package, skipping
    /// build/VCS scratch.  sorted by path so repeated runs are byte-stable.
    static func findCatalogs(in packageDir: String) -> [DoccCatalog] {
        let skip: Set<String> = [".build", ".git", ".swiftpm", ".build-audit", "DerivedData"]
        var found: [DoccCatalog] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: packageDir) else { return [] }
        for case let entry as String in enumerator {
            let parts = entry.split(separator: "/").map(String.init)
            if parts.dropLast().contains(where: { skip.contains($0) }) {
                enumerator.skipDescendants()
                continue
            }
            guard parts.last!.hasSuffix(".docc") else { continue }
            let full = (packageDir as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let markdown = ((try? fm.contentsOfDirectory(atPath: full)) ?? [])
                    .filter { $0.hasSuffix(".md") }
                    .sorted()
                    .map { (full as NSString).appendingPathComponent($0) }
                found.append(DoccCatalog(
                    path: full, kind: "catalog",
                    markdownFiles: markdown, markdownFileCount: markdown.count
                ))
            } else {
                found.append(DoccCatalog(path: full, kind: "file", markdownFiles: [], markdownFileCount: 0))
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    // MARK: - manifest facts

    static func manifestFacts(_ text: String) -> DoccManifest {
        let hasPlugin = (try? NSRegularExpression(pattern: "swift-docc-plugin|swift-docc|\\bDoccPlugin\\b"))?
            .firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil

        var targets: [String] = []
        let blockPattern = try? NSRegularExpression(pattern: "documentationTargets\\s*:\\s*\\[([^\\]]*)\\]")
        let quoted = try? NSRegularExpression(pattern: "\"([^\"]+)\"")
        if let blockPattern {
            let full = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in blockPattern.matches(in: text, range: full) {
                guard match.numberOfRanges > 1, let inner = Range(match.range(at: 1), in: text) else { continue }
                let block = String(text[inner])
                let blockRange = NSRange(block.startIndex..<block.endIndex, in: block)
                for quotedMatch in quoted?.matches(in: block, range: blockRange) ?? [] {
                    guard quotedMatch.numberOfRanges > 1, let nameRange = Range(quotedMatch.range(at: 1), in: block) else { continue }
                    targets.append(String(block[nameRange]))
                }
            }
        }
        return DoccManifest(hasDoccPlugin: hasPlugin, documentationTargets: targets)
    }

    // MARK: - coverage

    static func subdirectories(of path: String) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return entries.compactMap { name in
            var isDir: ObjCBool = false
            let full = (path as NSString).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { return nil }
            return full
        }.sorted()
    }

    /// AST-backed coverage over `Sources/` (the `api --include-internal` list).
    /// returns nil when there is nothing to measure, so the caller can fall
    /// back to the line heuristic.
    static func apiCoverage(sourcesPath: String, limit: Int?) -> DocCoverageStats? {
        var items: [ApiItem] = []
        for filePath in collectSwiftFiles(from: [sourcesPath]) {
            guard let source = readSwiftSource(filePath) else { continue }
            let tree = Parser.parse(source: source)
            let collector = ApiCollector(filePath: filePath, source: source, includeInternal: true)
            collector.walk(tree)
            items.append(contentsOf: collector.items)
        }
        guard !items.isEmpty else { return nil }

        // the python contract reads `api --include-internal` output, which is
        // sorted by (kind, name) — reproduce that order so the uncovered list
        // is comparable position-for-position.
        items.sort { ($0.kind, $0.name) < ($1.kind, $1.name) }

        let undocumented = items.filter { $0.docComment.trimmingCharacters(in: .whitespaces).isEmpty }
        let documentedCount = items.count - undocumented.count

        func entry(_ item: ApiItem) -> UncoveredSymbol {
            UncoveredSymbol(
                name: item.name, kind: item.kind, file: item.file, line: item.line,
                decl: String(item.signature.prefix(120))
            )
        }
        return DocCoverageStats(
            declarations: items.count,
            documented: documentedCount,
            undocumented: undocumented.count,
            coverage: round3(Double(documentedCount) / Double(items.count)),
            uncoveredSymbols: limit.map { Array(undocumented.prefix($0).map(entry)) } ?? undocumented.map(entry),
            uncoveredSymbolCount: undocumented.count,
            undocumentedSamples: undocumented.prefix(8).map(entry)
        )
    }

    /// line-heuristic coverage, used when the AST list is unavailable.
    static func heuristicCoverage(sourcesPath: String, limit: Int?) -> DocCoverageStats {
        var documented = 0
        var undoc = 0
        var uncovered: [UncoveredSymbol] = []

        for filePath in collectSwiftFiles(from: [sourcesPath]) {
            guard let text = readSwiftSource(filePath) else { continue }
            var previousWasDoc = false
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let stripped = line.trimmingCharacters(in: .whitespaces)
                if stripped.isEmpty { previousWasDoc = false; continue }
                if stripped.hasPrefix("///") { previousWasDoc = true; continue }
                if let parsed = parseDeclaration(line) {
                    if previousWasDoc {
                        documented += 1
                    } else {
                        undoc += 1
                        if limit == nil || uncovered.count < limit! {
                            uncovered.append(UncoveredSymbol(
                                name: parsed.name, kind: parsed.kind, file: filePath,
                                line: index + 1, decl: String(stripped.prefix(120))
                            ))
                        }
                    }
                    previousWasDoc = false
                } else {
                    previousWasDoc = false
                }
            }
        }
        let total = documented + undoc
        return DocCoverageStats(
            declarations: total,
            documented: documented,
            undocumented: undoc,
            coverage: total == 0 ? nil : round3(Double(documented) / Double(total)),
            uncoveredSymbols: uncovered,
            uncoveredSymbolCount: uncovered.count,
            undocumentedSamples: Array(uncovered.prefix(8))
        )
    }

    /// parse a swift declaration line into (kind, name) — the heuristic
    /// parser's shape, anchored at the start of the stripped line.  `name` is
    /// always assigned (the python contract falls back to the kind).
    static func parseDeclaration(_ line: String) -> (kind: String, name: String)? {
        let stripped = line.trimmingCharacters(in: .whitespaces)
        let pattern = "^(?:(?:public|open|internal|private|fileprivate)\\s+)*" +
            "(class|struct|enum|protocol|func|var|let|subscript|init)\\b(.*)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: stripped, range: NSRange(stripped.startIndex..<stripped.endIndex, in: stripped)),
              let kindRange = Range(match.range(at: 1), in: stripped),
              let restRange = Range(match.range(at: 2), in: stripped) else { return nil }
        let kind = String(stripped[kindRange])
        let rest = String(stripped[restRange]).trimmingCharacters(in: .whitespaces)
        var name: String?
        if let nameRegex = try? NSRegularExpression(pattern: "^([A-Za-z_][A-Za-z0-9_]*)"),
           let nameMatch = nameRegex.firstMatch(in: rest, range: NSRange(rest.startIndex..<rest.endIndex, in: rest)),
           let nameRange = Range(nameMatch.range(at: 1), in: rest) {
            name = String(rest[nameRange])
        }
        let resolved: String
        switch kind {
        case "class", "struct", "enum", "protocol":
            resolved = name ?? kind
        case "subscript":
            resolved = "subscript"
        case "init":
            resolved = name ?? "init"
        default:
            resolved = name ?? kind
        }
        return (kind, resolved)
    }

    /// round to three decimals (the python contract's `round(x, 3)`).
    static func round3(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }
}

// MARK: - output types

struct DoccCatalog: Codable, Sendable {
    let path: String
    let kind: String
    let markdownFiles: [String]
    let markdownFileCount: Int

    enum CodingKeys: String, CodingKey {
        case path, kind
        case markdownFiles = "markdown_files"
        case markdownFileCount = "markdown_file_count"
    }
}

struct DoccManifest: Codable, Sendable {
    let hasDoccPlugin: Bool
    let documentationTargets: [String]

    enum CodingKeys: String, CodingKey {
        case hasDoccPlugin = "has_docc_plugin"
        case documentationTargets = "documentation_targets"
    }
}

struct UncoveredSymbol: Codable, Sendable {
    let name: String
    let kind: String
    let file: String
    let line: Int
    let decl: String
}

struct DocCoverageStats: Codable, Sendable {
    let declarations: Int
    let documented: Int
    let undocumented: Int
    let coverage: Double?
    let uncoveredSymbols: [UncoveredSymbol]
    let uncoveredSymbolCount: Int
    let undocumentedSamples: [UncoveredSymbol]

    enum CodingKeys: String, CodingKey {
        case declarations, documented, undocumented, coverage
        case uncoveredSymbols = "uncovered_symbols"
        case uncoveredSymbolCount = "uncovered_symbol_count"
        case undocumentedSamples = "undocumented_samples"
    }
}

struct DocCoverageReport: Codable, Sendable {
    let ok: Bool
    let target: String
    let packagePath: String
    let catalogs: [DoccCatalog]
    let catalogCount: Int
    let manifest: DoccManifest
    let coverage: DocCoverageStats?
    let summary: String

    enum CodingKeys: String, CodingKey {
        case ok, target, catalogs, manifest, coverage, summary
        case packagePath = "package_path"
        case catalogCount = "catalog_count"
    }

    static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "DocCoverageReport",
      "type": "object",
      "properties": {
        "ok":            { "type": "boolean" },
        "target":        { "type": "string" },
        "package_path":  { "type": "string" },
        "catalogs":      { "type": "array", "items": { "type": "object" } },
        "catalog_count": { "type": "integer" },
        "manifest":      { "type": "object", "description": "has_docc_plugin, documentation_targets" },
        "coverage": {
          "type": ["object", "null"],
          "description": "declarations/documented/undocumented/coverage/r…",
          "properties": {
            "declarations":           { "type": "integer" },
            "documented":             { "type": "integer" },
            "undocumented":           { "type": "integer" },
            "coverage":               { "type": ["number", "null"] },
            "uncovered_symbols":      { "type": "array", "items": { "type": "object" } },
            "uncovered_symbol_count": { "type": "integer" },
            "undocumented_samples":   { "type": "array", "items": { "type": "object" } }
          }
        },
        "summary":       { "type": "string" }
      },
      "required": ["ok", "target", "package_path", "catalogs", "catalog_count", "manifest", "summary"]
    }
    """
}

struct DocCoverageFailureReport: Encodable, Sendable {
    let ok: Bool
    let target: String
    let error: String
    let catalogs: [DoccCatalog] = []
    let coverage: DocCoverageStats? = nil
}