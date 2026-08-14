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

    @Flag(name: .long, help: "Minify for LLM consumption (strip all non-semantic whitespace).")
    var minify = false

    @Flag(name: .long, help: "Pretty-print with canonical formatting (default).")
    var pretty = false

    @Flag(name: .long, help: "Report what would change without writing.")
    var dryRun = false

    mutating func run() throws {
        let useMinify = minify && !pretty

        for filePath in files {
            let url = URL(fileURLWithPath: filePath)
            let original = try String(contentsOf: url, encoding: .utf8)

            let formatted: String
            if useMinify {
                formatted = try minifySource(original, filePath: filePath)
            } else {
                // use the existing NormalizerCore with standard options
                formatted = Normalizer.normalize(original, options: .standard)
            }

            if formatted == original {
                if !dryRun { print("\(filePath): unchanged") }
                continue
            }

            if dryRun {
                print("\(filePath): would change")
            } else {
                try formatted.write(to: url, atomically: true, encoding: .utf8)
                print("\(filePath): formatted")
            }
        }
    }

    /// AST-safe minification: strip all leading/trailing trivia from tokens
    /// while preserving required single spaces between tokens on the same line,
    /// and keeping one newline between top-level declarations.
    private func minifySource(_ source: String, filePath: String) throws -> String {
        let tree = Parser.parse(source: source)
        var result = ""
        var lastEndPosition = AbsolutePosition(utf8Offset: 0)

        for token in tree.statements.tokens(viewMode: .sourceAccurate) {
            let leadingTrivia = token.leadingTrivia
            let trailingTrivia = token.trailingTrivia

            // determine if we need a separator before this token
            let needsNewline: Bool = {
                // check if original had a newline in leading trivia
                for piece in leadingTrivia {
                    if case .newlines = piece { return true }
                }
                return false
            }()

            let needsSpace: Bool = {
                // if original had any whitespace (space/tab) in leading trivia, keep a space
                for piece in leadingTrivia {
                    if case .spaces = piece { return true }
                    if case .tabs = piece { return true }
                }
                return false
            }()

            // preserve doc comments and regular comments from leading trivia
            var commentPrefix = ""
            for piece in leadingTrivia {
                switch piece {
                case .docLineComment(let text):
                    commentPrefix += text + "\n"
                case .docBlockComment(let text):
                    commentPrefix += text + "\n"
                case .lineComment(let text):
                    commentPrefix += text + "\n"
                case .blockComment(let text):
                    commentPrefix += text + "\n"
                default:
                    break
                }
            }

            if !commentPrefix.isEmpty {
                result += commentPrefix
            }

            // add separator
            if needsNewline {
                result += "\n"
            } else if needsSpace && !result.isEmpty && !result.hasSuffix("\n") {
                result += " "
            }

            // append the token text
            result += token.text

            // preserve trailing comments
            for piece in trailingTrivia {
                switch piece {
                case .docLineComment(let text):
                    result += " " + text + "\n"
                case .docBlockComment(let text):
                    result += " " + text + "\n"
                case .lineComment(let text):
                    result += " " + text + "\n"
                case .blockComment(let text):
                    result += " " + text + "\n"
                default:
                    break
                }
            }
        }

        // clean up: collapse runs of newlines to at most one
        var cleaned = result
        // remove leading/trailing whitespace per line
        cleaned = cleaned.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")

        // collapse 3+ newlines to 2 (one blank line between top-level decls)
        while cleaned.contains("\n\n\n") {
            cleaned = cleaned.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        // ensure exactly one trailing newline
        if !cleaned.hasSuffix("\n") {
            cleaned += "\n"
        }

        return cleaned
    }
}
