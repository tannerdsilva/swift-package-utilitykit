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

/// one-call orientation: what the project is, its shape, and its health.
///
/// composes the other tools — targets, dependencies, audit triage, build,
/// test, doc coverage — into a single JSON object, and (the point of the
/// first call on an unfamiliar package) states the verdict in one `summary`
/// line.  ports the package-inspector's `inspector`.
///
/// the build and test verdicts come from isolated runs (fresh ephemeral
/// scratch, the real `.build` untouched): the verdict is a clean-room build of
/// the current source.  `--skip-build`/`--skip-test` scope the call when only
/// the static picture is wanted.
struct InspectorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "overview",
        abstract: "One-call overview of a package: shape, audit triage, build/test/docs verdicts."
    )

    @Argument(help: "Package directory or any path inside it.")
    var path: String = "."

    @Flag(name: .customLong("compact"), help: "Return the orientation summary only (counts + verdicts).")
    var compact = false

    @Flag(name: .customLong("skip-build"), help: "Skip the build verdict (faster; build.succeeded is null).")
    var skipBuild = false

    @Flag(name: .customLong("skip-test"), help: "Skip the test verdict (faster; test.succeeded is null).")
    var skipTest = false

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
            print(InspectorReport.jsonSchema)
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
            try emit(InspectorFailureReport(ok: false, target: target, error: "no Package.swift at \(package.path)"))
            throw ExitCode(1)
        }

        let packageDirPath = packageDir.path
        let readme = InspectorCommand.firstParagraph(packageDir: packageDirPath)
        let agents = InspectorCommand.agentsDocument(packageDir: packageDirPath)
        let gitState = await InspectorCommand.gitDiffState(packageDir: packageDirPath)

        // targets + dependencies (the same measurements the standalone
        // subcommands report — never a second implementation)
        let targetEntries: [TargetEntry]
        do {
            targetEntries = try await TargetsEngine.list(packageDir: packageDirPath)
        } catch {
            try emit(InspectorFailureReport(ok: false, target: target, error: "\(error)"))
            throw ExitCode(1)
        }
        let targetRows = targetEntries.map {
            CompactTargetEntry(
                name: $0.name, type: $0.type,
                swiftFileCount: $0.swiftFileCount, totalLines: $0.totalLines, exists: $0.exists
            )
        }

        var largest: [InspectorLargestFile] = []
        for entry in targetEntries {
            for file in entry.largestFiles {
                largest.append(InspectorLargestFile(target: entry.name, path: file.path, lines: file.lines))
            }
        }
        largest = largest.enumerated().sorted { lhs, rhs in
            lhs.element.lines == rhs.element.lines ? lhs.offset < rhs.offset : lhs.element.lines > rhs.element.lines
        }.map(\.element)

        let dependencyEntries = (try? await DependenciesEngine.list(packageDir: packageDirPath)) ?? []
        let riskyKinds: Set<String> = ["from", "range", "branch", "unknown"]
        let risky = dependencyEntries
            .filter { riskyKinds.contains($0.requirementKind) }
            .map { InspectorRiskyDependency(name: $0.name, requirement: $0.requirement, kind: $0.requirementKind) }

        // audit triage
        let audit = StatsEngine.overview(target: target, dependencyEntries: dependencyEntries, packagePath: package.path)
        let auditTopFiles = Array(audit.perFile.prefix(5))

        // build / test verdicts (isolated: the real .build is untouched)
        var buildSucceeded: Bool?
        var buildExitCode: Int?
        if !skipBuild {
            let outcome = try? await BuildRunner.execute(
                BuildRequest(path: target, test: false, timeout: 600, isolated: true)
            )
            buildSucceeded = outcome?.succeeded
            buildExitCode = outcome?.exitCode
        }
        var testSucceeded: Bool?
        var testsTotal: Int?
        var testsFailed: Int?
        if !skipTest {
            let outcome = try? await BuildRunner.execute(
                BuildRequest(path: target, test: true, timeout: 1200, isolated: true)
            )
            testSucceeded = outcome?.succeeded
            testsTotal = outcome?.testsTotal
            testsFailed = outcome?.testsFailed
        }

        // doc coverage
        let catalogs = DocCoverageCommand.findCatalogs(in: packageDirPath)
        let sourcesDir = packageDir.appendingPathComponent("Sources").path
        var coverage: DocCoverageStats?
        if !DocCoverageCommand.subdirectories(of: sourcesDir).isEmpty {
            coverage = DocCoverageCommand.apiCoverage(sourcesPath: sourcesDir, limit: nil)
                ?? DocCoverageCommand.heuristicCoverage(sourcesPath: sourcesDir, limit: nil)
        }
        let coveragePct: Int? = (coverage?.declarations ?? 0) > 0
            ? Int(((coverage?.coverage ?? 0) * 100).rounded())
            : nil

        let linesTotal = targetRows.reduce(0) { $0 + $1.totalLines }
        let coverageText = coveragePct.map(String.init) ?? "None"
        let buildText = buildSucceeded == true ? "builds" : "does not build"
        let head = "\(packageDir.lastPathComponent): \(targetRows.count) target(s), \(linesTotal) source lines"
        let dependencyText = "\(dependencyEntries.count) dependencies "
            + "(\(risky.count) with loose/range/branch/unknown requirements)"
        let auditText = "\(audit.totals.findings) security findings"
        let summary = "\(head), \(dependencyText), \(auditText), "
            + "\(buildText), doc coverage \(coverageText)%."

        let fmt: OutputFormat = prettyPrint ? .json : outputFormat
        if compact {
            let report = InspectorCompactReport(
                ok: true, target: target, packagePath: packageDirPath,
                name: packageDir.lastPathComponent, summary: summary,
                targetCount: targetRows.count, depCount: dependencyEntries.count,
                riskyDepCount: risky.count, findingCount: audit.totals.findings,
                buildSucceeded: buildSucceeded, testSucceeded: testSucceeded,
                docCoveragePct: coveragePct, compact: true
            )
            try writeOutput(try formatObject(report, format: fmt), to: outputPath)
            return
        }

        let report = InspectorReport(
            ok: true, target: target, packagePath: packageDirPath,
            name: packageDir.lastPathComponent, summary: summary,
            readmeIntent: readme, agentsMD: agents, git: gitState,
            targets: targetRows,
            largestFiles: Array(largest.prefix(8)),
            dependencies: InspectorDependencies(
                count: dependencyEntries.count, riskyCount: risky.count,
                risky: Array(risky.prefix(10))
            ),
            audit: InspectorAudit(
                findings: audit.totals.findings,
                severity: audit.totals.severity,
                category: audit.totals.category,
                topFiles: auditTopFiles
            ),
            docs: InspectorDocs(
                coveragePct: coveragePct, catalogCount: catalogs.count,
                documented: coverage?.documented, undocumented: coverage?.undocumented,
                declarations: coverage?.declarations
            ),
            build: InspectorVerdict(succeeded: buildSucceeded, exitCode: buildExitCode),
            test: InspectorTestVerdict(
                succeeded: testSucceeded, testsTotal: testsTotal, testsFailed: testsFailed
            )
        )
        try writeOutput(try formatObject(report, format: fmt), to: outputPath)
    }

    // MARK: - project prose

    /// the README's first paragraph-ish body: every non-blank, non-heading,
    /// non-fence line joined, capped at 400 characters.
    static func firstParagraph(packageDir: String) -> String {
        for name in ["README.md", "README.markdown"] {
            let url = URL(fileURLWithPath: packageDir).appendingPathComponent(name)
            guard let text = readSwiftSource(url.path) else { continue }
            let lines = text.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let body = lines
                .filter { !$0.hasPrefix("#") && !$0.hasPrefix("```") }
                .joined(separator: " ")
            return String(body.prefix(400))
        }
        return ""
    }

    /// the project's AGENTS.md, capped at 4000 characters.
    static func agentsDocument(packageDir: String) -> InspectorAgents {
        for name in ["AGENTS.md", "agents.md", "Agents.md"] {
            let url = URL(fileURLWithPath: packageDir).appendingPathComponent(name)
            guard let text = readSwiftSource(url.path) else { continue }
            return InspectorAgents(
                present: true, path: url.path,
                content: String(text.prefix(4000)), truncated: text.count > 4000
            )
        }
        return InspectorAgents(present: false, path: nil, content: nil, truncated: nil)
    }

    /// the working tree's diff state, with build/VCS noise filtered out so
    /// "dirty" means source the reviewer is actually holding.
    static func gitDiffState(packageDir: String) async -> InspectorGit {
        let outcome: SubprocessOutcome
        do {
            outcome = try await Subprocess.capture(
                "/usr/bin/env",
                ["git", "-C", packageDir, "status", "--porcelain", "--untracked-files=all"],
                timeout: .seconds(15)
            )
        } catch {
            return InspectorGit(dirty: false, note: "not a git repo (or git unavailable)")
        }
        guard outcome.exitCode == 0 else {
            return InspectorGit(dirty: false, note: "not a git repo")
        }
        let changed = outcome.stdout.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if changed.isEmpty {
            return InspectorGit(dirty: false, note: "clean working tree (HEAD)")
        }
        let noise = [".build-audit/", ".build/", "/.swiftpm/", ".git/", "DerivedData"]
        let real = changed.filter { line in !noise.contains { line.contains($0) } }
        if real.isEmpty {
            return InspectorGit(dirty: false, note: "clean working tree (only build artifacts changed)")
        }
        let files = real.map { line -> String in
            let dropped = line.count > 3 ? String(line.dropFirst(3)) : line
            return dropped.trimmingCharacters(in: .whitespaces)
        }
        return InspectorGit(
            dirty: true, changedFileCount: files.count, changedFiles: Array(files.prefix(30)),
            note: "working tree differs from HEAD; these uncommitted changes "
                + "are what a reviewer is likely hardening."
        )
    }
}

