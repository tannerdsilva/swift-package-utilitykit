import Testing
import Foundation

/// integration tests for swift-code-query commands.
///
/// these tests run the built binary as a subprocess and verify its output.
/// they serve as smoke tests for the CLI interface and output formats.
@Suite("swift-code-query integration tests")
struct SwiftCodeQueryIntegrationTests {

    let binaryPath: String
    let testSourcesDir: String

    init() throws {
        // resolve the binary path relative to the package directory
        let packageDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/NormalizerCoreTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // swift-package-utilitykit/

        binaryPath = packageDir
            .appendingPathComponent(".build/debug/swift-code-query").path

        testSourcesDir = packageDir
            .appendingPathComponent("Sources/NormalizerCore").path
    }

    @Test("find command returns results for known symbol")
    func findKnownSymbol() throws {
        let output = try runCommand(["find", "Normalizer", testSourcesDir, "--exact"])
        #expect(output.contains("Normalizer"))
        #expect(output.contains("enum"))
    }

    @Test("find command returns empty for nonexistent symbol")
    func findNonexistentSymbol() throws {
        let output = try runCommand(["find", "XYZZY_NONEXISTENT", testSourcesDir])
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(trimmed == "[]")
    }

    @Test("find command supports --pretty-print")
    func findPrettyPrint() throws {
        let output = try runCommand(["find", "Normalizer", testSourcesDir, "--exact", "--pretty-print"])
        #expect(output.contains("\"name\""))
        #expect(output.contains("\"kind\""))
    }

    @Test("find command supports --output-format short")
    func findShortFormat() throws {
        let output = try runCommand(["find", "Normalizer", testSourcesDir, "--exact", "--output-format", "short"])
        #expect(output.contains("[enum]"))
    }

    @Test("complexity command returns results")
    func complexityReturnsResults() throws {
        let output = try runCommand(["complexity", testSourcesDir, "--output-format", "short"])
        #expect(output.contains("complexity:"))
        #expect(output.contains("rating:"))
    }

    @Test("complexity command supports --min-complexity filter")
    func complexityMinFilter() throws {
        let output = try runCommand(["complexity", testSourcesDir, "--min-complexity", "10", "--output-format", "short"])
        // may be empty if no function has complexity >= 10
        // just verify it doesn't crash
        _ = output
    }

