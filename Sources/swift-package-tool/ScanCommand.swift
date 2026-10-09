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

/// unified security / code-quality scan across four categories.
///
/// ports the package-inspector's Python scanner into the CLI, which is the
/// single home for the analysis: unsafe pointers, force unwraps (AST-backed),
/// process safety, and hardcoded secrets.  every finding carries a `severity`
/// adjusted for reachability, so a triaging agent ranks what a reviewer should
/// look at rather than every raw `!` or pointer.
///
/// the severity model is reachability-aware:
/// - test sources (`Tests/` or `*Tests.swift`) cap at `medium`
/// - cleanup paths (close/teardown/…) rank `low`
/// - attacker-reachable members (parse/decode/read/…) keep their consequence
/// - internal utility code caps high-consequence operators at `medium`
struct ScanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Unified security/code-quality scan: unsafe pointers, force unwraps, process safety, secrets.",
        discussion: """
        Runs one or more scan categories and returns unified findings with \
        severity counts. Categories: unsafe_ptrs, force_unwraps, \
        process_safety, secrets (default: all). Use --compact for a quick \
        triage pass (counts and top-5 findings per category).
        """
    )

    @Argument(help: "Package directory or source path to scan.")
    var path: String = "."

    @Option(name: .long, help: "Comma-separated categories: unsafe_ptrs, force_unwraps, process_safety, secrets, all. Default: all.")
    var categories: String?

    @Flag(name: .customLong("compact"), help: "Return counts and top-5 findings only per category.")
    var compact = false

    @Option(name: .long, help: "Output format: json, compact.")
    var outputFormat: OutputFormat = .compact

    @Flag(name: .long, inversion: .prefixedNo, help: "Pretty-print JSON output.")
    var prettyPrint = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    @Option(name: .customLong("output"), help: "Write output to file instead of stdout.")
    var outputPath: String = ""

    mutating func run() throws {
        if schema {
            print(ScanReport.jsonSchema)
            return
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            throw ValidationError("path not found: \(path)")
        }

        let requested = try ScanCategory.parseList(categories)
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        let report = ScanEngine.run(target: target, categories: requested, compact: compact)

        let fmt: OutputFormat = prettyPrint ? .json : outputFormat
        let outputStr = try formatObject(report, format: fmt)
        try writeOutput(outputStr, to: outputPath)
    }
}

// MARK: - categories

/// the scan categories the unified scanner understands.
enum ScanCategory: String, CaseIterable, Sendable {
    case unsafePtrs = "unsafe_ptrs"
    case forceUnwraps = "force_unwraps"
    case processSafety = "process_safety"
    case secrets = "secrets"

    /// parses the `--categories` value; `nil`/`all` means every category.
    static func parseList(_ raw: String?) throws -> [ScanCategory] {
        guard let raw, !raw.isEmpty else { return ScanCategory.allCases }
        let names = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if names.contains("all") { return ScanCategory.allCases }
        var result: [ScanCategory] = []
        for name in names {
            guard let category = ScanCategory(rawValue: name) else {
                throw ValidationError("unknown scan category '\(name)' (expected: unsafe_ptrs, force_unwraps, process_safety, secrets, all)")
            }
            if !result.contains(category) { result.append(category) }
        }
        return result
    }
}

// MARK: - output types

/// one finding from any scan category.
///
/// the category tables populate different subsets of these fields; a `nil`
/// field is omitted from the JSON (the Python contract's shape).
struct ScanFinding: Codable, Sendable {
    var file: String
    var line: Int
    var api: String?
    var kind: String?
    var match: String?
    var primary: String?
    var subkinds: [String: Int]?
    var severity: String?
    var severityHint: String?
    var context: String?
    var reachability: String?
    var relatedLines: [Int]?

    enum CodingKeys: String, CodingKey {
        case file, line, api, kind, match, primary, subkinds, severity, context, reachability
        case severityHint = "severity_hint"
        case relatedLines = "related_lines"
    }
}

/// one category's slice of the unified report.
struct ScanCategoryResult: Codable, Sendable {
    let count: Int
    let findings: [ScanFinding]
}

