import Testing
import Foundation
@testable import BuildOutputParsing

/// strips ESC (0x1B) — the byte that must never reach a model.
private let esc = Character(UnicodeScalar(UInt32(0x1B))!)

extension BuildOutputParsingTestsRoot {
    @Suite("stripEscapeSequences")
    struct StripEscapeSequencesTests {

        /// F1 from diagnostic-fixtures.txt: the 6.4.0 warning with SGR colours
        /// around the level token and two OSC 8 hyperlink sequences around
        /// `[#NoUsage]`.  After stripping, the classic layout must remain intact
        /// and every escape byte must be gone.
        @Test("strips ANSI SGR + OSC 8 from the exact 6.4.0 F1 warning bytes")
        func stripsF1AnsiAndOsc8() {
            let line = FixtureLoader.rawLine("diag-fixtures.txt", 0)
            // the fixture must actually carry an ESC byte, or the test is vacuous
            #expect(line.contains(String(esc)))
            let clean = BuildOutputParser.stripEscapeSequences(line)
            #expect(!clean.contains(String(esc)))
            // the leading path + classic `:line:col: level:` framing survives
            #expect(clean.hasPrefix("/Users/tannerdsilva/"))
            #expect(clean.contains(":2:9: warning: "))
            // the OSC-wrapped hyperlink becomes plain `[#NoUsage]` text
            #expect(clean.contains("[#NoUsage]"))
            // no C0 control bytes remain (ESC is 0x1B)
            let controlScalars = clean.unicodeScalars.filter { $0.value < 0x20 || $0.value == 0x7F }
            #expect(controlScalars.isEmpty)
        }

        /// rawLog hygiene: other SGR sequences (bold, reset) must vanish too.
        @Test("strips colour codes anywhere, not just before the level token")
        func stripsSgrAnywhere() {
            let line = "some \(esc)[1;32mcoloured\(esc)[0m text \(esc)[0;0mend"
            let clean = BuildOutputParser.stripEscapeSequences(line)
            #expect(!clean.contains(String(esc)))
            #expect(clean == "some coloured text end")
        }

        /// OSC 8 with an empty URL (the hyperlink close) is handled identically.
        @Test("strips OSC8 open and close pairs")
        func stripsOsc8Pairs() {
            let line = "a \(esc)]8;;https://example.com\(esc)\\visitable\(esc)]8;;\(esc)\\ tail"
            let clean = BuildOutputParser.stripEscapeSequences(line)
            #expect(!clean.contains(String(esc)))
            #expect(clean == "a visitable tail")
        }

        /// a run of 6.3.x text with no escapes passes through untouched.
        @Test("6.3.x classic text passes through unchanged")
        func leavesClassicUntouched() {
            let line = FixtureLoader.rawLine("matrix-630.txt", 0)
            #expect(!line.contains(String(esc)))
            #expect(BuildOutputParser.stripEscapeSequences(line) == line)
        }
    }
}
