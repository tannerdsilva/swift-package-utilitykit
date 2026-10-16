import Foundation

/// the nearest lines to a selector that missed, so an agent can correct itself.
///
/// ranking is deliberately simple and dependency-free. normalise (trim, collapse
/// runs of whitespace), then score each line by token-set overlap with the
/// selector. ties — and the recorded miss is a tie — break toward the line that
/// can actually be retried:
///
/// 1. a code line beats a comment line. prose that merely shares a word is not
///    the text the caller was aiming at.
/// 2. the line whose leading token matches the selector's — the word the eye
///    lands on first, and the one a retry keeps.
/// 3. the nearest indentation, since a caller quoting a line usually keeps its
///    depth and a different depth is a different context.
/// 4. line order (stable).
///
/// the failure this answers is measured, not hypothetical: a model aiming at
/// `return "50"` in a file that says `return "0"` — and whose doc comment on an
/// earlier line also says "return" — was handed the doc comment first, by the
/// old tie-break of line order alone. the list is capped — at most
/// ``maxSuggestions`` lines, each truncated at ``maxLineChars`` characters — so a
/// suggestion can never leak a whole file.
enum SelectorSuggestions {
    static let maxSuggestions = 3
    static let maxLineChars = 160

    /// one scored line, with the tie-break evidence that ranked it.
    private struct Candidate {
        let n: Int
        let text: String
        let score: Int
        let isComment: Bool
        let leadsWithSelectorToken: Bool
        let indentDistance: Int
    }

    /// the closest lines to `selector`, best first, each with its 1-based
    /// number; empty when no line shares a token with the selector.
    static func closest(to selector: String, in text: String) -> [LineSuggestion] {
        let selectorNormalized = normalize(selector)
        let selectorTokens = tokens(of: selectorNormalized)
        guard !selectorTokens.isEmpty else { return [] }
        let selectorLeading = leadingToken(of: selectorNormalized)
        let selectorIndent = indentWidth(of: selector)

        var candidates: [Candidate] = []
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // blank and punctuation-only lines share no vocabulary with any
            // meaningful selector; they would only crowd out real candidates.
            if line.isEmpty || isNoise(line) { continue }
            let normalized = normalize(line)
            let score = normalized == selectorNormalized
                ? Int.max  // exact normalised equality wins outright
                : selectorTokens.intersection(tokens(of: normalized)).count
            guard score > 0 else { continue }
            candidates.append(Candidate(
                n: index + 1,
                text: truncate(line),
                score: score,
                isComment: isComment(line),
                leadsWithSelectorToken: leadingToken(of: normalized) == selectorLeading,
                indentDistance: abs(indentWidth(of: raw) - selectorIndent)
            ))
        }

        let ranked = candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            // a tie is where the recorded miss went wrong: the earlier line was
            // a doc comment that shared one word, and the code line the retry
            // needed came second.
            if lhs.isComment != rhs.isComment { return !lhs.isComment }
            if lhs.leadsWithSelectorToken != rhs.leadsWithSelectorToken { return lhs.leadsWithSelectorToken }
            if lhs.indentDistance != rhs.indentDistance { return lhs.indentDistance < rhs.indentDistance }
            return lhs.n < rhs.n
        }
        return ranked.prefix(maxSuggestions).map { LineSuggestion(n: $0.n, text: $0.text) }
    }

    /// trim and collapse whitespace runs: `let  x =  1` and `let x = 1` are
    /// the same line to a reader.
    static func normalize(_ line: String) -> String {
        line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// the identifier-ish tokens of a line: runs of letters, digits and
    /// underscores. every other character (quotes, punctuation, operators)
    /// separates — so `return "50"` and `return "0"` still share `return`.
    static func tokens(of line: String) -> Set<String> {
        var set = Set<String>()
        var current = ""
        for character in line {
            if character.isLetter || character.isNumber || character == "_" {
                current.append(character)
            } else if !current.isEmpty {
                set.insert(current)
                current = ""
            }
        }
        if !current.isEmpty { set.insert(current) }
        return set
    }

    /// a line that is only punctuation (`}`, `});`) cannot teach a selector
    /// anything.
    static func isNoise(_ line: String) -> Bool {
        line.allSatisfy { !($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// whether a line is prose rather than code: `//` line and doc comments,
    /// `/*` block openers, and the `*` continuation lines inside a block
    /// comment. `*` cannot begin a Swift expression (`*` is infix), so there is
    /// no code line this misreads.
    static func isComment(_ line: String) -> Bool {
        line.hasPrefix("//") || line.hasPrefix("/*") || line.hasPrefix("*")
    }

    /// the first identifier-ish token of a line — the word a reader's eye lands
    /// on first, and the one a corrected retry keeps. `nil` when the line opens
    /// with punctuation only.
    static func leadingToken(of line: String) -> String? {
        var current = ""
        for character in line {
            if character.isLetter || character.isNumber || character == "_" {
                current.append(character)
            } else if !current.isEmpty {
                return current
            }
        }
        return current.isEmpty ? nil : current
    }

    /// the width of a line's leading whitespace, counted in characters. a
    /// caller quoting a line usually keeps its depth, so a candidate at a very
    /// different depth is a different context.
    static func indentWidth(of line: String) -> Int {
        var width = 0
        for character in line {
            guard character == " " || character == "\t" else { break }
            width += 1
        }
        return width
    }

    static func truncate(_ text: String) -> String {
        text.count <= maxLineChars ? text : String(text.prefix(maxLineChars)) + "…"
    }
}

/// one suggested line: its number and its (possibly truncated) text.
struct LineSuggestion: Codable, Sendable {
    let n: Int
    let text: String
}