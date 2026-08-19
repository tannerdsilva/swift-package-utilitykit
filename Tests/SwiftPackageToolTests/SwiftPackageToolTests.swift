import Testing
import Foundation

/// Tests for swift-package-tool that invoke the built executable as a
/// subprocess and verify its JSON output. This is a black-box integration
/// test that validates the CLI interface, JSON output format, and actual
/// file modifications.

let toolPath = ".build/debug/swift-package-tool"

/// Run the tool with given arguments and return parsed JSON output.
func runTool(_ args: String..., stdin: String? = nil) throws -> [String: Any] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: toolPath)
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    if let input = stdin {
        let stdinPipe = Pipe()
        stdinPipe.fileHandleForWriting.write(input.data(using: .utf8)!)
        stdinPipe.fileHandleForWriting.closeFile()
        process.standardInput = stdinPipe
    }

    try process.run()
    process.waitUntilExit()

    let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: outputData, encoding: .utf8) ?? ""

    guard let data = output.data(using: .utf8),
          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw TestError("Failed to parse JSON output: \(output)")
    }
    return json
}

func runToolArray(_ args: String..., stdin: String? = nil) throws -> [[String: Any]] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: toolPath)
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    if let input = stdin {
        let stdinPipe = Pipe()
        stdinPipe.fileHandleForWriting.write(input.data(using: .utf8)!)
        stdinPipe.fileHandleForWriting.closeFile()
        process.standardInput = stdinPipe
    }

    try process.run()
    process.waitUntilExit()

    let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: outputData, encoding: .utf8) ?? ""

    guard let data = output.data(using: .utf8),
          let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        throw TestError("Failed to parse JSON array output: \(output)")
    }
    return json
}

struct TestError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

// MARK: - FileEditor tests (via tool invocation)

@Suite("FileEditor.processMultilineContent")
struct ProcessMultilineTests {

    @Test("converts literal \\n to actual newlines")
    func convertsBackslashN() async throws {
        // Use insert --dry-run to verify multi-line content
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ml-test-\(UUID().uuidString).swift")
        try "// TARGET".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let json = try runTool(
            "insert", tmp.path,
            "--after", "// TARGET",
            "--content", "// LINE 1\n// LINE 2\n// LINE 3",
            "--dry-run", "--show-diff"
        )

        #expect(json["modified"] as? Bool == true)
        let diff = json["diff"] as? String ?? ""
        #expect(diff.contains("// LINE 1"))
        #expect(diff.contains("// LINE 2"))
        #expect(diff.contains("// LINE 3"))
    }

    @Test("single line content is not affected")
    func singleLineUnchanged() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sl-test-\(UUID().uuidString).swift")
        try "// TARGET".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let json = try runTool(
            "insert", tmp.path,
            "--after", "// TARGET",
            "--content", "// SINGLE LINE",
            "--dry-run", "--show-diff"
        )

        #expect(json["modified"] as? Bool == true)
        let diff = json["diff"] as? String ?? ""
        #expect(diff.contains("// SINGLE LINE"))
    }
}

@Suite("FileEditor.replace multiline")
struct ReplaceMultilineTests {

    @Test("replace with multiline content")
    func replaceWithMultiline() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rpl-test-\(UUID().uuidString).swift")
        try "let x = 1\nlet y = 2".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let json = try runTool(
            "replace", tmp.path,
            "--old", "let x = 1",
            "--new", "let a = 10\nlet b = 20",
            "--dry-run", "--show-diff"
        )

        #expect(json["modified"] as? Bool == true)
        let diff = json["diff"] as? String ?? ""
        #expect(diff.contains("let a = 10"))
        #expect(diff.contains("let b = 20"))
    }
}

// MARK: - Batch command tests

@Suite("Batch command")
struct BatchCommandTests {

