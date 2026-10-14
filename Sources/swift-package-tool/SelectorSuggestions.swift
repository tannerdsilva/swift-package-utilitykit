import Foundation

/// the nearest lines to a selector that missed, so an agent can correct itself.
///
/// ranking is deliberately simple and dependency-free: normalise (trim, collapse
/// runs of whitespace), then score each line by token-set overlap with the
/// selector, breaking ties by line order. the failure this answers is measured,
/// not hypothetical: a model aiming at `return "50"` in a file that says
/// `return "0"` (27 of 28 classifiable misses were text that does not exist at
/// all). the list is capped — at most ``maxSuggestions`` lines, each truncated
/// at ``maxLineChars`` characters — so a suggestion can never leak a whole file.
enum SelectorSuggestions {
    static let maxSuggestions = 3
    static let maxLineChars = 160

    /// the closest lines to `selector`, best first, each with its 1-based
    /// number; empty when no line shares a token with the selector.
    static func closest(to selector: String, in text: String) -> [LineSuggestion] {
        let selectorNormalized = normalize(selector)
        let selectorTokens = tokens(of: selectorNormalized)
        guard !selectorTokens.isEmpty else { return [] }

        var candidates: [(n: Int, text: String, score: Int)] = []
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
            candidates.append((n: index + 1, text: truncate(line), score: score))
        }

        // best score first; equal scores keep the earlier line (stable).
        let ranked = candidates.sorted { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.n < rhs.n
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

    static func truncate(_ text: String) -> String {
        text.count <= maxLineChars ? text : String(text.prefix(maxLineChars)) + "…"
    }
}

/// one suggested line: its number and its (possibly truncated) text.
struct LineSuggestion: Codable, Sendable {
    let n: Int
    let text: String
}