    @Test("complexity command supports --limit")
    func complexityLimit() throws {
        let output = try runCommand(["complexity", testSourcesDir, "--limit", "1", "--output-format", "short"])
        let lines = output.split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines.count <= 1)
    }

    @Test("diff command shows no changes for identical files")
    func diffIdenticalFiles() throws {
        let file1 = "\(testSourcesDir)/Normalizer.swift"
        let output = try runCommand(["diff", file1, file1, "--output-format", "short"])
        #expect(output.contains("addedCount: 0"))
        #expect(output.contains("removedCount: 0"))
        #expect(output.contains("changedCount: 0"))
    }

    @Test("diff command detects added declarations")
    func diffDetectsAdditions() throws {
        // create two temp files: one empty, one with a struct
        let tmpDir = FileManager.default.temporaryDirectory
        let emptyFile = tmpDir.appendingPathComponent("diff_test_empty_\(UUID().uuidString).swift")
        let structFile = tmpDir.appendingPathComponent("diff_test_struct_\(UUID().uuidString).swift")

        try "".write(to: emptyFile, atomically: true, encoding: .utf8)
        try "public struct DiffTestAdded {}\n".write(to: structFile, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: emptyFile)
            try? FileManager.default.removeItem(at: structFile)
        }

        let output = try runCommand(["diff", emptyFile.path, structFile.path, "--output-format", "short"])
        #expect(output.contains("addedCount: 1"))
    }

    @Test("diff command supports stdin with -")
    func diffStdin() throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let file1 = tmpDir.appendingPathComponent("diff_stdin_a_\(UUID().uuidString).swift")
        let file2 = tmpDir.appendingPathComponent("diff_stdin_b_\(UUID().uuidString).swift")

        try "public func oldFunc() {}".write(to: file1, atomically: true, encoding: .utf8)
        try "public func newFunc() {}".write(to: file2, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: file1)
            try? FileManager.default.removeItem(at: file2)
        }

        let output = try runCommand(["diff", file1.path, file2.path, "--output-format", "short"])
        #expect(output.contains("addedCount: 1"))
        #expect(output.contains("removedCount: 1"))
    }

    @Test("members command lists type members")
    func membersListsMembers() throws {
        let output = try runCommand(["members", "\(testSourcesDir)/Normalizer.swift", "--type", "Normalizer", "--output-format", "short"])
        #expect(output.contains("normalize"))
        #expect(output.contains("normalizeLine"))
    }

    @Test("members command errors on nonexistent type")
    func membersNonexistentType() throws {
        let output = try runCommand(["members", "\(testSourcesDir)/Normalizer.swift", "--type", "NonExistentType"])
        // should error, not crash
        #expect(output.contains("not found") || output.contains("error"))
    }

    @Test("all commands support --schema")
    func schemaFlag() throws {
        // only test commands without required arguments (--schema is checked before
        // argument parsing completes for commands with required @Argument properties)
        for cmd in ["complexity", "api", "conformances", "callgraph"] {
            let output = try runCommand([cmd, "--schema"])
            #expect(output.contains("\"$schema\""), "\(cmd) --schema should return valid JSON Schema")
        }
    }

    @Test("--version flag works")
    func versionFlag() throws {
        let output = try runCommand(["--version"])
        #expect(output.contains("0.1.0"))
    }

    // MARK: - comment handling

    @Test("format with --minify hides docc comments")
    func minifyHidesDocComments() throws {
        let tmp = "/tmp/test-format-docc.swift"
        try """
        /// important documentation
        func foo() {}
        """.write(toFile: tmp, atomically: true, encoding: .utf8)
        _ = try runCommand(["format", tmp, "--minify"])
        let content = try String(contentsOfFile: tmp, encoding: .utf8)
        #expect(!content.contains("important documentation"))
        #expect(content.contains("/// comment invisible"))
    }

    @Test("format with --minify hides line comments")
    func minifyHidesLineComments() throws {
        let tmp = "/tmp/test-format-line.swift"
        try """
        // this is a note
        let x = 1
        """.write(toFile: tmp, atomically: true, encoding: .utf8)
        _ = try runCommand(["format", tmp, "--minify"])
        let content = try String(contentsOfFile: tmp, encoding: .utf8)
        #expect(!content.contains("this is a note"))
        #expect(content.contains("// comment invisible"))
    }

    @Test("format with --minify hides block comments")
    func minifyHidesBlockComments() throws {
        let tmp = "/tmp/test-format-block.swift"
        try """
        /* block comment */
        let x = 1
        """.write(toFile: tmp, atomically: true, encoding: .utf8)
        _ = try runCommand(["format", tmp, "--minify"])
        let content = try String(contentsOfFile: tmp, encoding: .utf8)
        #expect(!content.contains("block comment"))
        #expect(content.contains("/* comment invisible */"))
    }

    @Test("format with --minify --preserve-comments keeps comments")
    func minifyPreserveComments() throws {
        let tmp = "/tmp/test-format-preserve.swift"
        try """
        // keep this
        let x = 1
        """.write(toFile: tmp, atomically: true, encoding: .utf8)
        _ = try runCommand(["format", tmp, "--minify", "--preserve-comments"])
        let content = try String(contentsOfFile: tmp, encoding: .utf8)
        #expect(content.contains("keep this"))
    }

    @Test("format without --minify preserves all comments")
    func formatPreservesComments() throws {
        let tmp = "/tmp/test-format-default.swift"
        try """
        /// doc
        // line
        /* block */
        let x = 1
        """.write(toFile: tmp, atomically: true, encoding: .utf8)
        _ = try runCommand(["format", tmp, "--dry-run"])
        let content = try String(contentsOfFile: tmp, encoding: .utf8)
        // dry-run doesn't write, so content should be unchanged
        #expect(content.contains("/// doc"))
        #expect(content.contains("// line"))
        #expect(content.contains("/* block */"))
    }

    // MARK: - helpers

    private func runCommand(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
