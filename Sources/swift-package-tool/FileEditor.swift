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
    /// JSON, backward compatible with the former hardcoded JSONEncoder), then
    /// make the process exit code tell the same story the payload does: an
    /// edit that missed its selector, was blocked by verification, or failed
    /// exits 1 AFTER the payload is printed — the same print-then-throw shape
    /// `validate`, `clean` and `build` use. usage errors stay exit 64
    /// (ArgumentParser's ValidationError).
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
        if result.status.isFailure {
            throw ExitCode(1)
        }
    }
}

// MARK: - Edit result

/// the machine-readable outcome of an edit. the process exit code mirrors it
/// for the failure cases, so a caller that only reads `$?` still knows the
/// edit did not happen.
enum EditStatus: String, Codable, Sendable {
    /// the edit applied (or, under --dry-run, would apply).
    case applied
    /// the file already satisfies the requested edit; nothing to do.
    case alreadyCurrent
    /// the selector matched nothing — the edit could not be applied.
    case missed
    /// the write was withheld: re-parse found syntax errors and --force was not set.
    case blocked
    /// the operation errored before it could apply (batch: unreadable file, unknown command).
    case failed

    /// failure statuses print the payload and then exit non-zero.
    var isFailure: Bool { self == .missed || self == .blocked || self == .failed }
}

struct EditResult: Codable, Sendable {
    let file: String
    let modified: Bool
    let diff: String?
    let verified: Bool
    let warning: String?
    let status: EditStatus
    /// whether this result describes a preview rather than a write: `modified`
    /// says the TRANSFORM would change the file; `dryRun: true` says the file on
    /// disk did not change.
    let dryRun: Bool?
    /// on a miss, the closest lines to the selector that matched nothing, best
    /// first, numbered and capped — the material for a correct retry.
    let suggestions: [LineSuggestion]?

    /// explicit init: fields added after 3.0 default to `nil`, so a result that
    /// has nothing new to say omits the key rather than inventing a value; the
    /// sites that do know pass them.
    init(
        file: String,
        modified: Bool,
        diff: String?,
        verified: Bool,
        warning: String?,
        status: EditStatus,
        dryRun: Bool? = nil,
        suggestions: [LineSuggestion]? = nil
    ) {
        self.file = file
        self.modified = modified
        self.diff = diff
        self.verified = verified
        self.warning = warning
        self.status = status
        self.dryRun = dryRun
        self.suggestions = suggestions
    }