// MARK: - audit triage

/// the triage engine behind the inspector's `audit` section: every scan
/// category plus dependency risk in one ranked table.
///
/// the inspector consumes `totals` and `perFile`; the ranked rows are here for
/// any future `stats` surface, and the raw per-category detail lives in `scan`.
enum StatsEngine {
    struct Totals: Sendable {
        let findings: Int
        let severity: [String: Int]
        let category: [String: Int]
    }

    struct Overview: Sendable {
        let totals: Totals
        let perFile: [PerFileRow]
    }

    static func overview(
        target: String,
        dependencyEntries: [DependencyEntry],
        packagePath: String
    ) -> Overview {
        var rows: [StatsRow] = []
        let categories: [(ScanCategory, String)] = [
            (.unsafePtrs, "unsafe_ptr"),
            (.forceUnwraps, "force_unwrap"),
            (.processSafety, "process_safety"),
        ]
        for (scanCategory, rowCategory) in categories {
            for finding in ScanEngine.findings(for: scanCategory, target: target) {
                rows.append(StatsRow(
                    category: rowCategory,
                    severity: findingSeverity(category: rowCategory, finding: finding),
                    file: finding.file, line: finding.line,
                    kind: finding.api ?? finding.kind,
                    context: finding.context ?? "source",
                    reachability: finding.reachability ?? "internal"
                ))
            }
        }
        let riskyKinds: Set<String> = ["from", "range", "branch", "unknown"]
        for dependency in dependencyEntries where riskyKinds.contains(dependency.requirementKind) {
            rows.append(StatsRow(
                category: "dependency",
                severity: findingSeverity(
                    category: "dependency",
                    finding: ScanFinding(
                        file: packagePath, line: -1,
                        api: nil, kind: dependency.requirementKind,
                        match: nil, primary: nil, subkinds: nil, severity: nil,
                        severityHint: nil, context: nil, reachability: nil, relatedLines: nil
                    )
                ),
                file: packagePath, line: -1,
                kind: dependency.requirementKind,
                context: "source", reachability: "internal"
            ))
        }
        for finding in ScanEngine.findings(for: .secrets, target: target) {
            rows.append(StatsRow(
                category: "secret",
                severity: findingSeverity(category: "secret", finding: finding),
                file: finding.file, line: finding.line,
                kind: finding.kind,
                context: finding.context ?? "source",
                reachability: finding.reachability ?? "internal"
            ))
        }

        var severityCounts: [String: Int] = ["critical": 0, "high": 0, "medium": 0, "low": 0]
        var categoryCounts: [String: Int] = [:]
        var perFileCounts: [String: [String: Int]] = [:]
        var perFileOrder: [String] = []
        for row in rows {
            severityCounts[row.severity, default: 0] += 1
            categoryCounts[row.category, default: 0] += 1
            let fileKey = (row.file as NSString).lastPathComponent
            if perFileCounts[fileKey] == nil { perFileOrder.append(fileKey) }
            perFileCounts[fileKey, default: [:]][row.category, default: 0] += 1
        }

        // sorted by -total findings; ties keep first-seen order (the python
        // dict-sort contract).
        let perFile = perFileOrder.enumerated().sorted { lhs, rhs in
            let left = perFileCounts[lhs.element]?.values.reduce(0, +) ?? 0
            let right = perFileCounts[rhs.element]?.values.reduce(0, +) ?? 0
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map { PerFileRow(file: $0.element, counts: perFileCounts[$0.element] ?? [:]) }

        return Overview(
            totals: Totals(
                findings: rows.count, severity: severityCounts, category: categoryCounts
            ),
            perFile: perFile
        )
    }

    /// assign a triage severity to a normalized finding.
    static func findingSeverity(category: String, finding: ScanFinding) -> String {
        let rank: Set<String> = ["critical", "high", "medium", "low"]
        if let stored = finding.severity, rank.contains(stored) { return stored }
        if category == "dependency" {
            return (finding.kind == "from" || finding.kind == "range") ? "medium" : "high"
        }
        if category == "secret" {
            let hint = finding.severityHint ?? "high"
            return rank.contains(hint) ? hint : "high"
        }
        if category == "unsafe_ptr" || category == "process_safety" {
            let api = finding.api ?? ""
            return ["Unmanaged", "unsafeBitCast", "withUnsafeMutableBytes"].contains(api) ? "high" : "medium"
        }
        if category == "force_unwrap" {
            return (finding.primary == "try_force" || finding.primary == "as_cast") ? "high" : "medium"
        }
        return "low"
    }

    /// one normalized triage row.
    struct StatsRow: Sendable {
        let category: String
        let severity: String
        let file: String
        let line: Int
        let kind: String?
        let context: String
        let reachability: String
    }
}

/// a per-file triage row, encoded as the python contract's `[file, {cat: n}]`
/// pair so a consumer can read it positionally.
struct PerFileRow: Encodable, Sendable {
    let file: String
    let counts: [String: Int]

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(file)
        try container.encode(counts)
    }
}