/// the unified scan report — the shape the `pkg_scan` agent tool returns.
struct ScanReport: Codable, Sendable {
    let ok: Bool
    let target: String
    let categoriesRun: [String]
    let totalFindings: Int
    let byCategory: [String: ScanCategoryResult]
    let bySeverity: [String: Int]
    let topFindings: [ScanFinding]
    let compact: Bool

    enum CodingKeys: String, CodingKey {
        case ok, target, compact
        case categoriesRun = "categories_run"
        case totalFindings = "total_findings"
        case byCategory = "by_category"
        case bySeverity = "by_severity"
        case topFindings = "top_findings"
    }

    static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "ScanReport",
      "type": "object",
      "properties": {
        "ok":              { "type": "boolean" },
        "target":          { "type": "string", "description": "Scanned absolute path" },
        "categories_run":  { "type": "array", "items": { "type": "string" } },
        "total_findings":  { "type": "integer" },
        "by_category":     { "type": "object", "description": "category -> {count, findings}" },
        "by_severity":     { "type": "object", "description": "critical/high/medium/low counts" },
        "top_findings":    { "type": "array", "items": { "$ref": "#/definitions/ScanFinding" } },
        "compact":         { "type": "boolean" }
      },
      "definitions": {
        "ScanFinding": {
          "type": "object",
          "properties": {
            "file":          { "type": "string" },
            "line":          { "type": "integer" },
            "api":           { "type": "string" },
            "kind":          { "type": "string" },
            "match":         { "type": "string" },
            "primary":       { "type": "string" },
            "subkinds":      { "type": "object" },
            "severity":      { "type": "string" },
            "severity_hint": { "type": "string" },
            "context":       { "type": "string" },
            "reachability":  { "type": "string" },
            "related_lines": { "type": "array", "items": { "type": "integer" } }
          },
          "required": ["file", "line"]
        }
      },
      "required": ["ok", "target", "categories_run", "total_findings", "by_category", "by_severity", "top_findings"]
    }
    """
}

// MARK: - pattern tables

/// a display name paired with the regex that recognizes it.
struct ScanPattern: Sendable {
    let name: String
    let regex: NSRegularExpression

    init(_ name: String, _ pattern: String) {
        self.name = name
        self.regex = (try? NSRegularExpression(pattern: pattern)) ?? NSRegularExpression()
    }
}

/// the pattern tables, ported verbatim from the package-inspector's Python
/// scanner so a scan's output stays comparable across the two implementations.
enum ScanPatterns {
    static let unsafePtrs: [ScanPattern] = [
        ScanPattern("UnsafePointer", #"\bUnsafePointer\b"#),
        ScanPattern("UnsafeMutablePointer", #"\bUnsafeMutablePointer\b"#),
        ScanPattern("UnsafeRawPointer", #"\bUnsafeRawPointer\b"#),
        ScanPattern("UnsafeMutableRawPointer", #"\bUnsafeMutableRawPointer\b"#),
        ScanPattern("UnsafeBufferPointer", #"\bUnsafeBufferPointer\b"#),
        ScanPattern("withUnsafeBytes", #"\bwithUnsafeBytes\b"#),
        ScanPattern("withUnsafeMutableBytes", #"\bwithUnsafeMutableBytes\b"#),
        ScanPattern("withUnsafeBufferPointer", #"\bwithUnsafeBufferPointer\b"#),
        ScanPattern("withUnsafePointer", #"\bwithUnsafePointer\b"#),
        ScanPattern("Unmanaged", #"\bUnmanaged\b"#),
        ScanPattern("unsafeBitCast", #"\bunsafeBitCast\b"#),
        ScanPattern("unsafeDowncast", #"\bunsafeDowncast\b"#),
        ScanPattern("unsafeAddressOf", #"\bunsafeAddressOf\b"#),
    ]

    static let secrets: [ScanPattern] = [
        ScanPattern("aws_access_key", #"\bAKIA[0-9A-Z]{16}\b"#),
        ScanPattern("aws_secret_key", #"\b(?:aws)?_?secret[_ ]?access[_ ]?key\s*[:=]\s*[\"'][A-Za-z0-9/+=]{20,}[\"']"#),
        ScanPattern("github_token", #"\bgh[pousr]_[A-Za-z0-9]{36,}\b"#),
        ScanPattern("bearer_token", #"(?:bearer|authorization)\s+sk_(?:live|test)_[A-Za-z0-9]{16,}"#),
        ScanPattern("stripe_key", #"\bsk_(?:live|test)_[A-Za-z0-9]{16,}\b"#),
        ScanPattern("private_key", #"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"#),
        ScanPattern("generic_password", #"(?:password|passwd|pwd|secret)\s*[:=]\s*[\"'][^\"']{6,}[\"']"#),
        ScanPattern("api_key", #"\bapi[_ ]?key\s*[:=]\s*[\"'][A-Za-z0-9]{16,}[\"']"#),
    ]

    static let processSafety: [ScanPattern] = [
        ScanPattern("raw_fork_without_exec", #"\bfork\(\)"#),
        ScanPattern("posix_spawn", #"\bposix_spawn(?:p)?\s*\("#),
        ScanPattern("missing_cloexec", #"\b(?:open|openat|socket|socketpair|pipe2?|dup)\s*\([^;]*?(?!O_CLOEXEC|FD_CLOEXEC)"#),
        ScanPattern("fd_mutation", #"\bdup(?:2|3)?\s*\(|\bfcntl\s*\(|\bioctl\s*\("#),
        ScanPattern("fork_and_handoff", #"\bexecve?\s*\(|\bexecvp\s*\(|\bexecl(?:p|pe)?\s*\("#),
    ]

    /// the base severity of a process-safety api.
    static let processSafetySeverity: [String: String] = [
        "raw_fork_without_exec": "high",
        "missing_cloexec": "high",
        "fd_mutation": "medium",
        "fork_and_handoff": "high",
        "posix_spawn": "low",
    ]

    /// secrets whose exposure is critical rather than merely high.
    static let criticalSecrets: Set<String> = ["private_key", "aws_secret_key"]
}

// MARK: - engine

/// the scan engine: reads swift sources, clusters hits by scope, and ranks
/// them by a reachability-aware severity.  pure over its inputs (the file
/// system read is the only effect), so the unified report is reproducible.
enum ScanEngine {

    static func run(target: String, categories: [ScanCategory], compact: Bool) -> ScanReport {
        var byCategory: [String: ScanCategoryResult] = [:]
        var allFindings: [ScanFinding] = []

        for category in categories {
            let findings = ScanEngine.findings(for: category, target: target)
            byCategory[category.rawValue] = ScanCategoryResult(
                count: findings.count,
                findings: compact ? Array(findings.prefix(5)) : findings
            )
            allFindings.append(contentsOf: findings)
        }

        var severityCounts: [String: Int] = ["critical": 0, "high": 0, "medium": 0, "low": 0]
        for finding in allFindings {
            let severity = finding.severity ?? finding.severityHint ?? "low"
            if severityCounts[severity] != nil { severityCounts[severity, default: 0] += 1 }
        }

        let order: [String: Int] = ["critical": 0, "high": 1, "medium": 2, "low": 3]
        let sorted = allFindings.enumerated().sorted { lhs, rhs in
            let l = order[lhs.element.severity ?? lhs.element.severityHint ?? "low"] ?? 9
            let r = order[rhs.element.severity ?? rhs.element.severityHint ?? "low"] ?? 9
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map(\.element)
        let top = Array(sorted.prefix(compact ? 5 : 10))

        return ScanReport(
            ok: true,
            target: target,
            categoriesRun: categories.map(\.rawValue),
            totalFindings: allFindings.count,
            byCategory: byCategory,
            bySeverity: severityCounts,
            topFindings: top,
            compact: compact
        )
    }

    /// runs one category over the target's swift sources.
    static func findings(for category: ScanCategory, target: String) -> [ScanFinding] {
        let files = collectSwiftFiles(from: [target])
        switch category {
        case .unsafePtrs:
            return scanRegexCategory(files: files, patterns: ScanPatterns.unsafePtrs, clustered: true)
        case .secrets:
            return scanSecrets(files: files)
        case .processSafety:
            return scanProcessSafety(files: files)
        case .forceUnwraps:
            return scanForceUnwraps(files: files)
        }
    }

    // MARK: regex categories

    /// a raw per-line hit: the line number, the label of the first matching
    /// pattern (pattern-table order, matching the Python scanner's
    /// first-match-wins re-test), and the count of combined-regex matches.
    private struct LineHit {
        let line: Int
        let label: String
        let matchCount: Int
        let text: String
    }

    private static func lineHits(in lines: [String], patterns: [ScanPattern]) -> [LineHit] {
        guard !patterns.isEmpty else { return [] }
        let combined = try? NSRegularExpression(
            pattern: patterns.map { "(?:\($0.regex.pattern))" }.joined(separator: "|")
        )
        var hits: [LineHit] = []
        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            let count = combined?.numberOfMatches(in: line, range: range) ?? 0
            guard count > 0 else { continue }
            guard let label = patterns.first(where: {
                $0.regex.firstMatch(in: line, range: range) != nil
            })?.name else { continue }
            hits.append(LineHit(line: index + 1, label: label, matchCount: count, text: line))
        }
        return hits
    }

    /// unsafe-pointer scan: cluster hits by enclosing scope and rank by
    /// reachability (a `try!`-free category — the pointer primitives).
    private static func scanRegexCategory(files: [String], patterns: [ScanPattern], clustered: Bool) -> [ScanFinding] {
        var findings: [ScanFinding] = []
        for file in files {
            guard let source = readSwiftSource(file) else { continue }
            let lines = source.components(separatedBy: "\n")
            let hits = lineHits(in: lines, patterns: patterns)
            guard !hits.isEmpty else { continue }
            let scopes = functionScopes(lines: lines)
            let context = isTestSource(file) ? "test" : "source"

            var clusteredLines: [Int: [Int]] = [:]
            var labelsByScope: [Int: String] = [:]
            for hit in hits {
                let scope = scopes[hit.line - 1]
                clusteredLines[scope, default: []].append(hit.line)
            }
            for (scope, hitLines) in clusteredLines {
                let rep = hitLines.min() ?? 0
                if let label = hits.first(where: { $0.line == rep })?.label {
                    labelsByScope[scope] = label
                }
            }

            for (scope, hitLines) in clusteredLines {
                let rep = hitLines.min() ?? 0
                let api = labelsByScope[scope] ?? hits.first?.label ?? "unknown"
                let member = enclosingMember(lines: lines, scopes: scopes, lineIndex: rep - 1)
                let reach = reachability(member: member)
                findings.append(ScanFinding(
                    file: file, line: rep,
                    api: api, kind: nil, match: api, primary: nil, subkinds: nil,
                    severity: severityFrom(context: context, reach: reach, base: severityForPointer(api)),
                    severityHint: severityForPointer(api),
                    context: context, reachability: reach,
                    relatedLines: Array(Set(hitLines)).sorted()
                ))
            }
        }
        return findings.sorted { ($0.file, $0.line) < ($1.file, $1.line) }
    }

    /// secrets scan: one finding per line, ranked by label.
    private static func scanSecrets(files: [String]) -> [ScanFinding] {
        var findings: [ScanFinding] = []
        for file in files {
            guard let source = readSwiftSource(file) else { continue }
            let lines = source.components(separatedBy: "\n")
            for hit in lineHits(in: lines, patterns: ScanPatterns.secrets) {
                findings.append(ScanFinding(
                    file: file, line: hit.line,
                    api: nil, kind: hit.label, match: String(hit.text.prefix(80)),
                    primary: nil, subkinds: nil, severity: nil,
                    severityHint: ScanPatterns.criticalSecrets.contains(hit.label) ? "critical" : "high",
                    context: nil, reachability: nil, relatedLines: nil
                ))
            }
        }
        return dedupeByLineKeepingPriority(findings)
    }

    /// dedupes findings by (file, line), keeping the first in label priority.
    private static func dedupeByLineKeepingPriority(_ findings: [ScanFinding]) -> [ScanFinding] {
        var best: [String: ScanFinding] = [:]
        var order: [String] = []
        for finding in findings {
            let key = "\(finding.file):\(finding.line)"
            if best[key] == nil {
                best[key] = finding
                order.append(key)
            }
        }
        return order.compactMap { best[$0] }
    }

    /// process-safety scan: one finding per regex match occurrence (the Python
    /// scanner counts matches, not lines, for this category).
    private static func scanProcessSafety(files: [String]) -> [ScanFinding] {
        var findings: [ScanFinding] = []
        for file in files {
            guard let source = readSwiftSource(file) else { continue }
            let lines = source.components(separatedBy: "\n")
            let context = isTestSource(file) ? "test" : "source"
            let scopes = functionScopes(lines: lines)
            for hit in lineHits(in: lines, patterns: ScanPatterns.processSafety) {
                let member = enclosingMember(lines: lines, scopes: scopes, lineIndex: hit.line - 1)
                let reach = reachability(member: member)
                let base = ScanPatterns.processSafetySeverity[hit.label] ?? "low"
                for _ in 0..<hit.matchCount {
                    findings.append(ScanFinding(
                        file: file, line: hit.line,
                        api: hit.label, kind: "process_safety", match: String(hit.text.trimmingCharacters(in: .whitespaces).prefix(200)),
                        primary: nil, subkinds: nil,
                        severity: severityFrom(context: context, reach: reach, base: base),
                        severityHint: nil, context: context, reachability: reach, relatedLines: nil
                    ))
                }
            }
        }
        return findings.sorted { ($0.file, $0.line) < ($1.file, $1.line) }
    }

    // MARK: force unwraps

    /// force-unwrap scan: AST-backed (swift-syntax), coalesced to one finding
    /// per (file, line) keeping the worst primary kind and severity.
    private static func scanForceUnwraps(files: [String]) -> [ScanFinding] {
        var findings: [ScanFinding] = []
        /// worst wins: try_force/as_cast outrank a plain force_unwrap.
        let kindOrder: [String: Int] = ["force_unwrap": 0, "try_force": 1, "as_cast": 1]
        let severityOrder: [String: Int] = ["low": 0, "medium": 1, "high": 2]

        for file in files {
            guard let source = readSwiftSource(file) else { continue }
            let lines = source.components(separatedBy: "\n")
            let scopes = functionScopes(lines: lines)
            let tree = Parser.parse(source: source)
            let collector = ForceUnwrapCollector(filePath: file, source: source)
            collector.walk(tree)
            let context = isTestSource(file) ? "test" : "source"

            var bySpot: [Int: ScanFinding] = [:]
            var spotOrder: [Int] = []
            for item in collector.items {
                let member = enclosingMember(lines: lines, scopes: scopes, lineIndex: item.line - 1)
                let reach = reachability(member: member)
                let base = (item.kind == "try_force" || item.kind == "as_cast") ? "high" : "medium"
                let severity = severityFrom(context: context, reach: reach, base: base)

                if var existing = bySpot[item.line] {
                    var subkinds = existing.subkinds ?? [:]
                    subkinds[item.kind, default: 0] += 1
                    existing.subkinds = subkinds
                    if (kindOrder[item.kind] ?? 0) > (kindOrder[existing.primary ?? ""] ?? 0) {
                        existing.primary = item.kind
                    }
                    if (severityOrder[severity] ?? 0) > (severityOrder[existing.severity ?? ""] ?? 0) {
                        existing.severity = severity
                    }
                    bySpot[item.line] = existing
                } else {
                    bySpot[item.line] = ScanFinding(
                        file: file, line: item.line,
                        api: nil, kind: "force_unwrap",
                        match: String(item.context.prefix(200)),
                        primary: item.kind, subkinds: [item.kind: 1], severity: severity,
                        severityHint: nil, context: context, reachability: reach, relatedLines: nil
                    )
                    spotOrder.append(item.line)
                }
            }
            findings.append(contentsOf: spotOrder.compactMap { bySpot[$0] })
        }
        return findings.sorted { ($0.file, $0.line) < ($1.file, $1.line) }
    }

    // MARK: severity helpers

    /// the operator's consequence for a pointer/memory API.
    static func severityForPointer(_ api: String) -> String {
        let high: Set<String> = ["unsafeBitCast", "unsafeDowncast", "unsafeAddressOf", "Unmanaged"]
        let medium: Set<String> = [
            "UnsafePointer", "UnsafeMutablePointer", "UnsafeRawPointer",
            "UnsafeMutableRawPointer", "UnsafeBufferPointer",
            "withUnsafeBytes", "withUnsafeMutableBytes",
            "withUnsafeBufferPointer", "withUnsafePointer",
        ]
        if high.contains(api) { return "high" }
        if medium.contains(api) { return "medium" }
        return "low"
    }

    /// ranks a finding from consequence plus reachability and context.
    static func severityFrom(context: String, reach: String, base: String) -> String {
        if context == "test" { return base == "high" ? "medium" : "low" }
        if reach == "cleanup" { return "low" }
        if reach == "input" { return base }
        return base == "high" ? "medium" : "low"
    }

    /// true for a swift file inside a test target or a *Tests.swift file.
    static func isTestSource(_ path: String) -> Bool {
        let s = path.replacingOccurrences(of: "\\", with: "/")
        return s.contains("/Tests/") || s.hasSuffix("Tests.swift")
    }

    /// classifies a member's input reachability from its declaration name.
    static func reachability(member: String) -> String {
        guard !member.isEmpty else { return "internal" }
        let input = try? NSRegularExpression(
            pattern: "parse|decode|read|recv|url|request|response|handler|input|load|fetch|receive|init\\b|unwrap|convert|deserialize|message",
            options: [.caseInsensitive]
        )
        let cleanup = try? NSRegularExpression(
            pattern: "close|cleanup|deinit|teardown|shutdown|remove|free|destroy|stop|cancel|invalidate|dispose",
            options: [.caseInsensitive]
        )
        let range = NSRange(member.startIndex..<member.endIndex, in: member)
        if input?.firstMatch(in: member, range: range) != nil { return "input" }
        if cleanup?.firstMatch(in: member, range: range) != nil { return "cleanup" }
        return "internal"
    }

    // MARK: scope analysis

    /// per-line scope id (0 = file/module scope) using brace depth — the same
    /// clustering the Python scanner applies, so severity ranking matches.
    static func functionScopes(lines: [String]) -> [Int] {
        var scopeIDs = [Int](repeating: 0, count: lines.count)
        var depth = 0
        var stack: [(id: Int, depth: Int)] = []
        var nextID = 1
        let controlFlow = try? NSRegularExpression(pattern: #"^\b(?:guard|if|for|while|switch|case|catch|repeat|return)\b"#)
        let opensScope = try? NSRegularExpression(pattern: #"\b(?:func|init|deinit|subscript)\b|\b(?:var|let)\b[^{]*\{"#)

        for (index, line) in lines.enumerated() {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            let isComment = stripped.hasPrefix("//")
            let range = NSRange(stripped.startIndex..<stripped.endIndex, in: stripped)
            let isControl = controlFlow?.firstMatch(in: stripped, range: range) != nil
            let opens = !isComment && !isControl && (opensScope?.firstMatch(in: stripped, range: range) != nil)

            for character in line {
                if character == "{" { depth += 1 }
                else if character == "}" { depth -= 1 }
            }
            while let last = stack.last, depth < last.depth { stack.removeLast() }
            if opens {
                stack.append((nextID, depth))
                nextID += 1
                scopeIDs[index] = stack.last?.id ?? 0
            } else if let last = stack.last {
                scopeIDs[index] = last.id
            }
        }
        return scopeIDs
    }

    /// the member declaration line that owns `lineIndex`, or "" for module scope.
    static func enclosingMember(lines: [String], scopes: [Int], lineIndex: Int) -> String {
        guard lineIndex >= 0, lineIndex < lines.count else { return "" }
        let scopeID = scopes[lineIndex]
        guard scopeID != 0 else { return "" }
        let decl = try? NSRegularExpression(pattern: #"\b(?:func|init|deinit|subscript)\b\s*([A-Za-z0-9_]+)?"#)
        var index = lineIndex
        while index >= 0 {
            if scopes[index] == scopeID {
                let line = lines[index]
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                if let match = decl?.firstMatch(in: line, range: range) {
                    return (line as NSString).substring(with: match.range)
                }
            }
            index -= 1
        }
        return ""
    }
}