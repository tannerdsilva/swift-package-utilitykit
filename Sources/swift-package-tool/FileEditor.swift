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
}

// MARK: - Edit result

struct EditResult: Codable, Sendable {
    let file: String
    let modified: Bool
    let diff: String?
    let verified: Bool
    let warning: String?
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

        // Simple line-by-line diff
        var i = 0
        while i < max(origLines.count, modLines.count) {
            let orig = i < origLines.count ? origLines[i] : nil
            let mod = i < modLines.count ? modLines[i] : nil
            if orig != mod {
                if let o = orig { result += "-\(o)\n" }
                if let m = mod { result += "+\(m)\n" }
            }
            i += 1
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
