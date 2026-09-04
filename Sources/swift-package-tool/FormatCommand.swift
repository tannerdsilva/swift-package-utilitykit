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

    mutating func run() throws {
        let useMinify = minify && !pretty

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
                if !dryRun { print("\(displayPath): unchanged") }
                continue
            }

            if dryRun {
                print("\(displayPath): would change")
            } else if isStdinPath(filePath) {
                // print to stdout for piping
                print(formatted)
            } else {
                try formatted.write(to: url!, atomically: true, encoding: .utf8)
                print("\(displayPath): formatted")
            }
        }
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

            // handle comments from trailing trivia
            for piece in trailingTrivia {
                switch piece {
                case .docLineComment(let text):
                    if preserveComments {
                        result += " " + text + "\n"
                    } else {
                        result += " /// comment invisible\n"
                    }
                case .docBlockComment(let text):
                    if preserveComments {
                        result += " " + text + "\n"
                    } else {
                        result += " /// comment invisible\n"
                    }
                case .lineComment(let text):
                    if preserveComments {
                        result += " " + text + "\n"
                    } else {
                        result += " // comment invisible\n"
                    }
                case .blockComment(let text):
                    if preserveComments {
                        result += " " + text + "\n"
                    } else {
                        result += " /* comment invisible */\n"
                    }
                default:
                    break
                }
            }

            lastToken = token
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
