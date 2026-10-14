//===----------------------------------------------------------------------===//
//
// swift-package-utilitykit
//
// Copyright (c) 2024 and the swift-package-utilitykit project authors
// Licensed under the MIT License
//
// See LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

import Testing
import Foundation
import SubprocessCore

/// Black-box tests for the `pkg_edit_*` surface: the plugin tools that let an
/// agent EDIT Swift source over stdio/MCP. Each test spawns the built binary in
/// `plugin` mode and drives the real stdin/stdout envelope, so the argument
/// mapping, the CLI contract behind each verb, and the failure channel are all
/// exercised end-to-end. Run `swift build` first.
///
/// Serialized for the same reason as the plugin-mode suite: every child runs a
/// `ServiceGroup` whose signal watchers race startup/shutdown under parallel
/// spawns. Fixtures live in the system temp dir, never in the checked-out tree.

// MARK: - harness

private struct PluginRun {
    let status: Int32
    let stdout: String
    let stderr: String

    /// the plugin envelope's `result` string (the `Error: ` prefix included
    /// when the tool threw).
    var result: String {
        guard let data = stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["result"] as? String else { return "" }
        return text
    }

    /// the EditResult object carried as the tool's payload — parseable after
    /// stripping the `Error: ` prefix a failure carries.
    func editResult() throws -> [String: Any] {
        let payload = result.hasPrefix("Error: ") ? String(result.dropFirst("Error: ".count)) : result
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestError("expected an EditResult object, got: \(result.prefix(240))")
        }
        return object
    }
}

/// one `{"tool": …, "args": …}` frame through the built binary's plugin mode.
private func callEditTool(_ tool: String, _ args: [String: Any]) async throws -> PluginRun {
    let frame = try JSONSerialization.data(withJSONObject: ["tool": tool, "args": args])
    let text = String(decoding: frame, as: UTF8.self) + "\n"
    let outcome = try await Subprocess.capture(absoluteToolPath(), ["plugin"], stdin: text, timeout: .seconds(30))
    return PluginRun(status: outcome.exitCode, stdout: outcome.stdout, stderr: outcome.stderr)
}