// MARK: - output types

struct InspectorAgents: Codable, Sendable {
    let present: Bool
    let path: String?
    let content: String?
    let truncated: Bool?
}

struct InspectorGit: Codable, Sendable {
    let dirty: Bool
    let changedFileCount: Int?
    let changedFiles: [String]?
    let note: String

    enum CodingKeys: String, CodingKey {
        case dirty, note
        case changedFileCount = "changed_file_count"
        case changedFiles = "changed_files"
    }

    init(dirty: Bool, changedFileCount: Int? = nil, changedFiles: [String]? = nil, note: String) {
        self.dirty = dirty
        self.changedFileCount = changedFileCount
        self.changedFiles = changedFiles
        self.note = note
    }
}

struct InspectorLargestFile: Codable, Sendable {
    let target: String
    let path: String
    let lines: Int
}

struct InspectorRiskyDependency: Codable, Sendable {
    let name: String
    let requirement: String
    let kind: String
}

struct InspectorDependencies: Codable, Sendable {
    let count: Int
    let riskyCount: Int
    let risky: [InspectorRiskyDependency]

    enum CodingKeys: String, CodingKey {
        case count, risky
        case riskyCount = "risky_count"
    }
}

struct InspectorAudit: Encodable, Sendable {
    let findings: Int
    let severity: [String: Int]
    let category: [String: Int]
    let topFiles: [PerFileRow]