    @Test("batch executes multiple operations")
    func batchMultipleOps() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("batch-test-\(UUID().uuidString).swift")
        try "// FILE START\nlet value = 0\n// FILE END".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let planPath = FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID().uuidString).json")
        let plan: [String: Any] = [
            "operations": [
                [
                    "command": "replace",
                    "file": tmp.path,
                    "old": "let value = 0",
                    "new": "let value = 42"
                ] as [String: Any],
                [
                    "command": "insert",
                    "file": tmp.path,
                    "after": "// FILE END",
                    "content": "print(value)\n"
                ] as [String: Any],
            ]
        ]
        let planData = try JSONSerialization.data(withJSONObject: plan, options: [.prettyPrinted])
        try planData.write(to: planPath)
        defer { try? FileManager.default.removeItem(at: planPath) }

        let json = try runTool("batch", planPath.path, "--dry-run", "--show-diff")

        let results = json["results"] as? [[String: Any]] ?? []
        #expect(results.count == 2)
        #expect(results[0]["modified"] as? Bool == true)
        // Second operation targets a pattern that exists in the original file
        // (not dependent on the first operation's output in dry-run mode)
        #expect(results[1]["modified"] as? Bool == true)
    }

    @Test("batch --fail-fast stops on first failure")
    func batchFailFast() async throws {
        let planPath = FileManager.default.temporaryDirectory.appendingPathComponent("plan-ff-\(UUID().uuidString).json")
        let plan: [String: Any] = [
            "operations": [
                [
                    "command": "replace",
                    "file": "/tmp/nonexistent-file-\(UUID().uuidString).swift",
                    "old": "x",
                    "new": "y"
                ] as [String: Any],
                [
                    "command": "insert",
                    "file": "/tmp/another-nonexistent-\(UUID().uuidString).swift",
                    "after": "x",
                    "content": "y"
                ] as [String: Any],
            ]
        ]
        let planData = try JSONSerialization.data(withJSONObject: plan, options: [.prettyPrinted])
        try planData.write(to: planPath)
        defer { try? FileManager.default.removeItem(at: planPath) }

        let json = try runTool("batch", planPath.path, "--dry-run", "--fail-fast")

        let results = json["results"] as? [[String: Any]] ?? []
        // With --fail-fast, the batch stops after the first failure.
        // The first operation fails (file not found), so only 1 result.
        #expect(results.count == 1)
        #expect(results[0]["modified"] as? Bool == false)
    }

    @Test("batch add-import operation")
    func batchAddImport() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("import-test-\(UUID().uuidString).swift")
        try "// Header\n// More header\n".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let planPath = FileManager.default.temporaryDirectory.appendingPathComponent("plan-import-\(UUID().uuidString).json")
        let plan: [String: Any] = [
            "operations": [
                [
                    "command": "add-import",
                    "file": tmp.path,
                    "module": "Foundation"
                ] as [String: Any],
            ]
        ]
        let planData = try JSONSerialization.data(withJSONObject: plan, options: [.prettyPrinted])
        try planData.write(to: planPath)
        defer { try? FileManager.default.removeItem(at: planPath) }

        let json = try runTool("batch", planPath.path, "--dry-run", "--show-diff")

        let results = json["results"] as? [[String: Any]] ?? []
        #expect(results.count == 1)
        #expect(results[0]["modified"] as? Bool == true)
        let diff = results[0]["diff"] as? String ?? ""
        #expect(diff.contains("import Foundation"))
    }
}

// MARK: - Dry-run diff tests

@Suite("Dry-run diff")
struct DryRunDiffTests {

    @Test("--dry-run returns diff without --show-diff")
    func dryRunShowsDiff() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dryrun-\(UUID().uuidString).swift")
        try "let x = 1".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let json = try runTool(
            "replace", tmp.path,
            "--old", "let x = 1",
            "--new", "let x = 42",
            "--dry-run"
        )

        #expect(json["modified"] as? Bool == true)
        // diff should be present even without --show-diff
        #expect(json["diff"] is String)
        let diff = json["diff"] as? String ?? ""
        #expect(diff.contains("let x = 42"))
    }
}
