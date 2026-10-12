import Testing
import Foundation
@testable import BuildOutputParsing

extension BuildOutputParsingTestsRoot {
    @Suite("parseBuildOutput")
    struct ParseBuildOutputTests {

        /// End-to-end over the 6.3.0 captures: the classic warning, the classic
        /// phase, and the classic error are all seen.
        @Test("6.3.0 captures: warning + error + phase")
        func classicEra() {
            let text = FixtureLoader.rawLine("matrix-630.txt", 0) + "\n" +
                       FixtureLoader.rawLine("matrix-630.txt", 1) + "\n" +
                       FixtureLoader.rawLine("matrix-630.txt", 2) + "\n"
            let out = BuildOutputParser.parseBuildOutput(text)
            #expect(out.diagnostics.warningCount == 1)
            #expect(out.diagnostics.errorCount == 1)
            #expect(out.phases.count == 1)
            #expect(out.phases[0].current == 0 && out.phases[0].total == 2)
        }

        /// End-to-end over the 6.4.0 captures: the ANSI-wrapped warning (F1), the
        /// thin-space phase (F3) and the level-prefix error (F2) are ALL seen —
        /// the union of the two layouts across the matrix.
        @Test("6.4.0 captures: ANSI warning + thin-space phase + level-prefix error")
        func sixFourEra() {
            let text = FixtureLoader.rawLine("matrix-640.txt", 0) + "\n" +
                       FixtureLoader.rawLine("matrix-640.txt", 1) + "\n" +
                       FixtureLoader.rawLine("matrix-640.txt", 2) + "\n"
            let out = BuildOutputParser.parseBuildOutput(text)
            #expect(out.diagnostics.warningCount == 1)
            #expect(out.diagnostics.errorCount == 1)
            #expect(out.phases.count == 1)
            #expect(out.phases[0].current == 19 && out.phases[0].total == 28)
            // the parsed error carries file/line/column/message for a model
            let err = out.diagnostics.errors[0]
            #expect(err.line == 1 && err.column == 14)
            #expect(err.file.hasSuffix("cap-error/Sources/F/F.swift"))
            #expect(!err.message.isEmpty)
        }

        /// The headline summary must not be counted as a file diagnostic, even in
        /// a real error fixture's output (which pairs the headline with the real
        /// file diagnostic).
        @Test("headline summary is not counted; real file error is")
        func headlineNotCounted() {
            let text = """
            1>error: emit-module command failed with exit code 1 (use -v to see invocation)
            \(FixtureLoader.rawLine("matrix-630.txt", 2))
            """
            let out = BuildOutputParser.parseBuildOutput(text)
            #expect(out.diagnostics.errorCount == 1, "only the file diagnostic counts")
            #expect(out.diagnostics.errors.count == 1)
            #expect(out.diagnostics.errors[0].file.hasSuffix("F.swift"))
        }
    }
}