    static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "EditResult",
      "type": "object",
      "properties": {
        "file":     { "type": "string", "description": "Edited file path" },
        "modified": { "type": "boolean", "description": "Whether the transform would change (or did change) the file — on a preview this describes the diff, not the write" },
        "dryRun":   { "type": ["boolean", "null"], "description": "True when nothing was written: the file on disk did not change" },
        "diff":     { "type": ["string", "null"], "description": "Unified diff when shown" },
        "verified": { "type": "boolean", "description": "Whether the edit passed syntactic re-validation" },
        "warning":  { "type": ["string", "null"], "description": "Diagnostic note: why an edit selected nothing, or the verification warning when the write was blocked or forced" },
        "suggestions": { "type": ["array", "null"], "items": { "type": "object", "properties": { "n": { "type": "integer", "description": "1-based line number" }, "text": { "type": "string", "description": "The line's text" } }, "required": ["n", "text"] }, "description": "On a miss: the closest lines to the selector, best first, each numbered — capped at 3, text truncated at 160 characters" },
        "status":   { "type": "string", "enum": ["applied", "alreadyCurrent", "missed", "blocked", "failed"], "description": "Machine-readable outcome: exit 0 for applied/alreadyCurrent; exit 1 after this payload for missed/blocked/failed" }
      },
      "required": ["file", "modified", "verified", "status"]
    }
    """
}

// MARK: - File editing helpers

enum FileEditor {

    /// why a transform changed nothing. the transform is the one place that
    /// knows whether its selector missed or the file already satisfied the
    /// request — the two are not the same outcome.
    enum NoChange {
        /// the requested edit could not be applied — its selector matched
        /// nothing. `selector` is the exact text the transform searched for,
        /// when it knows one; it feeds the near-miss suggestions (`nil` for a
        /// range/state miss, where line suggestions would not help).
        case missed(String, selector: String?)
        /// the file already satisfies the requested edit.
        case alreadyCurrent(String)
    }

    /// Read a file, apply a transform, optionally verify, optionally write.
    /// Returns an EditResult describing what happened, including the
    /// machine-readable status the process exit code mirrors.
    static func edit(
        file: String,
        dryRun: Bool,
        backup: Bool,
        verify: Bool,
        showDiff: Bool,
        outputPath: String,
        force: Bool,
        transform: (inout String) throws -> NoChange?
    ) throws -> EditResult {
        let resolved = NSString(string: file).standardizingPath
        guard FileManager.default.fileExists(atPath: resolved) else {
            throw ValidationError("file not found: \(resolved)")
        }

        let original = try String(contentsOfFile: resolved, encoding: .utf8)
        var modified = original
        let noChange = try transform(&modified)

        guard modified != original else {
            // a transform that changed nothing may still have something to say
            // — an anchor that did not match, a range that selected no lines.
            // surface it instead of reporting a silent no-op. a miss is a
            // failure (exit 1); an already-satisfied state is a benign skip
            // (exit 0).
            switch noChange {
            case .some(.missed(let note, let selector)):
                // a miss must teach: the closest lines (numbered) turn a dead
                // end into a retry, and the first one is named in the warning
                // so a text-only consumer gets the hint too.
                var warning = note
                var suggestions: [LineSuggestion]? = nil
                if let selector {
                    let closest = SelectorSuggestions.closest(to: selector, in: original)
                    if !closest.isEmpty {
                        suggestions = closest
                        warning += "; nearest: line \(closest[0].n): \(closest[0].text)"
                    }
                }
                return EditResult(
                    file: resolved, modified: false, diff: nil, verified: true,
                    warning: warning, status: .missed, dryRun: dryRun, suggestions: suggestions
                )
            case .some(.alreadyCurrent(let note)):
                return EditResult(
                    file: resolved, modified: false, diff: nil, verified: true,
                    warning: note, status: .alreadyCurrent, dryRun: dryRun
                )
            case .none:
                return EditResult(
                    file: resolved, modified: false, diff: nil, verified: true,
                    warning: nil, status: .alreadyCurrent, dryRun: dryRun
                )
            }
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
            // the preview mirrors the real run's verdict: what would land,
            // and whether verification would let it land
            return EditResult(
                file: resolved, modified: true, diff: diff, verified: verified,
                warning: verifyWarning, status: verified ? .applied : .blocked, dryRun: dryRun
            )
        }

        // Block the write when verification fails unless --force is set
        if !verified && !force {
            return EditResult(
                file: resolved, modified: false, diff: diff, verified: false,
                warning: verifyWarning, status: .blocked, dryRun: dryRun
            )
        }

        // Backup
        if backup {
            try backupFile(resolved)
        }

        // Write
        let target = outputPath.isEmpty ? resolved : outputPath
        try modified.write(toFile: target, atomically: true, encoding: .utf8)

        return EditResult(
            file: resolved, modified: true, diff: diff, verified: verified,
            warning: verifyWarning, status: .applied, dryRun: dryRun
        )
    }

    /// copy `path` to `<path>.bak`, replacing any previous backup. a stale
    /// backup must never block an edit.
    static func backupFile(_ path: String) throws {
        let backupPath = path + ".bak"
        if FileManager.default.fileExists(atPath: backupPath) {
            try FileManager.default.removeItem(atPath: backupPath)
        }
        try FileManager.default.copyItem(atPath: path, toPath: backupPath)
    }

    // notes a transform returns when it changed nothing. a `missed` note is a
    // failure (exit 1); an `alreadyCurrent` note is a benign skip (exit 0).
    static func noLineContaining(_ pattern: String) -> NoChange {
        .missed("no line containing '\(pattern)' found", selector: pattern)
    }
    static func noOccurrenceOf(_ text: String) -> NoChange {
        .missed("no occurrence of '\(text)' found", selector: text)
    }
    static func alreadyImported(_ module: String) -> NoChange { .alreadyCurrent("module '\(module)' already imported") }
    static func rangeSelectsNoLines(_ range: String) -> NoChange {
        // a range miss has no text selector to be close to
        .missed("line range '\(range)' selects no lines", selector: nil)
    }
    static func noTypeNamed(_ name: String) -> NoChange {
        .missed("no type '\(name)' found", selector: name)
    }
    static func noDeclarationNamed(_ name: String) -> NoChange {
        .missed("no declaration '\(name)' found", selector: name)
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

    /// Interpret the backslash escapes a shell leaves in edit content.
    ///
    /// A shell passes `--content "line1\nline2"` as two literal characters
    /// (backslash + n), so the content-bearing commands expand the escapes
    /// here: `\n` becomes a newline and `\\` becomes a single backslash.
    /// Every other backslash sequence passes through untouched — code being
    /// edited routinely contains `\"`, `\t` or a regex `\d`, and none of those
    /// may be rewritten.
    ///
    /// To place a literal backslash-n in a file (a Swift string-literal
    /// escape, say), escape the backslash: `\\n`.
    ///
    /// A caller whose content is already exact bytes — anything that builds
    /// its arguments as data rather than through a shell — passes
    /// `--literal-content` to skip this interpretation entirely (see
    /// ``content(_:literal:)``).
    static func processMultilineContent(_ content: String) -> String {
        var out = ""
        out.reserveCapacity(content.count)
        var iterator = content.makeIterator()
        var pending: Character? = nil
        while let ch = pending ?? iterator.next() {
            pending = nil
            guard ch == "\\" else {
                out.append(ch)
                continue
            }
            guard let next = iterator.next() else {
                // a trailing lone backslash is content, not an escape
                out.append(ch)
                break
            }
            switch next {
            case "n": out.append("\n")
            case "\\": out.append("\\")
            default:
                // an unrecognized sequence stays exactly as written
                out.append(ch)
                pending = next
            }
        }
        return out
    }

    /// The CLI's escape expansion, skipped when the caller declares its bytes
    /// already exact (`--literal-content`).
    static func content(_ raw: String, literal: Bool) -> String {
        literal ? raw : processMultilineContent(raw)
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
