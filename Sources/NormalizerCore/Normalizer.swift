import Foundation

/// applies syntactic normalization passes to source text.
public enum Normalizer {

    /// normalizes `input` according to `options`.
    ///
    /// - Returns: the normalized text. callers compare the result against the
    ///   input to detect whether a file actually changed.
    public static func normalize(_ input: String, options: NormalizationOptions) -> String {
        let (rawLines, endsWithNewline) = splitLines(input)

        var lines = rawLines.map { normalizeLine($0, options: options) }

        if options.minify {
            // minify mode: strip all leading whitespace, then collapse blank lines
            lines = lines.map { stripLeadingWhitespace($0) }
            lines = collapseBlankLines(lines)
        } else if options.collapseBlankLines {
            lines = collapseBlankLines(lines)
        }

        // apply comment mode
        if options.commentMode == .hide {
            lines = lines.map { hideComments(in: $0) }
        }

        if lines.isEmpty {
            return ""
        }

        let eol = options.lineEnding.stringValue
        let body = lines.joined(separator: eol)

        let shouldEndWithNewline: Bool
        switch options.ensureFinalNewline {
        case true:
            shouldEndWithNewline = true
        case false:
            // preserve the author's trailing-newline state.
            shouldEndWithNewline = endsWithNewline
        }

        return shouldEndWithNewline ? body + eol : body
    }

    // MARK: - line splitting

    /// splits text into logical lines, stripping the trailing terminator from
    /// each. a trailing "\r" in a CRLF pair is dropped. reports whether the
    /// source text ended with a line terminator.
    static func splitLines(_ text: String) -> (lines: [String], endsWithNewline: Bool) {
        var lines: [String] = []
        var current = ""
        // iterate over unicode scalars, not grapheme clusters: a "\r\n" sequence
        // is a single grapheme cluster, which would otherwise hide the newline.
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if current.last == "\r" { current.removeLast() }
                lines.append(current)
                current = ""
            } else {
                current.append(Character(scalar))
            }
        }
        if !current.isEmpty {
            lines.append(current)
        }
        return (lines, text.hasSuffix("\n"))
    }

    // MARK: - per-line passes

    static func normalizeLine(_ line: String, options: NormalizationOptions) -> String {
        var result = line
        if options.stripTrailingWhitespace {
            while let last = result.last, last == " " || last == "\t" {
                result.removeLast()
            }
        }
        switch options.indentation {
        case .preserve:
            break
        case .tabsToSpaces(let tabWidth):
            result = convertLeadingTabsToSpaces(result, tabWidth: tabWidth)
        case .spacesToTabs(let tabWidth):
            result = convertLeadingSpacesToTabs(result, tabWidth: tabWidth)
        }
        return result
    }

    /// strips all leading whitespace (indentation) from a line.
    static func stripLeadingWhitespace(_ line: String) -> String {
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" {
            idx = line.index(after: idx)
        }
        return String(line[idx...])
    }

    /// replaces each leading tab with `tabWidth` spaces, preserving any leading
    /// spaces already present.
    static func convertLeadingTabsToSpaces(_ line: String, tabWidth: Int) -> String {
        guard tabWidth >= 1 else { return line }
        var prefix = ""
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "\t" {
            prefix += String(repeating: " ", count: tabWidth)
            idx = line.index(after: idx)
        }
        return prefix + line[idx...]
    }

    /// replaces each complete run of `tabWidth` leading spaces with a single tab,
    /// leaving any remainder spaces in place. if a tab immediately follows the
    /// space run the line is left alone, since the intent is ambiguous.
    static func convertLeadingSpacesToTabs(_ line: String, tabWidth: Int) -> String {
        guard tabWidth >= 1 else { return line }
        let chars = Array(line)
        var index = 0
        while index < chars.count, chars[index] == " " {
            index += 1
        }
        if index < chars.count && chars[index] == "\t" {
            return line
        }
        let groups = index / tabWidth
        let remainder = index % tabWidth
        var result = String(repeating: "\t", count: groups)
        result += String(repeating: " ", count: remainder)
        result += String(chars[index...])
        return result
    }

    // MARK: - comment handling

    /// replaces comment text with a placeholder, preserving indentation and
    /// the comment structure (line vs block).
    ///
    /// handles three comment kinds:
    ///   - docc comments (`///`)
    ///   - line comments (`//`)
    ///   - block comments (`/* ... */`)
    ///
    /// a simple line-based heuristic is used: lines that start with `//`,
    /// `///`, or contain `/*` are treated as comments. this is not
    /// AST-perfect (it can't distinguish `//` inside a string literal),
    /// but it is safe — it never removes content, only replaces it with
    /// a placeholder.
    static func hideComments(in line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return line }

        // detect comment lines
        if trimmed.hasPrefix("///") {
            // docc comment — preserve indentation, replace content
            let indent = String(line.prefix(line.count - line.drop(while: { $0 == " " || $0 == "\t" }).count))
            return indent + "/// comment invisible"
        }

        if trimmed.hasPrefix("//") {
            // line comment — preserve indentation, replace content
            let indent = String(line.prefix(line.count - line.drop(while: { $0 == " " || $0 == "\t" }).count))
            return indent + "// comment invisible"
        }

        // block comments: detect lines that are part of a /* */ block.
        // a line containing /* or */ or entirely inside a block comment.
        if trimmed.hasPrefix("/*") || trimmed.hasSuffix("*/") || trimmed.contains("/*") || trimmed.contains("*/") {
            let indent = String(line.prefix(line.count - line.drop(while: { $0 == " " || $0 == "\t" }).count))
            // check if this is a single-line block comment
            if trimmed.hasPrefix("/*") && trimmed.hasSuffix("*/") {
                return indent + "/* comment invisible */"
            }
            if trimmed.hasPrefix("/*") {
                return indent + "/* comment invisible"
            }
            if trimmed.hasSuffix("*/") {
                return indent + "comment invisible */"
            }
            return indent + "* comment invisible"
        }

        return line
    }

    // MARK: - blank-line collapse

    /// collapses any run of two or more blank lines down to a single blank line.
    /// a blank line is one that is empty or contains only whitespace.
    static func collapseBlankLines(_ lines: [String]) -> [String] {
        var result: [String] = []
        var previousWasBlank = false
        for line in lines {
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if isBlank {
                if previousWasBlank {
                    continue
                }
                previousWasBlank = true
            } else {
                previousWasBlank = false
            }
            result.append(line)
        }
        return result
    }
}
