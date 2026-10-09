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
import SubprocessCore

/// list a package's resolved dependencies (flat, transitive included) with
/// their requirement kinds, straight from `swift package show-dependencies`.
///
/// ports the package-inspector's `list_dependencies` into the CLI.  the walk
/// starts at the root's children, so the package under analysis is never
/// listed as its own dependency; like the Python contract, `package_path`
/// names the `Package.swift` file here (not the directory).
struct PackageDependenciesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "package-dependencies",
        abstract: "List resolved package dependencies with requirement kinds."
    )

    @Argument(help: "Package directory or any path inside it.")
    var path: String = "."

    @Flag(name: .customLong("compact"), help: "Return name/requirement-kind/version only.")
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
            print(PackageDependenciesReport.jsonSchema)
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
            try emit(PackageDependenciesFailureReport(
                ok: false, target: target, error: "no Package.swift at \(package.path)"
            ))
            throw ExitCode(1)
        }

        let dependencies: [DependencyEntry]
        do {
            dependencies = try await DependenciesEngine.list(packageDir: packageDir)
        } catch {
            try emit(PackageDependenciesFailureReport(ok: false, target: target, error: "\(error)"))
            throw ExitCode(1)
        }

        let fmt: OutputFormat = prettyPrint ? .json : outputFormat
        if compact {
            let report = PackageDependenciesCompactReport(
                ok: true, target: target, count: dependencies.count,
                dependencies: dependencies.map {
                    CompactDependency(name: $0.name, requirementKind: $0.requirementKind, version: $0.version)
                },
                packagePath: package.path, compact: true
            )
            try writeOutput(try formatObject(report, format: fmt), to: outputPath)
        } else {
            let report = PackageDependenciesReport(
                ok: true, target: target, count: dependencies.count,
                dependencies: dependencies, packagePath: package.path, compact: false
            )
            try writeOutput(try formatObject(report, format: fmt), to: outputPath)
        }
    }
}

// MARK: - the engine

/// the dependency-listing engine — shared by `package-dependencies` and
/// `inspector`.  the walk starts at the root's children, so the package under
/// analysis is never listed as its own dependency.
enum DependenciesEngine {
    static func list(packageDir: String) async throws -> [DependencyEntry] {
        let described = try await runSwiftPackageJSON(
            ["show-dependencies", "--format", "json"], in: packageDir
        )
        guard let root = described as? [String: Any] else {
            throw UsageError("failed to parse deps output: not an object")
        }
        var dependencies: [DependencyEntry] = []
        func walk(_ node: [String: Any]) {
            let identity = node["identity"] as? String
            let name = (identity?.isEmpty == false ? identity : nil) ?? node["name"] as? String ?? ""
            let url = node["url"] as? String ?? ""
            let version = node["version"] as? String ?? ""
            let requirement = node["requirement"] as? [String: Any]
            let kind = requirement?["type"] as? String ?? "unknown"
            let lower = requirement?["lowerBound"] as? String ?? ""
            let upper = requirement?["upperBound"] as? String ?? ""
            dependencies.append(DependencyEntry(
                name: name, url: url, version: version,
                requirementKind: kind,
                requirement: lower.isEmpty ? kind : "\(kind) \(lower)..<\(upper)"
            ))
            for child in (node["dependencies"] as? [[String: Any]]) ?? [] {
                walk(child)
            }
        }
        for child in (root["dependencies"] as? [[String: Any]]) ?? [] {
            walk(child)
        }
        return dependencies
    }
}

// MARK: - output types

struct DependencyEntry: Codable, Sendable {
    let name: String
    let url: String
    let version: String
    let requirementKind: String
    let requirement: String

    enum CodingKeys: String, CodingKey {
        case name, url, version, requirement
        case requirementKind = "requirement_kind"
    }
}

/// the compact entry preserves `null` for an unpinned version (the Python
/// contract passes `None` through), so it encodes explicitly rather than
/// relying on the omitted-when-nil default.
struct CompactDependency: Codable, Sendable {
    let name: String
    let requirementKind: String
    let version: String?

    enum CodingKeys: String, CodingKey {
        case name, version
        case requirementKind = "requirement_kind"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(requirementKind, forKey: .requirementKind)
        try container.encode(version, forKey: .version)
    }
}

struct PackageDependenciesReport: Codable, Sendable {
    let ok: Bool
    let target: String
    let count: Int
    let dependencies: [DependencyEntry]
    let packagePath: String
    let compact: Bool

    enum CodingKeys: String, CodingKey {
        case ok, target, count, dependencies, compact
        case packagePath = "package_path"
    }

    static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "PackageDependenciesReport",
      "type": "object",
      "properties": {
        "ok":           { "type": "boolean" },
        "target":       { "type": "string" },
        "count":        { "type": "integer" },
        "dependencies": { "type": "array", "items": { "$ref": "#/definitions/DependencyEntry" } },
        "package_path": { "type": "string", "description": "Path to Package.swift" },
        "compact":      { "type": "boolean" }
      },
      "definitions": {
        "DependencyEntry": {
          "type": "object",
          "properties": {
            "name":             { "type": "string" },
            "url":              { "type": "string" },
            "version":          { "type": "string" },
            "requirement_kind": { "type": "string", "description": "range, exact, branch, revision, …" },
            "requirement":      { "type": "string" }
          }
        }
      },
      "required": ["ok", "target", "count", "dependencies", "package_path"]
    }
    """
}

struct PackageDependenciesCompactReport: Codable, Sendable {
    let ok: Bool
    let target: String
    let count: Int
    let dependencies: [CompactDependency]
    let packagePath: String
    let compact: Bool

    enum CodingKeys: String, CodingKey {
        case ok, target, count, dependencies, compact
        case packagePath = "package_path"
    }
}

struct PackageDependenciesFailureReport: Codable, Sendable {
    let ok: Bool
    let target: String
    let error: String
    let dependencies: [DependencyEntry] = []
}