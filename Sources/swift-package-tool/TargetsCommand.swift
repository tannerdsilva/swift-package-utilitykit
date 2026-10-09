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
import SubprocessCore

/// list a package's targets with resolved source paths, per-file line counts,
/// and an AST-backed symbol heatmap.
///
/// delegates target resolution to `swift package describe --type json` (the
/// toolchain's own resolver) and symbol counting to the in-process
/// `query --all` declaration collector — no regex parsing of `Package.swift`.
/// ports the package-inspector's `list_targets` into the CLI.
struct TargetsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "targets",
        abstract: "List package targets with source paths, line counts, and symbol heatmaps."
    )

    @Argument(help: "Package directory or any path inside it.")
    var path: String = "."

    @Flag(name: .customLong("compact"), help: "Return name/type/file-count/line-count only.")
    var compact = false

    @Option(name: .long, help: "Output format: json, compact.")
    var outputFormat: OutputFormat = .compact

    @Flag(name: .long, inversion: .prefixedNo, help: "Pretty-print JSON output.")
    var prettyPrint = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    @Option(name: .customLong("output"), help: "Write output to file instead of stdout.")
    var outputPath: String = ""

    func run() async throws {
        if schema {
            print(TargetsReport.jsonSchema)
            return
        }
        let target = try resolveExistingPath(path)
        let package = packageFileURL(for: target)
        let packageDir = package.deletingLastPathComponent().path

        func emit(_ payload: some Encodable & Sendable) throws {
            let fmt: OutputFormat = prettyPrint ? .json : outputFormat
            try writeOutput(try formatObject(payload, format: fmt), to: outputPath)
        }

        guard FileManager.default.fileExists(atPath: package.path) else {
            try emit(TargetsFailureReport(ok: false, target: target, error: "no Package.swift at \(package.path)"))
            throw ExitCode(1)
        }

        let described: Any
        do {
            described = try await runSwiftPackageJSON(["describe", "--type", "json"], in: packageDir)
        } catch {
            try emit(TargetsFailureReport(ok: false, target: target, error: "\(error)"))
            throw ExitCode(1)
        }

        guard let root = described as? [String: Any] else {
            try emit(TargetsFailureReport(ok: false, target: target, error: "failed to parse describe output: not an object"))
            throw ExitCode(1)
        }

        var entries: [TargetEntry] = []
        for rawTarget in (root["targets"] as? [[String: Any]]) ?? [] {
            entries.append(makeEntry(rawTarget, packageDir: packageDir))
        }

        let fmt: OutputFormat = prettyPrint ? .json : outputFormat
        if compact {
            let compactEntries = entries.map {
                CompactTargetEntry(
                    name: $0.name, type: $0.type,
                    swiftFileCount: $0.swiftFileCount, totalLines: $0.totalLines, exists: $0.exists
                )
            }
            let report = TargetsCompactReport(
                ok: true, target: target, packagePath: packageDir,
                count: compactEntries.count, targets: compactEntries, compact: true
            )
            try writeOutput(try formatObject(report, format: fmt), to: outputPath)
        } else {
            let report = TargetsReport(
                ok: true, target: target, packagePath: packageDir,
                count: entries.count, targets: entries, compact: false
            )
            try writeOutput(try formatObject(report, format: fmt), to: outputPath)
        }
    }

    // MARK: - one target

    private func makeEntry(_ rawTarget: [String: Any], packageDir: String) -> TargetEntry {
        let name = rawTarget["name"] as? String ?? ""
        let type = rawTarget["type"] as? String ?? "library"
        let rawPath = rawTarget["path"] as? String ?? ""
        let sources = rawTarget["sources"] as? [String] ?? []

        // `describe` emits the target path relative to the package dir and each
        // source as a bare filename relative to the target path; anchor both
        // before touching the filesystem.
        func absolute(_ raw: String) -> URL {
            let url = URL(fileURLWithPath: raw)
            if raw.hasPrefix("/") { return url.standardizedFileURL }
            return URL(fileURLWithPath: packageDir).appendingPathComponent(raw).standardizedFileURL
        }

        let targetDir: URL? = rawPath.isEmpty ? nil : absolute(rawPath)
        let sourcePaths: [URL] = sources.map { source in
            if let targetDir { return targetDir.appendingPathComponent(source).standardizedFileURL }
            return absolute(source)
        }

        // describe does not flag whether the path came from SwiftPM's default
        // rule (Sources/<Name>, Tests/<Name> for test targets) or an explicit
        // `path` property — derive it.
        let defaultPath = type == "test" ? "Tests/\(name)" : "Sources/\(name)"
        let pathKind = rawPath == defaultPath ? "default" : "explicit"

        var fileStats: [TargetFileStat] = []
        var totalLines = 0
        var totalSymbols = 0
        var largestFiles: [TargetLargestFile] = []

        let existingSources = sourcePaths.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !existingSources.isEmpty {
            // AST-backed symbol counts: one `query --all`-equivalent pass over
            // the target's swift sources, bucketed per file by declaration kind.
            var perFileKinds: [String: [String: Int]] = [:]
            let swiftSources = existingSources.filter { $0.pathExtension == "swift" }
            if !swiftSources.isEmpty {
                for url in swiftSources {
                    guard let source = readSwiftSource(url.path) else { continue }
                    let tree = Parser.parse(source: source)
                    let collector = DeclarationCollector(
                        filePath: url.path, source: source, kinds: DeclarationKinds.all
                    )
                    collector.walk(tree)
                    let key = url.resolvingSymlinksInPath().path
                    for declaration in collector.declarations {
                        perFileKinds[key, default: [:]][declaration.kind, default: 0] += 1
                        totalSymbols += 1
                    }
                }
            }

            for url in existingSources {
                guard let text = readSwiftSource(url.path) else { continue }
                let lineCount = text.isEmpty
                    ? 0
                    : text.components(separatedBy: "\n").count - (text.hasSuffix("\n") ? 1 : 0)
                let relative = relativePath(of: url, from: packageDir)
                let key = url.resolvingSymlinksInPath().path
                fileStats.append(TargetFileStat(
                    path: relative,
                    lines: lineCount,
                    symbols: perFileKinds[key] ?? [:]
                ))
                totalLines += lineCount
            }

            // python sorts by -lines with a stable sort; tie-break on insertion
            // order so the two implementations agree.
            let indexed = fileStats.enumerated().sorted { lhs, rhs in
                lhs.element.lines == rhs.element.lines
                    ? lhs.offset < rhs.offset
                    : lhs.element.lines > rhs.element.lines
            }.map(\.element)
            fileStats = indexed
            largestFiles = indexed.prefix(5).map {
                TargetLargestFile(path: $0.path, lines: $0.lines)
            }
        }

        return TargetEntry(
            name: name, type: type, rawPath: rawPath, pathKind: pathKind,
            swiftFileCount: sources.count, swiftFiles: sources,
            exists: targetDir.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
            fileStats: fileStats, totalSymbols: totalSymbols, totalLines: totalLines,
            largestFiles: largestFiles
        )
    }

    /// a path relative to the package dir when possible (the python contract),
    /// else the absolute path.
    private func relativePath(of url: URL, from packageDir: String) -> String {
        let base = packageDir.hasSuffix("/") ? packageDir : packageDir + "/"
        return url.path.hasPrefix(base) ? String(url.path.dropFirst(base.count)) : url.path
    }
}

