import Foundation
import ArgumentParser
import SubprocessCore

/// run `swift package clean` as a subprocess and return structured JSON.
///
/// by default this removes **only build artifacts** (`.build/` object files,
/// modules, binaries). the dependency cache (`.build/checkouts/`) is
/// preserved — the next `swift build` recompiles without re-fetching.
///
/// to also destroy cached dependencies, pass `--purge-all`. this is a
/// destructive operation: every dependency is deleted and must be re-fetched
/// from scratch on the next build. only use this when you are certain you
/// want to wipe the entire cache.
struct CleanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "Delete build artifacts. Dependencies are preserved unless --purge-all is passed."
    )

    @Argument(help: "Package directory to clean (default: current directory).")
    var path: String = "."

    @Flag(name: .long, inversion: .prefixedNo, help: "Pretty-print JSON output.")
    var prettyPrint = false

    @Option(name: .long, help: "Output format: json, compact, csv, short.")
    var outputFormat: OutputFormat = .json

    @Flag(name: .long, inversion: .prefixedNo, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    @Flag(
        name: [.customLong("purge-all"), .customLong("destroy-dependencies")],
        help: """
        ⚠️  DESTRUCTIVE: Delete ALL cached dependencies in addition to build artifacts. \
        Every dependency is removed from .build/checkouts/ and must be re-fetched from \
        scratch on the next build. Only use this when you are certain you want to wipe \
        the entire dependency cache.
        """
    )
    var purgeAll = false

    @Flag(name: .customLong("audit"), help: "Non-destructive: sweep stale audit scratch + legacy residue instead of running swift package clean.")
    var audit = false

    func run() async throws {
        if schema {
            print(CleanResult.jsonSchema)
            return
        }

        if audit {
            try runAuditSweep()
            return
        }

        let resolvedPath = NSString(string: path).standardizingPath
        guard FileManager.default.fileExists(atPath: resolvedPath + "/Package.swift") else {
            throw ValidationError("no Package.swift found at \(resolvedPath)")
        }

        let command = purgeAll ? "swift package reset" : "swift package clean"
        let outcome = try await Subprocess.capture(
            "/bin/bash",
            ["-c", command],
            workingDirectory: resolvedPath
        )

        let modeLabel = purgeAll ? "purge-all (dependencies DESTROYED)" : "clean (dependencies preserved)"
        let result = CleanResult(
            success: outcome.exitCode == 0,
            mode: modeLabel,
            directory: resolvedPath,
            output: (outcome.stdout + outcome.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        )

        let fmt: OutputFormat = prettyPrint ? .json : outputFormat
        let outputStr = try formatOutput([result], format: fmt)
        print(outputStr)

        // a clean that failed is a tool failure — the exit code must say so,
        // not only the JSON payload (nested callers treat 0 as success)
        if !result.success {
            throw ExitCode(1)
        }
    }

    /// the audit sweep: remove only what an audit run can own — scratch dirs
    /// abandoned by crashed runs (older than an hour, so a live concurrent
    /// audit is never touched) and legacy pre-ephemeral `.build-audit`
    /// residue.  the package's real `.build` products and sources are never
    /// touched, and `swift package clean` is never run.
    private func runAuditSweep() throws {
        let target = try resolveExistingPath(path)
        let package = packageFileURL(for: target)
        let packageDir = package.deletingLastPathComponent().path

        let fmt: OutputFormat = prettyPrint ? .json : outputFormat
        guard FileManager.default.fileExists(atPath: package.path) else {
            let failure = AuditCleanResult(
                ok: false, cleaned: false, exitCode: nil, target: target,
                packagePath: packageDir, scratchRoot: AuditScratch.root(packageDir: packageDir),
                removedRuns: 0, removedLegacyBuildAudit: false,
                error: "no Package.swift at \(package.path)"
            )
            try writeOutput(try formatObject(failure, format: fmt), to: "")
            throw ExitCode(1)
        }

        let removedRuns = AuditScratch.sweepStaleRuns(packageDir: packageDir)

        // legacy residue from the pre-ephemeral design (deterministic .build-audit)
        let legacy = (packageDir as NSString).appendingPathComponent(".build-audit")
        if FileManager.default.fileExists(atPath: legacy) {
            try? FileManager.default.removeItem(atPath: legacy)
        }

        let result = AuditCleanResult(
            ok: true, cleaned: true, exitCode: 0, target: target,
            packagePath: packageDir,
            scratchRoot: AuditScratch.root(packageDir: packageDir),
            removedRuns: removedRuns,
            removedLegacyBuildAudit: !FileManager.default.fileExists(atPath: legacy),
            error: nil
        )
        try writeOutput(try formatObject(result, format: fmt), to: "")
    }
}

/// the `clean --audit` payload — the package-inspector `clean` contract.
struct AuditCleanResult: Encodable, Sendable {
    let ok: Bool
    let cleaned: Bool
    let exitCode: Int?
    let target: String
    let packagePath: String
    let scratchRoot: String
    let removedRuns: Int
    let removedLegacyBuildAudit: Bool
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok, cleaned, target, error
        case exitCode = "exit_code"
        case packagePath = "package_path"
        case scratchRoot = "scratch_root"
        case removedRuns = "removed_runs"
        case removedLegacyBuildAudit = "removed_legacy_build_audit"
        case note
    }

    /// the human note, present only on a successful sweep (the Python contract).
    var note: String? {
        guard ok else { return nil }
        return "Audit builds use ephemeral scratch dirs under "
            + "<pkg>/.build/swift-package-audit/ that clean up after "
            + "themselves; this swept crashed-run leftovers and legacy "
            + ".build-audit residue. the package's real .build products "
            + "and sources are untouched."
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ok, forKey: .ok)
        try container.encode(cleaned, forKey: .cleaned)
        try container.encodeIfPresent(exitCode, forKey: .exitCode)
        try container.encode(target, forKey: .target)
        try container.encode(packagePath, forKey: .packagePath)
        try container.encode(scratchRoot, forKey: .scratchRoot)
        try container.encode(removedRuns, forKey: .removedRuns)
        try container.encode(removedLegacyBuildAudit, forKey: .removedLegacyBuildAudit)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encodeIfPresent(note, forKey: .note)
    }
}

struct CleanResult: Codable, Sendable, CustomStringConvertible {
    let success: Bool
    let mode: String
    let directory: String
    let output: String

    var description: String {
        "\(directory): \(mode) — success=\(success)"
    }

    static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "CleanResult",
      "type": "object",
      "properties": {
        "success":   { "type": "boolean", "description": "Whether the clean command exited 0" },
        "mode":      { "type": "string", "description": "clean (dependencies preserved) or purge-all (dependencies DESTROYED)" },
        "directory": { "type": "string", "description": "Package directory cleaned" },
        "output":    { "type": "string", "description": "Raw clean command output" }
      },
      "required": ["success", "mode", "directory"]
    }
    """
}