    enum CodingKeys: String, CodingKey {
        case findings, severity, category
        case topFiles = "top_files"
    }
}

struct InspectorDocs: Codable, Sendable {
    let coveragePct: Int?
    let catalogCount: Int?
    let documented: Int?
    let undocumented: Int?
    let declarations: Int?

    enum CodingKeys: String, CodingKey {
        case documented, undocumented, declarations
        case coveragePct = "coverage_pct"
        case catalogCount = "catalog_count"
    }
}

/// a build verdict — nulls are meaningful ("not run"), so they encode as `null`
/// rather than being omitted.
struct InspectorVerdict: Codable, Sendable {
    let succeeded: Bool?
    let exitCode: Int?

    enum CodingKeys: String, CodingKey {
        case succeeded
        case exitCode = "exit_code"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(succeeded, forKey: .succeeded)
        try container.encode(exitCode, forKey: .exitCode)
    }
}

struct InspectorTestVerdict: Codable, Sendable {
    let succeeded: Bool?
    let testsTotal: Int?
    let testsFailed: Int?

    enum CodingKeys: String, CodingKey {
        case succeeded
        case testsTotal = "tests_total"
        case testsFailed = "tests_failed"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(succeeded, forKey: .succeeded)
        try container.encode(testsTotal, forKey: .testsTotal)
        try container.encode(testsFailed, forKey: .testsFailed)
    }
}

