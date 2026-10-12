import Testing
import Foundation
@testable import BuildOutputParsing

extension BuildOutputParsingTestsRoot {
    @Suite("parseDiagnosticLine")
    struct ParseDiagnosticLineTests {

        /// The 6.3.x line: classic `PATH:LINE:COL: LEVEL: MESSAGE`.  Whole 6.3.x
        /// era, no ANSI.  Copied from matrix-630.txt (W 6.3.0).
        @Test("6.3.0 classic warning parses (classic rule)")
        func classicWarning6_3() throws {
            let line = FixtureLoader.rawLine("matrix-630.txt", 0)
            let d = try #require(BuildOutputParser.parseDiagnosticLine(line))
            #expect(d.level == "warning")
            #expect(d.line == 2 && d.column == 9)
            #expect(d.file.hasSuffix("cap-warn/Sources/F/F.swift"))
            #expect(d.message.contains("initialization of immutable value 'unused'"))
        }

        /// The 6.3.x line: classic `PATH:LINE:COL: error: MESSAGE`.
        /// Copied from matrix-630.txt (E 6.3.0).
        @Test("6.3.0 classic error parses (classic rule)")
        func classicError6_3() throws {
            let line = FixtureLoader.rawLine("matrix-630.txt", 2)
            let d = try #require(BuildOutputParser.parseDiagnosticLine(line))
            #expect(d.level == "error")
            #expect(d.line == 1 && d.column == 14)
            #expect(d.file.hasSuffix("cap-error/Sources/F/F.swift"))
            #expect(d.message == "expected parameter name followed by ':'")
        }

        /// The 6.4.0 warning is the classic layout with an ANSI-wrapped level
        /// token (F1).  Once stripped it must parse through the classic rule.
        /// Copied from matrix-640.txt (W 6.4.0).
        @Test("6.4.0 ANSI-wrapped warning parses after stripping (classic rule)")
        func ansiWarning6_4() throws {
            let line = BuildOutputParser.stripEscapeSequences(FixtureLoader.rawLine("matrix-640.txt", 0))
            let d = try #require(BuildOutputParser.parseDiagnosticLine(line))
            #expect(d.level == "warning")
            #expect(d.line == 2 && d.column == 9)
            #expect(d.message.contains("initialization of immutable value 'unused'"))
        }

        /// The 6.4.0 error is the LEVEL-PREFIX layout: `error: PATH:LINE:COL MESSAGE`
        /// with no trailing level tag after the column (F2).  The classic rule
        /// cannot match it; the level-prefix rule must.  Copied from
        /// matrix-640.txt (E 6.4.0).
        @Test("6.4.0 level-prefix error parses (level-prefix rule)")
        func levelPrefixError6_4() throws {
            let line = FixtureLoader.rawLine("matrix-640.txt", 2)
            let d = try #require(BuildOutputParser.parseDiagnosticLine(line))
            #expect(d.level == "error")
            #expect(d.line == 1 && d.column == 14)
            #expect(d.file.hasSuffix("cap-error/Sources/F/F.swift"))
            #expect(d.message == "expected parameter name followed by ':'")
        }

        /// The 6.3.x headline summary must NOT count as a file diagnostic: it is
        /// `error: <summary>` with no `:line:col` path.  The level-prefix rule's
        /// `:line:col` requirement is what keeps this false-positive out.
        @Test("6.3.x headline summary yields no diagnostic (negative)")
        func headlineSummaryNegative() {
            let line = "error: emit-module command failed with exit code 1 (use -v to see invocation)"
            #expect(BuildOutputParser.parseDiagnosticLine(line) == nil)
        }

        /// A level-prefix line whose "path" has no `:line:col` is rejected, so
        /// arbitrary `error: text` summaries are never miscounted.
        @Test("level-prefix rule demands a real :line:col path")
        func levelPrefixDemandsLineCol() {
            #expect(BuildOutputParser.parseDiagnosticLine("error: just some prose") == nil)
            #expect(BuildOutputParser.parseDiagnosticLine("warning: nothing here") == nil)
        }
    }
}