/// the tools/list catalog over a real JSON-RPC handshake.
private func listedTools() async throws -> [[String: Any]] {
    let frames = [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#,
    ].joined(separator: "\n") + "\n"
    let outcome = try await Subprocess.capture(absoluteToolPath(), ["plugin"], stdin: frames, timeout: .seconds(30))
    for line in outcome.stdout.split(separator: "\n") {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["id"] as? Int == 2,
              let result = object["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else { continue }
        return tools
    }
    throw TestError("no tools/list response: \(outcome.stdout.prefix(300))")
}

/// writes `content` to a fresh temp `.swift` file and returns its path.
private func makeTempSwift(_ content: String, _ name: String = "Fixture.swift") throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("uk-edit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent(name).path
    try content.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

private func readSource(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

private func cleanup(_ path: String) {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
}

/// one `edit <verb> …` invocation on the CLI arm, as a harness would run it —
/// the near-miss contract is asserted against the compact JSON payload.
private struct EditRun {
    let status: Int32
    let stdout: String
    let stderr: String
}

private func runEdit(_ args: [String]) async throws -> EditRun {
    let outcome = try await Subprocess.capture(
        absoluteToolPath(), ["edit"] + args + ["--output-format", "compact"], timeout: .seconds(30))
    return EditRun(status: outcome.exitCode, stdout: outcome.stdout, stderr: outcome.stderr)
}

// MARK: - the suite

extension SwiftPackageToolTestsRoot {
    @Suite("plugin edit surface")
    struct PluginEditTests {

        @Test("pkg_edit_replace applies the edit and reports a compact EditResult")
        func replaceApplies() async throws {
            let path = try makeTempSwift("let a = 1\nlet b = 2\n")
            defer { cleanup(path) }

            let run = try await callEditTool("pkg_edit_replace", ["path": path, "old_text": "let a = 1", "new_text": "let a = 9"])
            #expect(run.status == 0, "\(run.stderr)")
            #expect(!run.result.hasPrefix("Error: "), "\(run.result)")
            #expect(!run.result.contains("\n"), "the MCP payload is compact single-line JSON: \(run.result)")

            let edit = try run.editResult()
            #expect(edit["status"] as? String == "applied")
            #expect(edit["modified"] as? Bool == true)
            #expect(edit["dryRun"] as? Bool == false, "a real edit must not claim a preview")
            #expect(readSource(path).contains("let a = 9"))
        }

        @Test("dry_run previews the diff without writing")
        func dryRunPreviews() async throws {
            let fixture = "struct S {\n    var value: Int\n}\n"
            let path = try makeTempSwift(fixture)
            defer { cleanup(path) }

            let run = try await callEditTool("pkg_edit_rename", ["path": path, "old_name": "value", "new_name": "count", "dry_run": true])
            #expect(run.status == 0, "\(run.stderr)")
            let edit = try run.editResult()
            #expect(edit["status"] as? String == "applied")
            #expect(edit["diff"] is String)
            #expect(edit["dryRun"] as? Bool == true, "a preview must say so")
            #expect(readSource(path) == fixture, "a dry run must not write")
        }

        @Test("a selector miss throws through the isError channel and leaves the file untouched")
        func missThrows() async throws {
            let fixture = "let a = 1\n"
            let path = try makeTempSwift(fixture)
            defer { cleanup(path) }

            let run = try await callEditTool("pkg_edit_replace", ["path": path, "old_text": "NOT-THERE", "new_text": "x"])
            #expect(run.status == 0, "a tool-level failure is a result, never an exit code: \(run.stderr)")
            #expect(run.result.hasPrefix("Error: "), "\(run.result)")

            let edit = try run.editResult()
            #expect(edit["status"] as? String == "missed")
            #expect(readSource(path) == fixture)
        }

        @Test("pkg_edit_rename rewrites every reference in the file")
        func renameSymbol() async throws {
            let path = try makeTempSwift("struct S {\n    var count: Int\n    func total() -> Int { count }\n}\n")
            defer { cleanup(path) }

            let run = try await callEditTool("pkg_edit_rename", ["path": path, "old_name": "count", "new_name": "value"])
            #expect(run.status == 0, "\(run.stderr)")
            let edit = try run.editResult()
            #expect(edit["status"] as? String == "applied")

            let source = readSource(path)
            #expect(source.contains("var value: Int"), "\(source)")
            #expect(source.contains("{ value }"), "\(source)")
            #expect(!source.contains("count"), "\(source)")
        }

        @Test("pkg_edit_add_import is alphabetical, and re-running is an alreadyCurrent skip")
        func addImportIdempotent() async throws {
            let path = try makeTempSwift("import Zeta\n\nlet x = 1\n")
            defer { cleanup(path) }

            let first = try await callEditTool("pkg_edit_add_import", ["path": path, "module": "Alpha"])
            #expect(first.status == 0, "\(first.stderr)")
            let firstEdit = try first.editResult()
            #expect(firstEdit["status"] as? String == "applied")
            #expect(readSource(path).contains("import Alpha\nimport Zeta"), "\(readSource(path))")

            let second = try await callEditTool("pkg_edit_add_import", ["path": path, "module": "Alpha"])
            #expect(second.status == 0, "an already-satisfied edit stays exit 0")
            let secondEdit = try second.editResult()
            #expect(secondEdit["status"] as? String == "alreadyCurrent")
            #expect(secondEdit["modified"] as? Bool == false)
        }

        @Test("pkg_edit_add_member and pkg_edit_add_conformance edit the body and the inheritance clause")
        func structuralEdits() async throws {
            let path = try makeTempSwift("struct S {\n    var a: Int\n}\n")
            defer { cleanup(path) }

            let member = try await callEditTool("pkg_edit_add_member", ["path": path, "type": "S", "property": "var z: Int"])
            #expect(member.status == 0, "\(member.stderr)")
            let memberEdit = try member.editResult()
            #expect(memberEdit["status"] as? String == "applied")

            let conform = try await callEditTool("pkg_edit_add_conformance", ["path": path, "type": "S", "protocol_name": "Sendable"])
            #expect(conform.status == 0, "\(conform.stderr)")
            let conformEdit = try conform.editResult()
            #expect(conformEdit["status"] as? String == "applied")

            let source = readSource(path)
            #expect(source.contains("var z: Int"), "\(source)")
            #expect(source.contains("Sendable"), "\(source)")
        }

        @Test("pkg_edit_delete removes a declaration by name")
        func deleteSymbol() async throws {
            let path = try makeTempSwift("struct S {\n    var a: Int\n}\n\nstruct Gone {\n    var b: Int\n}\n")
            defer { cleanup(path) }

            let run = try await callEditTool("pkg_edit_delete", ["path": path, "symbol": "Gone"])
            #expect(run.status == 0, "\(run.stderr)")
            let edit = try run.editResult()
            #expect(edit["status"] as? String == "applied")

            let source = readSource(path)
            #expect(!source.contains("struct Gone"), "\(source)")
            #expect(source.contains("struct S"), "\(source)")
        }

        @Test("pkg_edit_batch applies a plan, and a plan with a miss throws")
        func batchPlan() async throws {
            let path = try makeTempSwift("let value = 0\n")
            defer { cleanup(path) }
            let planPath = (path as NSString).deletingLastPathComponent + "/plan.json"

            let ok: [String: Any] = ["operations": [
                ["command": "replace", "file": path, "old": "let value = 0", "new": "let value = 42"],
                ["command": "append", "file": path, "content": "let extra = 1"],
            ]]
            try JSONSerialization.data(withJSONObject: ok).write(to: URL(fileURLWithPath: planPath))

            let run = try await callEditTool("pkg_edit_batch", ["path": planPath])
            #expect(run.status == 0, "\(run.stderr)")
            guard let payload = try? JSONSerialization.jsonObject(with: Data(run.result.utf8)) as? [String: Any] else {
                throw TestError("expected a BatchResult object, got: \(run.result.prefix(240))")
            }
            let results = payload["results"] as? [[String: Any]] ?? []
            #expect(results.count == 2, "\(run.result)")
            #expect(results.allSatisfy { $0["status"] as? String == "applied" }, "\(run.result)")
            #expect(readSource(path).contains("let value = 42"))

            // a plan whose operation missed is a real failure (isError channel)
            let miss: [String: Any] = ["operations": [
                ["command": "replace", "file": path, "old": "NOPE", "new": "x"],
            ]]
            try JSONSerialization.data(withJSONObject: miss).write(to: URL(fileURLWithPath: planPath))
            let missRun = try await callEditTool("pkg_edit_batch", ["path": planPath])
            #expect(missRun.result.hasPrefix("Error: "), "\(missRun.result)")
        }

        @Test("an edit that would not parse is blocked unless force is set")
        func blockedWrite() async throws {
            let fixture = "struct S {\n    var value: Int\n}\n"
            let path = try makeTempSwift(fixture)
            defer { cleanup(path) }

            let blocked = try await callEditTool("pkg_edit_replace", ["path": path, "old_text": "}", "new_text": ""])
            #expect(blocked.result.hasPrefix("Error: "), "\(blocked.result)")
            let blockedEdit = try blocked.editResult()
            #expect(blockedEdit["status"] as? String == "blocked")
            #expect(blockedEdit["verified"] as? Bool == false)
            #expect(readSource(path) == fixture, "a blocked write must not touch the file")

            let forced = try await callEditTool("pkg_edit_replace", ["path": path, "old_text": "}", "new_text": "", "force": true])
            #expect(!forced.result.hasPrefix("Error: "), "\(forced.result)")
            let forcedEdit = try forced.editResult()
            #expect(forcedEdit["status"] as? String == "applied")
            #expect(readSource(path) != fixture)
        }

        @Test("the edit tools advertise precise schemas")
        func editSchemas() async throws {
            let tools = try await listedTools()
            let byName = Dictionary(uniqueKeysWithValues: tools.compactMap { tool -> (String, [String: Any])? in
                guard let name = tool["name"] as? String else { return nil }
                return (name, tool)
            })

            let replace = try #require(byName["pkg_edit_replace"])
            let schema = try #require(replace["inputSchema"] as? [String: Any])
            #expect(schema["required"] as? [String] == ["path"])
            let props = try #require(schema["properties"] as? [String: Any])
            #expect(Set(props.keys) == Set(["path", "old_text", "new_text", "dry_run", "force"]), "\(props.keys)")

            let wrap = try #require(byName["pkg_edit_wrap"])
            let wrapSchema = try #require(wrap["inputSchema"] as? [String: Any])
            let wrapProps = try #require(wrapSchema["properties"] as? [String: Any])
            let container = try #require(wrapProps["container"] as? [String: Any])
            #expect(container["enum"] as? [String] == ["do-catch", "if-let", "guard-let", "do"])

            for tool in tools where (tool["name"] as? String)?.hasPrefix("pkg_edit_") == true {
                let toolSchema = tool["inputSchema"] as? [String: Any]
                #expect(toolSchema?["required"] as? [String] == ["path"], "\(tool["name"] ?? "?") must require only path")
            }
        }

        @Test("missing parameters and relative paths are model-actionable errors")
        func argumentErrors() async throws {
            let missing = try await callEditTool("pkg_edit_add_import", ["path": "/tmp/uk-nonexistent.swift"])
            #expect(missing.result.hasPrefix("Error: "), "\(missing.result)")
            #expect(missing.result.lowercased().contains("module"), "\(missing.result)")
            let relative = try await callEditTool("pkg_edit_replace", ["path": "Sources", "old_text": "a", "new_text": "b"])
            #expect(relative.result.contains("absolute path"), "\(relative.result)")
        }

        @Test("pkg_edit_wrap keeps the wrapped code for every container it offers")
        func wrapKeepsBody() async throws {
            let cases: [(String, [String: Any])] = [
                ("do", [:]),
                ("do-catch", [:]),
                ("if-let", ["variable": "x"]),
                ("guard-let", ["variable": "x", "else_body": "return"]),
            ]
            for (container, extra) in cases {
                let path = try makeTempSwift("func f() {\n    let a = 1\n    print(a)\n}\n")
                defer { cleanup(path) }

                let args = ["path": path, "lines": "2-3", "container": container].merging(extra) { _, new in new }
                let run = try await callEditTool("pkg_edit_wrap", args)
                #expect(run.status == 0, "\(container): \(run.stderr)")
                let edit = try run.editResult()
                #expect(edit["status"] as? String == "applied", "\(container): \(run.result)")

                let source = readSource(path)
                #expect(source.contains("let a = 1") && source.contains("print(a)"),
                        "\(container) must keep the wrapped code: \(source)")
            }
        }

        @Test("MCP content arrives verbatim: a Swift string-literal escape survives")
        func contentIsVerbatim() async throws {
            let path = try makeTempSwift("let s = 1\n")
            defer { cleanup(path) }

            // the argument carries the two characters `\` `n`, exactly as the Swift
            // source spells the string-literal escape. the CLI's shell-era `\n`
            // expansion would rewrite it into a line break and break the file.
            let run = try await callEditTool(
                "pkg_edit_insert", ["path": path, "at_line": 1, "content": #"print("a\nb")"#])
            #expect(run.status == 0, "\(run.stderr)")
            let edit = try run.editResult()
            #expect(edit["status"] as? String == "applied", "\(run.result)")
            #expect(readSource(path).contains(#"print("a\nb")"#),
                    "the escape must land verbatim: \(readSource(path))")
        }
    }
}

extension SwiftPackageToolTestsRoot {
    /// the near-miss contract on the CLI arm: a missed selector must teach —
    /// the closest numbered lines come back with the failure, capped.
    @Suite("edit near-miss suggestions")
    struct EditSuggestionTests {

        @Test("a missed replace suggests the closest lines with numbers")
        func missSuggests() async throws {
            let path = try makeTempSwift("struct S {\n    let x = \"0\"\n    func f() -> Int { return \"0\" }\n}\n")
            defer { cleanup(path) }

            let out = try await runEdit(["replace", path, "--old", "return \"50\"", "--new", "return 50"])
            #expect(out.status == 1, "\(out.stderr)")
            #expect(out.stdout.contains("\"status\":\"missed\""), "\(out.stdout)")
            #expect(out.stdout.contains("suggestions"), "\(out.stdout)")
            #expect(out.stdout.contains("\"n\":3"), "\(out.stdout)")  // the closest line, numbered
            #expect(out.stdout.contains("return"), "\(out.stdout)")
        }

        @Test("suggestions never leak the whole file and never exceed the cap")
        func suggestionsCapped() async throws {
            let path = try makeTempSwift((1...200).map { _ in "let value = 1" }.joined(separator: "\n"))
            defer { cleanup(path) }

            let out = try await runEdit(["replace", path, "--old", "let value = 2", "--new", "let value = 3"])
            #expect(out.status == 1, "\(out.stderr)")
            #expect(out.stdout.components(separatedBy: "\"n\":").count - 1 <= 3, "\(out.stdout)")
        }
    }
}

extension SwiftPackageToolTestsRoot {
    /// the preview contract on the CLI arm: `modified` describes the transform,
    /// `dryRun` says whether anything was written.
    @Suite("edit dry-run honesty")
    struct EditDryRunTests {

        @Test("a dry-run replace says so and leaves the bytes untouched")
        func dryRunSaysSo() async throws {
            let fixture = "let a = 1\n"
            let path = try makeTempSwift(fixture)
            defer { cleanup(path) }

            let out = try await runEdit(["replace", path, "--old", "let a = 1", "--new", "let a = 2", "--dry-run"])
            #expect(out.status == 0, "\(out.stderr)")
            #expect(out.stdout.contains("\"dryRun\":true"), "\(out.stdout)")
            #expect(readSource(path) == fixture, "a dry run must not write")
        }

        @Test("a real replace changes the bytes and reports dryRun:false")
        func realReplaceIsNotAPreview() async throws {
            let path = try makeTempSwift("let a = 1\n")
            defer { cleanup(path) }

            let out = try await runEdit(["replace", path, "--old", "let a = 1", "--new", "let a = 2"])
            #expect(out.status == 0, "\(out.stderr)")
            #expect(out.stdout.contains("\"dryRun\":false"), "\(out.stdout)")
            #expect(readSource(path).contains("let a = 2"))
        }
    }
}