struct InspectorReport: Encodable, Sendable {
    let ok: Bool
    let target: String
    let packagePath: String
    let name: String
    let summary: String
    let readmeIntent: String
    let agentsMD: InspectorAgents
    let git: InspectorGit
    let targets: [CompactTargetEntry]
    let largestFiles: [InspectorLargestFile]
    let dependencies: InspectorDependencies
    let audit: InspectorAudit
    let docs: InspectorDocs
    let build: InspectorVerdict
    let test: InspectorTestVerdict

    enum CodingKeys: String, CodingKey {
        case ok, target, name, summary, git, targets, dependencies, audit, docs, build, test
        case packagePath = "package_path"
        case readmeIntent = "readme_intent"
        case agentsMD = "agents_md"
        case largestFiles = "largest_files"
    }

    static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "InspectorReport",
      "type": "object",
      "properties": {
        "ok":            { "type": "boolean" },
        "target":        { "type": "string" },
        "package_path":  { "type": "string" },
        "name":          { "type": "string" },
        "summary":       { "type": "string", "description": "One-line orientation verdict" },
        "readme_intent": { "type": "string", "description": "README body, first ~400 chars" },
        "agents_md":     { "type": "object", "description": "present/path/content/truncated" },
        "git":           { "type": "object", "description": "dirty/changed_file_count/changed_files/note" },
        "targets":       { "type": "array", "items": { "type": "object" } },
        "largest_files": { "type": "array", "items": { "type": "object" } },
        "dependencies":  { "type": "object", "description": "count/risky_count/risky" },
        "audit":         { "type": "object", "description": "findings/severity/category/top_files" },
        "docs":          { "type": "object", "description": "coverage_pct/catalog_count/documented/undocumented/declarations" },
        "build":         { "type": "object", "description": "succeeded/exit_code (null when skipped)" },
        "test":          { "type": "object", "description": "succeeded/tests_total/tests_failed (null when skipped)" }
      },
      "required": ["ok", "target", "package_path", "name", "summary", "readme_intent", "agents_md", "git", "targets", "largest_files", "dependencies", "audit", "docs", "build", "test"]
    }
    """
}

struct InspectorCompactReport: Codable, Sendable {
    let ok: Bool
    let target: String
    let packagePath: String
    let name: String
    let summary: String
    let targetCount: Int
    let depCount: Int
    let riskyDepCount: Int
    let findingCount: Int
    let buildSucceeded: Bool?
    let testSucceeded: Bool?
    let docCoveragePct: Int?
    let compact: Bool

    enum CodingKeys: String, CodingKey {
        case ok, target, name, summary, compact
        case packagePath = "package_path"
        case targetCount = "target_count"
        case depCount = "dep_count"
        case riskyDepCount = "risky_dep_count"
        case findingCount = "finding_count"
        case buildSucceeded = "build_succeeded"
        case testSucceeded = "test_succeeded"
        case docCoveragePct = "doc_coverage_pct"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ok, forKey: .ok)
        try container.encode(target, forKey: .target)
        try container.encode(packagePath, forKey: .packagePath)
        try container.encode(name, forKey: .name)
        try container.encode(summary, forKey: .summary)
        try container.encode(targetCount, forKey: .targetCount)
        try container.encode(depCount, forKey: .depCount)
        try container.encode(riskyDepCount, forKey: .riskyDepCount)
        try container.encode(findingCount, forKey: .findingCount)
        try container.encode(buildSucceeded, forKey: .buildSucceeded)
        try container.encode(testSucceeded, forKey: .testSucceeded)
        try container.encode(docCoveragePct, forKey: .docCoveragePct)
        try container.encode(compact, forKey: .compact)
    }
}

struct InspectorFailureReport: Codable, Sendable {
    let ok: Bool
    let target: String
    let error: String
}