// MARK: - declaration kinds

/// the declaration kinds `query --all` collects — shared so `targets` counts
/// exactly what the `query` subcommand reports.
enum DeclarationKinds {
    static let all: Set<String> = [
        "function", "struct", "class", "enum", "protocol",
        "typealias", "associatedtype", "variable",
        "extension", "initializer", "subscript",
        "operator", "precedencegroup", "macro", "import",
    ]
}

// MARK: - output types

struct TargetFileStat: Codable, Sendable {
    let path: String
    let lines: Int
    let symbols: [String: Int]
}

struct TargetLargestFile: Codable, Sendable {
    let path: String
    let lines: Int
}

struct TargetEntry: Codable, Sendable {
    let name: String
    let type: String
    let rawPath: String
    let pathKind: String
    let swiftFileCount: Int
    let swiftFiles: [String]
    let exists: Bool
    let fileStats: [TargetFileStat]
    let totalSymbols: Int
    let totalLines: Int
    let largestFiles: [TargetLargestFile]

    enum CodingKeys: String, CodingKey {
        case name, type, exists
        case rawPath = "path"
        case pathKind = "path_kind"
        case swiftFileCount = "swift_file_count"
        case swiftFiles = "swift_files"
        case fileStats = "file_stats"
        case totalSymbols = "total_symbols"
        case totalLines = "total_lines"
        case largestFiles = "largest_files"
    }
}

struct CompactTargetEntry: Codable, Sendable {
    let name: String
    let type: String
    let swiftFileCount: Int
    let totalLines: Int
    let exists: Bool

    enum CodingKeys: String, CodingKey {
        case name, type, exists
        case swiftFileCount = "swift_file_count"
        case totalLines = "total_lines"
    }
}

struct TargetsReport: Codable, Sendable {
    let ok: Bool
    let target: String
    let packagePath: String
    let count: Int
    let targets: [TargetEntry]
    let compact: Bool

    enum CodingKeys: String, CodingKey {
        case ok, target, count, targets, compact
        case packagePath = "package_path"
    }

    static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "TargetsReport",
      "type": "object",
      "properties": {
        "ok":           { "type": "boolean" },
        "target":       { "type": "string", "description": "Resolved input path" },
        "package_path": { "type": "string", "description": "Package directory" },
        "count":        { "type": "integer" },
        "targets":      { "type": "array", "items": { "$ref": "#/definitions/TargetEntry" } },
        "compact":      { "type": "boolean" }
      },
      "definitions": {
        "TargetEntry": {
          "type": "object",
          "properties": {
            "name":             { "type": "string" },
            "type":             { "type": "string" },
            "path":             { "type": "string", "description": "Target path as declared" },
            "path_kind":        { "type": "string", "description": "default | explicit" },
            "swift_file_count": { "type": "integer" },
            "swift_files":      { "type": "array", "items": { "type": "string" } },
            "exists":           { "type": "boolean" },
            "file_stats":       { "type": "array", "items": { "$ref": "#/definitions/TargetFileStat" } },
            "total_symbols":    { "type": "integer" },
            "total_lines":      { "type": "integer" },
            "largest_files":    { "type": "array", "items": { "type": "object" } }
          }
        },
        "TargetFileStat": {
          "type": "object",
          "properties": {
            "path":    { "type": "string" },
            "lines":   { "type": "integer" },
            "symbols": { "type": "object", "description": "declaration kind -> count" }
          }
        }
      },
      "required": ["ok", "target", "package_path", "count", "targets"]
    }
    """
}

struct TargetsCompactReport: Codable, Sendable {
    let ok: Bool
    let target: String
    let packagePath: String
    let count: Int
    let targets: [CompactTargetEntry]
    let compact: Bool

    enum CodingKeys: String, CodingKey {
        case ok, target, count, targets, compact
        case packagePath = "package_path"
    }
}

struct TargetsFailureReport: Codable, Sendable {
    let ok: Bool
    let target: String
    let error: String
    let targets: [TargetEntry] = []
}