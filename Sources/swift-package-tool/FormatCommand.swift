import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParser
import NormalizerCore

/// format or minify Swift source files.
struct FormatCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "format",
        abstract: "Format or minify Swift source files."
    )

    @Argument(help: "Swift source file(s) to format.")
    var files: [String]

    @Flag(name: .long, inversion: .prefixedNo, help: "Minify for LLM consumption (strip all non-semantic whitespace).")
    var minify = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Pretty-print with canonical formatting (default).")
    var pretty = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Report what would change without writing.")
    var dryRun = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Preserve comments in minified output (default: hide with placeholder).")
    var preserveComments = false

    @Option(name: .long, help: "Output format: json, compact. omit for text status lines.")
    var outputFormat: OutputFormat?

    @Flag(name: .long, inversion: .prefixedNo, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    mutating func run() throws {
        if schema {
            print(FormatResult.jsonSchema)
            return
        }
        let useMinify = minify && !pretty

        var results: [FormatResult] = []
        for filePath in files {
            let original: String
            let displayPath: String
            let url: URL?
            if isStdinPath(filePath) {
                original = readSourceFromStdin()
                displayPath = "<stdin>"
                url = nil
            } else {
                let u = URL(fileURLWithPath: filePath)
                original = try String(contentsOf: u, encoding: .utf8)
                displayPath = filePath
                url = u
            }

            let formatted: String
            if useMinify {
                formatted = try minifySource(original, filePath: filePath, preserveComments: preserveComments)
            } else {
                // use the existing NormalizerCore with standard options
                formatted = Normalizer.normalize(original, options: .standard)
            }

            if formatted == original {
                results.append(FormatResult(file: displayPath, status: "unchanged", changed: false))
                if outputFormat == nil && !dryRun { print("\(displayPath): unchanged") }
                continue
            }

            if dryRun {
                results.append(FormatResult(file: displayPath, status: "would change", changed: true, content: outputFormat == nil ? nil : formatted))
                if outputFormat == nil { print("\(displayPath): would change") }
            } else if isStdinPath(filePath) {
                // print to stdout for piping
                if outputFormat == nil {
                    print(formatted)
                } else {
                    results.append(FormatResult(file: displayPath, status: "formatted", changed: true, content: formatted))
                }
            } else {
                try formatted.write(to: url!, atomically: true, encoding: .utf8)
                results.append(FormatResult(file: displayPath, status: "formatted", changed: true))
                if outputFormat == nil { print("\(displayPath): formatted") }
            }
        }

        // JSON/compact mode emits the per-file summary instead of text lines
        if let fmt = outputFormat, fmt == .json || fmt == .compact {
            let outputStr = try formatOutput(results, format: fmt)
            print(outputStr)
        }
    }

    /// per-file status reported by `format` in JSON mode.
struct FormatResult: Codable, Sendable {
    let file: String
    let status: String   // "unchanged", "would change", "formatted"
    let changed: Bool
    let content: String?

    init(file: String, status: String, changed: Bool, content: String? = nil) {
        self.file = file
        self.status = status
        self.changed = changed
        self.content = content
    }

    static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "FormatResult",
      "type": "object",
      "properties": {
        "file":    { "type": "string", "description": "Source file path (or <stdin>)" },
        "status":  { "type": "string", "description": "unchanged, would change, or formatted" },
        "changed": { "type": "boolean", "description": "Whether the file changed or would change" },
        "content": { "type": ["string", "null"], "description": "Formatted content for stdin/dry-run JSON mode" }
      },
      "required": ["file", "status", "changed"]
    }
    """
}

/// AST-safe minification: strip all leading/trailing trivia from tokens
    /// while preserving required single spaces between tokens on the same line,
    /// and keeping one newline between top-level declarations.
    ///
    /// Comments are replaced with a `// comment invisible` placeholder by
    /// default (LLM-optimized). Pass `preserveComments: true` to keep them.
    private func minifySource(_ source: String, filePath: String, preserveComments: Bool) throws -> String {
        let tree = Parser.parse(source: source)
        var result = ""
        var length = 0
        // character ranges the whitespace cleanup must leave alone: the
        // interior of a multi-line string literal is part of its value, not
        // formatting.
        var verbatimRanges: [Range<Int>] = []

        // append text, tracking the character offset needed to record the
        // verbatim ranges below
        func emit(_ text: String) {
            result += text
            length += text.count
        }

        // append text the whitespace cleanup must not touch
        func emitVerbatim(_ text: String) {
            verbatimRanges.append(length..<(length + text.count))
            emit(text)
        }

        // true for tokens whose text must survive the whitespace cleanup
        // verbatim: string-literal segments carry the literal's content
        // (including its final line, which has no trailing newline), and any
        // other token that spans lines does too.
        func hasWhitespaceSignificantText(_ token: TokenSyntax) -> Bool {
            switch token.tokenKind {
            case .stringSegment: return true
            default: return token.text.contains("\n")
            }
        }

        var lastToken: TokenSyntax? = nil
        for token in tree.statements.tokens(viewMode: .sourceAccurate) {
            let leadingTrivia = token.leadingTrivia
            let trailingTrivia = token.trailingTrivia
            let previousTrailing = lastToken?.trailingTrivia ?? []

            // determine if we need a separator before this token. whitespace
            // between two tokens can be attached to either the current token's
            // leading trivia or the previous token's trailing trivia, so both
            // must be inspected.
            let needsNewline: Bool = {
                for piece in leadingTrivia {
                    if case .newlines = piece { return true }
                }
                for piece in previousTrailing {
                    if case .newlines = piece { return true }
                }
                return false
            }()

            let needsSpace: Bool = {
                for piece in leadingTrivia {
                    if case .spaces = piece { return true }
                    if case .tabs = piece { return true }
                }
                for piece in previousTrailing {
                    if case .spaces = piece { return true }
                    if case .tabs = piece { return true }
                }
                return false
            }()

            // handle comments from leading trivia
            var commentPrefix = ""
            for piece in leadingTrivia {
                switch piece {
                case .docLineComment(let text):
                    if preserveComments {
                        commentPrefix += text + "\n"
                    } else {
                        commentPrefix += "/// comment invisible\n"
                    }
                case .docBlockComment(let text):
                    if preserveComments {
                        commentPrefix += text + "\n"
                    } else {
                        commentPrefix += "/// comment invisible\n"
                    }
                case .lineComment(let text):
                    if preserveComments {
                        commentPrefix += text + "\n"
                    } else {
                        commentPrefix += "// comment invisible\n"
                    }
                case .blockComment(let text):
                    if preserveComments {
                        commentPrefix += text + "\n"
                    } else {
                        commentPrefix += "/* comment invisible */\n"
                    }
                default:
                    break
                }
            }

            if !commentPrefix.isEmpty {
                emit(commentPrefix)
            }

            // add separator
            if needsNewline {
                emit("\n")
            } else if needsSpace && !result.isEmpty && !result.hasSuffix("\n") {
                emit(" ")
            }

            // append the token text. string-literal content is emitted
            // verbatim and protected from the whitespace cleanup below — its
            // whitespace is part of the value, not formatting.
            if hasWhitespaceSignificantText(token) {
                emitVerbatim(token.text)
            } else {
                emit(token.text)
            }

            // handle comments from trailing trivia
            for piece in trailingTrivia {
                switch piece {
                case .docLineComment(let text):
                    if preserveComments {
                        emit(" " + text + "\n")
                    } else {
                        emit(" /// comment invisible\n")
                    }
                case .docBlockComment(let text):
                    if preserveComments {
                        emit(" " + text + "\n")
                    } else {
                        emit(" /// comment invisible\n")
                    }
                case .lineComment(let text):
                    if preserveComments {
                        emit(" " + text + "\n")
                    } else {
                        emit(" // comment invisible\n")
                    }
                case .blockComment(let text):
                    if preserveComments {
                        emit(" " + text + "\n")
                    } else {
                        emit(" /* comment invisible */\n")
                    }
                default:
                    break
                }
            }

            lastToken = token
        }

        // clean up: strip per-line whitespace and collapse blank-line runs,
        // leaving the protected (verbatim) ranges untouched
        var cleaned = cleanWhitespace(result, keepingVerbatim: verbatimRanges)

        // ensure exactly one trailing newline
        if !cleaned.hasSuffix("\n") {
            cleaned += "\n"
        }

        return cleaned
    }

    /// strips leading/trailing whitespace from every output line and collapses
    /// runs of three or more newlines to two, leaving `ranges` untouched.
    ///
    /// the ranges protect text whose whitespace is semantic — the interior
    /// lines of multi-line string literals — so minification can never change
    /// a string's value.
    private func cleanWhitespace(_ text: String, keepingVerbatim ranges: [Range<Int>]) -> String {
        var out = ""
        var offset = 0
        var nextRange = ranges.startIndex
        var atLineStart = true
        var pendingWhitespace = ""
        var newlineRun = 0

        func flushPending() {
            out += pendingWhitespace
            pendingWhitespace = ""
        }

        for ch in text {
            while nextRange < ranges.endIndex, offset >= ranges[nextRange].upperBound {
                nextRange += 1
            }
            let isVerbatim = nextRange < ranges.endIndex && ranges[nextRange].contains(offset)

            if isVerbatim {
                flushPending()
                out.append(ch)
                atLineStart = ch == "\n"
                newlineRun = ch == "\n" ? newlineRun + 1 : 0
            } else if ch == "\n" {
                // trailing whitespace before a newline is dropped
                pendingWhitespace = ""
                if newlineRun < 2 {
                    out.append(ch)
                    newlineRun += 1
                }
                atLineStart = true
            } else if ch == " " || ch == "\t" {
                // leading whitespace is dropped; interior whitespace is held
                // until we know the line continues
                if !atLineStart {
                    pendingWhitespace.append(ch)
                }
            } else {
                flushPending()
                out.append(ch)
                atLineStart = false
                newlineRun = 0
            }
            offset += 1
        }

        return out
    }
}
