import Testing
@testable import NormalizerCore

@Suite("Normalizer")
struct NormalizerTests {

	private var standard: NormalizationOptions { .standard }

	@Test("Split lines with mixed LF and CRLF")
	func splitLinesHandlesLFAndCRLF() {
		let (lines, ends) = Normalizer.splitLines("a\nb\r\nc")
		#expect(lines == ["a", "b", "c"])
		#expect(!ends)
	}

	@Test("Split lines tracks a trailing newline")
	func splitLinesTrailingNewline() {
		let (lines, ends) = Normalizer.splitLines("a\n")
		#expect(lines == ["a"])
		#expect(ends)
	}

	@Test("Split lines on empty input")
	func splitLinesEmptyInput() {
		let (lines, ends) = Normalizer.splitLines("")
		#expect(lines == [])
		#expect(!ends)
	}

	@Test("Strip trailing whitespace")
	func stripsTrailingWhitespace() {
		let out = Normalizer.normalize("let a = 1;   \n\t\nlet b = 2;  ", options: standard)
		#expect(out == "let a = 1;\n\nlet b = 2;\n")
	}

	@Test("Ensure final newline")
	func ensuresFinalNewline() {
		let out = Normalizer.normalize("print(\"hi\")", options: standard)
		#expect(out == "print(\"hi\")\n")
	}

	@Test("Convert CRLF to LF by default")
	func convertsCRLFToLF() {
		let out = Normalizer.normalize("a\r\nb\r\n", options: standard)
		#expect(out == "a\nb\n")
	}

	@Test("Preserve CRLF when requested")
	func preservesCRLFWhenRequested() {
		var opts = standard
		opts.lineEnding = .crlf
		let out = Normalizer.normalize("a\nb\n", options: opts)
		#expect(out == "a\r\nb\r\n")
	}

	@Test("Without final-newline pass, preserve original trailing state")
	func noFinalNewlinePreservesOriginalState() {
		var opts = standard
		opts.ensureFinalNewline = false
		#expect(Normalizer.normalize("a\n", options: opts) == "a\n")
		#expect(Normalizer.normalize("a", options: opts) == "a")
	}

	@Test("Convert leading tabs to spaces")
	func tabsToSpaces() {
		var opts = standard
		opts.indentation = .tabsToSpaces(4)
		let out = Normalizer.normalize("\tfunc foo() {\n\t\treturn 1\n\t}\n", options: opts)
		#expect(out == "    func foo() {\n        return 1\n    }\n")
	}

	@Test("Convert runs of leading spaces to tabs")
	func spacesToTabs() {
		var opts = standard
		opts.indentation = .spacesToTabs(4)
		let out = Normalizer.normalize("    func foo() {\n        return 1\n    }\n", options: opts)
		#expect(out == "\tfunc foo() {\n\t\treturn 1\n\t}\n")
	}

	@Test("Default policy normalizes 4-space indents to tabs")
	func defaultPolicyUsesTabsForIndent() {
		let out = Normalizer.normalize(
			"func foo() {\n    let x = 1\n    return x\n}\n",
			options: .standard
		)
		#expect(out == "func foo() {\n\tlet x = 1\n\treturn x\n}\n")
	}

	@Test("Collapse runs of blank lines")
	func collapseBlankLines() {
		var opts = standard
		opts.collapseBlankLines = true
		let out = Normalizer.normalize("a\n\n\n\nb\n\nc\n", options: opts)
		#expect(out == "a\n\nb\n\nc\n")
	}

	@Test("Already-normalized input is unchanged")
	func identicalInputReturnsIdenticalOutput() {
		let input = "let x = 1\n"
		#expect(Normalizer.normalize(input, options: standard) == input)
	}

	// MARK: - minify mode

	@Test("Minify strips leading whitespace and blank lines")
	func minifyStripsIndentationAndBlanks() {
		let input = "    func foo() {\n        let x = 1\n\n\n        return x\n    }\n"
		let out = Normalizer.normalize(input, options: .minified)
		#expect(out == "func foo() {\nlet x = 1\n\nreturn x\n}\n")
	}

	@Test("Minify preserves a single blank line between declarations")
	func minifyPreservesOneBlankLine() {
		let input = "class A {}\n\n\n\nclass B {}\n"
		let out = Normalizer.normalize(input, options: .minified)
		#expect(out == "class A {}\n\nclass B {}\n")
	}

	@Test("Minify is idempotent on already-minified input")
	func minifyIsIdempotent() {
		let input = "func a() {}\n\nfunc b() {}\n"
		let once = Normalizer.normalize(input, options: .minified)
		let twice = Normalizer.normalize(once, options: .minified)
		#expect(once == twice)
	}

	@Test("Minify strips trailing whitespace before stripping leading")
	func minifyStripsTrailingFirst() {
		let input = "    let x = 1;   \n    let y = 2;   \n"
		let out = Normalizer.normalize(input, options: .minified)
		#expect(out == "let x = 1;\nlet y = 2;\n")
	}
}
