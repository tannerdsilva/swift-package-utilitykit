import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParser
import SwiftDiagnostics
import SwiftParserDiagnostics

/// shared editing infrastructure for swift-package-tool editing commands.
///
/// provides common flags (--dry-run, --backup, --verify, --diff),
/// file reading/writing with safety checks, and AST re-validation.

// MARK: - Common flags protocol

protocol EditCommand: ParsableCommand {
    var dryRun: Bool { get set }
    var backup: Bool { get set }
    var verify: Bool { get set }
    var showDiff: Bool { get set }
    var outputPath: String { get set }
    var force: Bool { get set }
    var schema: Bool { get set }
    var outputFormat: OutputFormat? { get set }
}

extension EditCommand {
    /// print the EditResult JSON schema and exit when --schema was passed;
    /// returns true when the schema was printed (the caller should return).
    func printSchemaIfRequested() -> Bool {
        if schema {
            print(EditResult.jsonSchema)
            return true
        }
        return false
    }

    /// encode a single EditResult honoring --output-format (default: pretty
    /// JSON, backward compatible with the former hardcoded JSONEncoder).
    func emitEditResult(_ result: EditResult) throws {
        let fmt: OutputFormat = outputFormat ?? .json
        switch fmt {
        case .json:
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(data: try enc.encode(result), encoding: .utf8)!)
        case .compact:
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            print(String(data: try enc.encode(result), encoding: .utf8)!)
        case .short:
            let w = result.warning.map { " warning: \($0)" } ?? ""
            print("\(result.file): modified=\(result.modified) verified=\(result.verified)\(w)")
        case .csv, .jsonl:
            // single object — emit as one-element rows/lines
            let out = try formatOutput([result], format: fmt)
            print(out)
        }
    }
}

// MARK: - Edit result

struct EditResult: Codable, Sendable {
    let file: String
    let modified: Bool
    let diff: String?
    let verified: Bool
    let warning: String?

    static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "EditResult",
      "type": "object",
      "properties": {
        "file":     { "type": "string", "description": "Edited file path" },
        "modified": { "type": "boolean", "description": "Whether the file changed" },
        "diff":     { "type": ["string", "null"], "description": "Unified diff when shown" },
        "verified": { "type": "boolean", "description": "Whether the edit passed syntactic re-validation" },
        "warning":  { "type": ["string", "null"], "description": "Verification warning when the write was blocked or forced" }
      },
      "required": ["file", "modified", "verified"]
    }
    """
}

// MARK: - File editing helpers

enum FileEditor {

    /// Read a file, apply a transform, optionally verify, optionally write.
    /// Returns an EditResult describing what happened.
    static func edit(
        file: String,
        dryRun: Bool,
        backup: Bool,
        verify: Bool,
        showDiff: Bool,
        outputPath: String,
        force: Bool,
        transform: (inout String) -> String
    ) throws -> EditResult {
        let resolved = NSString(string: file).standardizingPath
        guard FileManager.default.fileExists(atPath: resolved) else {
            throw ValidationError("file not found: \(resolved)")
        }

        let original = try String(contentsOfFile: resolved, encoding: .utf8)
        var modified = original
        let warning = transform(&modified)

        guard modified != original else {
            return EditResult(file: resolved, modified: false, diff: nil, verified: true, warning: nil)
        }

        // Verify syntactic validity if requested
        var verified = true
        var verifyWarning: String? = nil
        if verify {
            let tree = Parser.parse(source: modified)
            let diags = ParseDiagnosticsGenerator.diagnostics(for: tree)
            if !diags.isEmpty {
                let errors = diags.filter { $0.diagMessage.severity == .error }
                if !errors.isEmpty {
                    verified = false
                    verifyWarning = "edit introduced \(errors.count) syntax error(s); use --force to write anyway"
                }
            }
        }

        // Compute diff — always show on dry-run, or when --show-diff is set
        var diff: String? = nil
        if showDiff || dryRun {
            diff = makeDiff(original: original, modified: modified)
        }

        if dryRun {
            return EditResult(file: resolved, modified: true, diff: diff, verified: verified, warning: verifyWarning)
        }

        // Block the write when verification fails unless --force is set
        if !verified && !force {
            return EditResult(file: resolved, modified: false, diff: diff, verified: false, warning: verifyWarning)
        }

        // Backup
        if backup {
            try FileManager.default.copyItem(atPath: resolved, toPath: resolved + ".bak")
        }

        // Write
        let target = outputPath.isEmpty ? resolved : outputPath
        try modified.write(toFile: target, atomically: true, encoding: .utf8)

        return EditResult(file: resolved, modified: true, diff: diff, verified: verified, warning: verifyWarning)
    }

    /// Generate a simple unified diff between two strings.
    static func makeDiff(original: String, modified: String) -> String {
        let origLines = original.components(separatedBy: "\n")
        let modLines = modified.components(separatedBy: "\n")
        var result = ""

        // longest-common-subsequence diff: unchanged lines are aligned so an
        // insertion or deletion in the middle doesn't flag the whole tail of
        // the file as changed.
        var matrix = Array(
            repeating: Array(repeating: 0, count: modLines.count + 1),
            count: origLines.count + 1
        )
        for i in stride(from: origLines.count - 1, through: 0, by: -1) {
            for j in stride(from: modLines.count - 1, through: 0, by: -1) {
                if origLines[i] == modLines[j] {
                    matrix[i][j] = matrix[i + 1][j + 1] + 1
                } else {
                    matrix[i][j] = max(matrix[i + 1][j], matrix[i][j + 1])
                }
            }
        }

        var i = 0
        var j = 0
        while i < origLines.count && j < modLines.count {
            if origLines[i] == modLines[j] {
                i += 1
                j += 1
            } else if matrix[i + 1][j] >= matrix[i][j + 1] {
                result += "-\(origLines[i])\n"
                i += 1
            } else {
                result += "+\(modLines[j])\n"
                j += 1
            }
        }
        while i < origLines.count {
            result += "-\(origLines[i])\n"
            i += 1
        }
        while j < modLines.count {
            result += "+\(modLines[j])\n"
            j += 1
        }

        return result
    }

    /// Process content string from CLI arguments, converting literal `\n`
    /// sequences to actual newline characters.
    ///
    /// When a user passes `--content "line1\nline2"` from the shell, the
    /// shell sends `\n` as two literal characters (backslash + n). This
    /// helper converts them to real newlines so multi-line insertions work.
    ///
    /// To insert a literal backslash-n sequence, escape it: `"\\n"`.
    static func processMultilineContent(_ content: String) -> String {
        content.replacingOccurrences(of: "\\n", with: "\n")
    }

    /// Compute indentation string from a source line.
    static func detectIndent(_ line: String) -> String {
        var indent = ""
        for ch in line {
            if ch == " " || ch == "\t" {
                indent.append(ch)
            } else {
                break
            }
        }
        return indent
    }
}
