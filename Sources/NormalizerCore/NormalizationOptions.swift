import Foundation

/// how comments should be handled during normalization.
public enum CommentMode: Sendable, Equatable {
    /// preserve comments as-is (default for non-minified formatting).
    case preserve
    /// replace comment text with a placeholder (`// comment invisible`).
    /// the comment structure (line vs block) and indentation are preserved,
    /// but the content is hidden — useful for LLM-optimized output where
    /// comments waste tokens but removing them entirely would lose context.
    case hide
}

/// a set of syntactic normalization passes to apply to source files.
public struct NormalizationOptions: Sendable, Equatable {
    /// the line ending to normalize files to.
    public var lineEnding: LineEnding
    /// whether to strip trailing whitespace from every line.
    public var stripTrailingWhitespace: Bool
    /// whether to ensure each file ends with exactly one line terminator.
    public var ensureFinalNewline: Bool
    /// whether to collapse runs of consecutive blank lines to a single blank line.
    public var collapseBlankLines: Bool
    /// leading-whitespace policy.
    public var indentation: IndentationPolicy
    /// whether to aggressively minify for LLM consumption (strip indentation,
    /// collapse all runs of whitespace, remove blank lines).
    public var minify: Bool
    /// how to handle comments during normalization.
    public var commentMode: CommentMode

    public enum LineEnding: Sendable, Equatable {
        /// unix newline, "\n". the universal default.
        case lf
        /// windows newline, "\r\n".
        case crlf

        public var stringValue: String {
            switch self {
            case .lf: return "\n"
            case .crlf: return "\r\n"
            }
        }
    }

    public enum IndentationPolicy: Sendable, Equatable {
        /// leave leading whitespace untouched.
        case preserve
        /// replace each leading tab with `tabWidth` spaces.
        case tabsToSpaces(Int)
        /// replace each run of `tabWidth` leading spaces with a single tab.
        case spacesToTabs(Int)
    }

    /// sensible defaults: LF endings, trailing whitespace stripped, a final
    /// newline guaranteed, indentation normalized to tabs (each complete
    /// run of 4 leading spaces becomes one tab), comments preserved.
    public static let standard = NormalizationOptions(
        lineEnding: .lf,
        stripTrailingWhitespace: true,
        ensureFinalNewline: true,
        collapseBlankLines: false,
        indentation: .spacesToTabs(4),
        minify: false,
        commentMode: .preserve
    )

    /// LLM-optimized: strip all indentation, remove blank lines, collapse
    /// whitespace, hide comments, LF endings, no trailing whitespace, final
    /// newline. Based on research showing LLMs maintain accuracy on
    /// unformatted code while saving ~24.5% input tokens.
    public static let minified = NormalizationOptions(
        lineEnding: .lf,
        stripTrailingWhitespace: true,
        ensureFinalNewline: true,
        collapseBlankLines: true,
        indentation: .preserve,
        minify: true,
        commentMode: .hide
    )
}
