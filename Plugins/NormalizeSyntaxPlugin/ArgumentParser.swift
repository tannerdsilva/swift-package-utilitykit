/// Result of parsing the plugin's command-line flags.
struct ParsedArguments {
    /// Line ending target.
    var lineEnding: LineEnding = .lf
    /// Whether to strip trailing whitespace.
    var stripTrailingWhitespace = true
    /// Whether to guarantee a final newline.
    var ensureFinalNewline = true
    /// Whether to collapse runs of blank lines.
    var collapseBlankLines = false
    /// Indentation policy.
    var indentation: Indentation = .spacesToTabs(4)
    /// Whether to minify for LLM consumption.
    var minify = false
    var dryRun = false
    var showHelp = false
}

enum LineEnding {
    case lf
    case crlf
}

enum Indentation {
    case preserve
    case tabsToSpaces(Int)
    case spacesToTabs(Int)
}

struct UsageError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

enum ArgumentParser {

    static func parse(_ arguments: [String]) throws -> ParsedArguments {
        var result = ParsedArguments()
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--help", "-h":
                result.showHelp = true
            case "--dry-run":
                result.dryRun = true
            case "--crlf":
                result.lineEnding = .crlf
            case "--lf":
                result.lineEnding = .lf
            case "--keep-trailing-whitespace":
                result.stripTrailingWhitespace = false
            case "--no-final-newline":
                result.ensureFinalNewline = false
            case "--collapse-blank-lines":
                result.collapseBlankLines = true
            case "--tabs-to-spaces":
                index += 1
                guard index < arguments.count, let n = Int(arguments[index]), n >= 1 else {
                    throw UsageError("--tabs-to-spaces requires a positive integer.")
                }
                result.indentation = .tabsToSpaces(n)
            case "--spaces-to-tabs":
                index += 1
                guard index < arguments.count, let n = Int(arguments[index]), n >= 1 else {
                    throw UsageError("--spaces-to-tabs requires a positive integer.")
                }
                result.indentation = .spacesToTabs(n)
            case "--preserve-indentation":
                result.indentation = .preserve
            case "--minify":
                result.minify = true
            default:
                throw UsageError("Unknown argument: \(arg)")
            }
            index += 1
        }
        return result
    }

    static func printUsage() {
        print("""
        usage: swift package normalize-syntax [options]

        Options:
          --lf                         Use Unix (LF) line endings (default).
          --crlf                       Use Windows (CRLF) line endings.
          --keep-trailing-whitespace   Do not strip trailing whitespace.
          --no-final-newline           Do not guarantee a trailing newline.
          --collapse-blank-lines       Collapse runs of blank lines to one.
          --tabs-to-spaces <n>         Convert leading tabs to <n> spaces.
          --spaces-to-tabs <n>         Convert runs of <n> leading spaces to tabs
                                       (default: 4, i.e. tabs for indent).
          --preserve-indentation       Leave leading whitespace untouched.
          --minify                      Strip indentation and blank lines for
                                        LLM-optimized token efficiency.
          --dry-run                    Report changes without writing files.
          --help                       Show this help.
        """)
    }
}