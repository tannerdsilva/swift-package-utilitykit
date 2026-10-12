import Testing
import Foundation
@testable import BuildOutputParsing

private let thin = Character(UnicodeScalar(UInt32(0x2009))!)

extension BuildOutputParsingTestsRoot {
    @Suite("parsePhase")
    struct ParsePhaseTests {

        /// The classic 6.3.x phase line `[N/M] Action File` (P 6.3.0).
        @Test("classic [0/2] phase parses")
        func classicPhase() throws {
            let line = FixtureLoader.rawLine("matrix-630.txt", 1)
            let p = try #require(BuildOutputParser.parsePhase(line))
            #expect(p.current == 0 && p.total == 2)
            #expect(p.action == "Write")
            #expect(p.file == "sources")
        }

        /// The 6.4.0 phase line pads the slash with U+2009 THIN SPACE (F3):
        /// `[19 / 28] F`.  The bracket content is normalised (all whitespace,
        /// including thin spaces, stripped) before splitting on the slash.
        @Test("6.4.0 thin-space [19 / 28] phase parses")
        func thinSpacePhase6_4() throws {
            let line = FixtureLoader.rawLine("matrix-640.txt", 1)
            #expect(line.contains(String(thin)))
            let p = try #require(BuildOutputParser.parsePhase(line))
            #expect(p.current == 19 && p.total == 28)
            #expect(p.action == "F")
            #expect(p.file == nil)
        }

        /// The same shape from diagnostic-fixtures.txt (F3), which is the raw
        /// `[19 / 28]` with no trailing action.
        @Test("6.4.0 thin-space phase with no action parses")
        func thinSpaceBarePhase() throws {
            let line = FixtureLoader.rawLine("diag-fixtures.txt", 2)
            #expect(line.contains(String(thin)))
            let p = try #require(BuildOutputParser.parsePhase(line))
            #expect(p.current == 19 && p.total == 28)
            #expect(p.action.isEmpty)
        }

        /// A non-count bracket like `[Planning deferred tasks]` has no slash and
        /// is not a phase at all.
        @Test("non-numeric bracket is not a phase")
        func nonNumericBracket() {
            #expect(BuildOutputParser.parsePhase("[Planning deferred tasks]") == nil)
        }
    }
}
