import Foundation

// MARK: - parsed-output value types

public struct BuildPhase: Codable, Sendable {
    public let current: Int
    public let total: Int
    public let action: String
    public let file: String?

    public init(current: Int, total: Int, action: String, file: String?) {
        self.current = current
        self.total = total
        self.action = action
        self.file = file
    }
}

public struct BuildDiagnostics: Codable, Sendable {
    public var errorCount: Int
    public var warningCount: Int
    public var noteCount: Int
    public var errors: [DiagnosticItem]
    public var warnings: [DiagnosticItem]
    public var notes: [DiagnosticItem]

    public init(errorCount: Int, warningCount: Int, noteCount: Int,
                errors: [DiagnosticItem], warnings: [DiagnosticItem], notes: [DiagnosticItem]) {
        self.errorCount = errorCount
        self.warningCount = warningCount
        self.noteCount = noteCount
        self.errors = errors
        self.warnings = warnings
        self.notes = notes
    }
}

public struct DiagnosticItem: Codable, Sendable {
    public let file: String
    public let line: Int
    public let column: Int
    public let message: String
    public let context: String

    public init(file: String, line: Int, column: Int, message: String, context: String) {
        self.file = file
        self.line = line
        self.column = column
        self.message = message
        self.context = context
    }
}

// MARK: - parsing

/// the pure text parser for `swift build` / `swift test` output, shared by
/// the `build` subcommand and the inspector so a verdict means the same thing
/// wherever it is produced.  it lives in its own library target so it is
/// unit-testable (an executable target cannot be imported by a test).
public enum BuildOutputParser {

    public struct ParsedOutput {
        public var phases: [BuildPhase] = []
        public var diagnostics = BuildDiagnostics(
            errorCount: 0, warningCount: 0, noteCount: 0,
            errors: [], warnings: [], notes: []
        )

        public init() {}
    }

    public static func parseBuildOutput(_ text: String) -> ParsedOutput {
        var parsed = ParsedOutput()
        let lines = text.components(separatedBy: "\n")
        var i = 0
        var seenDiagnostics = Set<String>() // dedup by file:line:message

        while i < lines.count {
            let line = lines[i]

            // phase line: [N/M] Action File
            if let phase = parsePhase(line) {
                parsed.phases.append(phase)
                i += 1
                continue
            }

            // diagnostic line: file:line:col: level: message
            if let diag = parseDiagnosticLine(line) {
                // collect context lines (source snippet + caret)
                var context: [String] = [line]
                i += 1
                while i < lines.count {
                    let next = lines[i]
                    // context lines are indented (source) or start with spaces+^ (caret)
                    // or are continuation lines (no colon-number pattern)
                    if next.hasPrefix(" ") || next.hasPrefix("\t") || next.hasPrefix("^") {
                        context.append(next)
                        i += 1
                    } else {
                        break
                    }
                }
                let fullMessage = context.joined(separator: "\n")

                // deduplicate: same file+line+message may appear in both per-file
                // compilation and module emission phases
                let dedupKey = "\(diag.file):\(diag.line):\(diag.message)"
                if !seenDiagnostics.contains(dedupKey) {
                    seenDiagnostics.insert(dedupKey)

                    switch diag.level {
                    case "error":
                        parsed.diagnostics.errorCount += 1
                        if parsed.diagnostics.errors.count < 20 {
                            parsed.diagnostics.errors.append(DiagnosticItem(
                                file: diag.file, line: diag.line, column: diag.column,
                                message: diag.message, context: fullMessage
                            ))
                        }
                    case "warning":
                        parsed.diagnostics.warningCount += 1
                        if parsed.diagnostics.warnings.count < 20 {
                            parsed.diagnostics.warnings.append(DiagnosticItem(
                                file: diag.file, line: diag.line, column: diag.column,
                                message: diag.message, context: fullMessage
                            ))
                        }
                    case "note":
                        parsed.diagnostics.noteCount += 1
                        if parsed.diagnostics.notes.count < 20 {
                            parsed.diagnostics.notes.append(DiagnosticItem(
                                file: diag.file, line: diag.line, column: diag.column,
                                message: diag.message, context: fullMessage
                            ))
                        }
                    default:
                        break
                    }
                }
                continue
            }

            i += 1
        }

        return parsed
    }

