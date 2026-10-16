import Foundation
import ArgumentParser

/// print the text of a file, with line numbers.
///
/// the read half of read-before-write: an edit verb needs exact `old_text`, and
/// no other verb on either surface returns source text — a measured gap, not a
/// hypothetical one (50.5 % of this model's edit attempts aimed at text it had
/// never read). line numbers are on by default because the next call is usually
/// `edit wrap --lines` or a range read.
///
/// output is bounded by default (400 lines) and NEVER truncates silently: the
/// note says how many lines were withheld and which `--lines` reads on. an
/// explicit `--output-format` switches to structured output (`json`: one
/// compact object with the lines, the total, and the shown range; `jsonl`: one
/// `{"n","text"}` object per line).
///
/// the file does not have to be Swift source — any UTF-8 text file (a
/// `Package.swift`, a README, JSON) is fair game. a file that is not valid
/// UTF-8 is a `failed` EditResult-shaped result (exit 1) — never a crash and
/// never a partial decode.
struct ReadCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Print a file's text with line numbers (bounded, explicit about truncation)."
    )

    @Argument(help: "File to read.")
    var file: String?

    @Option(name: .long, help: "Line range to print (e.g. '10-20'); 1-based, inclusive.")
    var lines: String?

    @Option(name: .long, help: "Stop after this many lines (default 400).")
    var maxLines: Int = 400

    @Flag(name: .long, inversion: .prefixedNo, help: "Prefix each line with its number.")
    var lineNumbers = true

    // note: `OutputFormat` has no `.text` case (json/compact/csv/short/jsonl) —
    // the default output here is the numbered text, and an explicit
    // `--output-format` switches to structured.
    @Option(name: .long, help: "Output format: json, jsonl. Omit for numbered text.")
    var outputFormat: OutputFormat? = nil

    @Option(name: .customLong("output"), help: "Write output to file instead of stdout.")
    var outputPath: String = ""

    @Flag(name: .long, inversion: .prefixedNo, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    mutating func run() throws {
        if schema {
            print(FileRead.jsonSchema)
            return
        }
        guard let file else {
            throw ValidationError("Missing expected argument '<file>'")
        }

        // relative paths are resolved here (the MCP tool layer requires
        // absolute ones); read takes a file, never a directory.
        let resolved = NSString(string: file).standardizingPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) else {
            throw ValidationError("file not found: \(resolved)")
        }
        guard !isDir.boolValue else {
            throw ValidationError("'\(resolved)' is a directory; read takes a file")
        }

        // utf-8 only: a non-utf-8 file is a failed result with a clear note —
        // never a crash and never a partial decode.
        guard let content = try? String(contentsOfFile: resolved, encoding: .utf8) else {
            let result = EditResult(
                file: resolved, modified: false, diff: nil, verified: true,
                warning: "file is not valid UTF-8 text; read refuses to decode it",
                status: .failed
            )
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            print(String(data: try enc.encode(result), encoding: .utf8)!)
            throw ExitCode(1)
        }

        // a trailing newline terminates the last line; it does not open a new
        // one. an empty file has zero lines. this is the one line model the
        // surface numbers — `replace-range` counts by it too (`sourceLines`).
        let allLines = sourceLines(content)
        let total = allLines.count

        // the requested window (default: the whole file), clamped to the file,
        // then capped at `maxLines` with the withhold made explicit.
        let requested: (start: Int, end: Int)
        if let lines {
            requested = try parseLineRange(lines)
        } else {
            requested = (1, total)
        }
        let startIdx = max(0, min(requested.start - 1, total))
        let endIdx = max(startIdx, min(requested.end, total))
        var window = Array(allLines[startIdx..<endIdx])
        let cap = max(1, maxLines)
        var truncated = false
        if window.count > cap {
            window = Array(window.prefix(cap))
            truncated = true
        }

        var note: String?
        if total == 0 {
            note = "the file is empty"
        } else if startIdx >= endIdx {
            note = "range \(requested.start)-\(requested.end) selects no lines; the file has \(total) lines"
        } else if truncated {
            let nextStart = startIdx + window.count + 1
            let nextEnd = min(startIdx + window.count + cap, endIdx)
            note = "truncated: showed \(window.count) of \(endIdx - startIdx) lines; pass --lines \(nextStart)-\(nextEnd) for more"
        }

        let displayed = window.enumerated().map { offset, text in
            FileReadLine(n: startIdx + offset + 1, text: text)
        }

        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let out: String
        if outputFormat == .jsonl {
            // one line-object per output line: the streamable record
            out = try displayed
                .map { String(data: try enc.encode($0), encoding: .utf8)! }
                .joined(separator: "\n")
        } else if outputFormat != nil {
            // json (and the other object formats) carry the whole payload as
            // one compact object — the shape FileRead.jsonSchema documents.
            let payload = FileRead(
                file: resolved,
                totalLines: total,
                range: displayed.isEmpty ? [] : [displayed.first!.n, displayed.last!.n],
                lines: displayed,
                truncated: truncated,
                note: note
            )
            out = String(data: try enc.encode(payload), encoding: .utf8)!
        } else {
            var text = displayed
                .map { lineNumbers ? "\($0.n)\t\($0.text)" : $0.text }
                .joined(separator: "\n")
            if let note {
                text = text.isEmpty ? note : text + "\n" + note
            }
            out = text
        }
        try writeOutput(out, to: outputPath)
    }
}

/// the machine-readable shape of a `read`: what was shown, out of how many
/// lines, and whether anything was withheld.
struct FileRead: Codable, Sendable {
    let file: String
    let totalLines: Int
    /// the first and last line numbers shown (1-based, inclusive); empty when
    /// the request selected no lines.
    let range: [Int]
    let lines: [FileReadLine]
    let truncated: Bool
    let note: String?

    enum CodingKeys: String, CodingKey {
        case file
        case totalLines = "total_lines"
        case range
        case lines
        case truncated
        case note
    }

    static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "FileRead",
      "type": "object",
      "properties": {
        "file":        { "type": "string", "description": "Absolute path of the file that was read" },
        "total_lines": { "type": "integer", "description": "Number of lines in the file; a trailing newline does not open a new line" },
        "range":       { "type": "array", "items": { "type": "integer" }, "description": "First and last line numbers shown, 1-based inclusive; empty when the request selected no lines" },
        "lines":       { "type": "array", "items": { "type": "object", "properties": { "n": { "type": "integer", "description": "1-based line number" }, "text": { "type": "string", "description": "The line's text" } }, "required": ["n", "text"] }, "description": "The shown lines with their numbers" },
        "truncated":   { "type": "boolean", "description": "True when lines were withheld to honour the bound; the note says how to read on" },
        "note":        { "type": ["string", "null"], "description": "Why lines are missing: truncation, a range that selects no lines, or an empty file" }
      },
      "required": ["file", "total_lines", "range", "lines", "truncated"]
    }
    """
}

/// one numbered line of a `read`.
struct FileReadLine: Codable, Sendable {
    let n: Int
    let text: String
}