    /// parse a phase line like `[1/10] Compiling SomeFile.swift`
    public static func parsePhase(_ line: String) -> BuildPhase? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let bracketEnd = trimmed.firstIndex(of: "]") else {
            return nil
        }

        let bracketContent = trimmed[trimmed.index(after: trimmed.startIndex)..<bracketEnd]
        let parts = bracketContent.split(separator: "/")
        guard parts.count == 2,
              let current = Int(parts[0]),
              let total = Int(parts[1]) else {
            return nil
        }

        let rest = trimmed[trimmed.index(after: bracketEnd)...].trimmingCharacters(in: .whitespaces)
        // split into action and file
        if let spaceIdx = rest.firstIndex(of: " ") {
            let action = String(rest[..<spaceIdx])
            let file = String(rest[rest.index(after: spaceIdx)...])
            return BuildPhase(
                current: current, total: total,
                action: action, file: file.isEmpty ? nil : file
            )
        }

        return BuildPhase(current: current, total: total, action: rest, file: nil)
    }

    /// parse a diagnostic line: `file:line:col: level: message`
    public static func parseDiagnosticLine(_ line: String) -> (file: String, line: Int, column: Int, level: String, message: String)? {
        // pattern: /path/file.swift:42:13: error: message
        // or: /path/file.swift:42:13: warning: message
        // or: /path/file.swift:42:13: note: message

        // find the third colon after the file path
        guard let firstColon = line.firstIndex(of: ":") else { return nil }
        let afterFirst = line[line.index(after: firstColon)...]

        guard let secondColon = afterFirst.firstIndex(of: ":") else { return nil }
        let lineStr = String(afterFirst[..<secondColon])
        guard let lineNum = Int(lineStr.trimmingCharacters(in: .whitespaces)) else { return nil }

        let afterSecond = afterFirst[afterFirst.index(after: secondColon)...]
        guard let thirdColon = afterSecond.firstIndex(of: ":") else { return nil }
        let colStr = String(afterSecond[..<thirdColon])
        guard let colNum = Int(colStr.trimmingCharacters(in: .whitespaces)) else { return nil }

        let afterThird = afterSecond[afterSecond.index(after: thirdColon)...].trimmingCharacters(in: .whitespaces)
        // after third colon: "error: message" or "warning: message" or "note: message"
        guard let levelColon = afterThird.firstIndex(of: ":") else { return nil }
        let level = String(afterThird[..<levelColon]).trimmingCharacters(in: .whitespaces)
        let message = String(afterThird[afterThird.index(after: levelColon)...]).trimmingCharacters(in: .whitespaces)

        let file = String(line[..<firstColon])

        guard ["error", "warning", "note"].contains(level) else { return nil }

        return (file, lineNum, colNum, level, message)
    }

    /// executed/failed test counts from the run log.  XCTest emits
    /// "Executed N tests, with M failures" and Swift Testing emits
    /// "Test run with N tests in M suites".
    public static func parseTestCounts(_ text: String) -> (total: Int?, failed: Int?) {
        if let match = firstMatch(#"Executed (\d+) tests?, with (\d+) failure"#, in: text) {
            return (Int(match[0]), Int(match[1]))
        }
        if let match = firstMatch(#"Test run with (\d+) tests? in"#, in: text) {
            return (Int(match[0]), 0)
        }
        return (nil, nil)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            guard let r = Range(match.range(at: index), in: text) else { return "" }
            return String(text[r])
        }
    }
}
