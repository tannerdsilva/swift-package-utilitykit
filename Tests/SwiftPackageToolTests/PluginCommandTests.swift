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

/// Black-box tests for `plugin` (the agent tool protocol over stdin/stdout):
/// dispatch through the CLI subcommands, the model-actionable error contract,
/// and the framework-generated arc manifest. Run `swift build` first so
/// `.build/debug/swift-package-tool` exists.
///
/// The children are spawned through `SubprocessCore` — the same path every
/// other spawn in this package uses. This harness previously hand-rolled
/// `posix_spawn` with its own pipes because a Foundation-`Process` spawn's child
/// never received the one-shot host's NIO pipe channel under the test runner;
/// the shared path owns its own pipes and hands the child a plain inherited
/// stdin, so that hazard no longer applies.
///
/// The suite is SERIALIZED: each child runs a `ServiceGroup` whose signal
/// watchers race startup/shutdown under parallel spawns (the house rule for
/// subprocess-heavy suites — swift-mcp's spawned E2E suite is serialized for
/// the same reason).
extension SwiftPackageToolTestsRoot {
    @Suite("Plugin mode")
    struct PluginCommandTests {

        private var repoRoot: String { FileManager.default.currentDirectoryPath }

        // MARK: - spawn harness

        private struct ToolRun {
            /// the child's exit status (`128 + signal` when it was killed by a signal).
            let status: Int32
            let stdout: String
            let stderr: String

            func stdoutJSON() throws -> [String: Any] {
                guard let data = stdout.data(using: .utf8),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw TestError("Failed to parse JSON output: \(stdout)")
                }
                return json
            }
        }

        /// Runs the built tool with the shared spawn path: writes `stdin` (when
        /// given) and closes the stream, waits (bounded), and captures both pipes.
        /// this harness used to hand-roll `posix_spawn` because a Foundation-Process
        /// spawn's child never received the one-shot host's NIO pipe channel under
        /// the test runner; the shared path owns its own pipes, so that hazard is gone.
        private func runPluginTool(_ args: [String], stdin: String? = nil) async throws -> ToolRun {
            let absolute = toolPath.hasPrefix("/")
                ? toolPath
                : FileManager.default.currentDirectoryPath + "/" + toolPath

            // newline-delimited framing: the host's frame codec delivers a frame on
            // its terminating newline (the envelope's own examples — `echo '{...}'
            // | tool` — terminate every frame).
            let payload = stdin.map { $0 + "\n" }

            let outcome = try await Subprocess.capture(
                absolute, args, stdin: payload, timeout: .seconds(10))
            return ToolRun(status: outcome.exitCode, stdout: outcome.stdout, stderr: outcome.stderr)
        }

        // MARK: - Tests

        @Test("manifest is generated from the compiled surface, addressed at this binary")
        func manifest() async throws {
            let run = try await runPluginTool(["plugin", "--mcp-manifest", "arc"])
            #expect(run.status == 0)
            let manifest = try run.stdoutJSON()
            #expect(manifest["name"] as? String == "swift-package-utilitykit")
            #expect(manifest["version"] as? String == "3.0.0")

            let tools = manifest["tools"] as? [[String: Any]] ?? []
            let names = tools.compactMap { $0["name"] as? String }
            #expect(names == ["pkg_build", "pkg_security_scan", "pkg_dependencies", "pkg_targets",
                              "pkg_test", "pkg_clean", "pkg_doc_coverage", "pkg_overview",
                              "pkg_public_api", "pkg_force_unwraps", "pkg_validate",
                              "pkg_edit_replace", "pkg_edit_rename", "pkg_edit_insert",
                              "pkg_edit_delete", "pkg_edit_prepend", "pkg_edit_append",
                              "pkg_edit_add_import", "pkg_edit_add_conformance", "pkg_edit_add_member",
                              "pkg_edit_wrap", "pkg_edit_sort", "pkg_edit_batch"])

            for tool in tools {
                let name = tool["name"] as? String ?? "?"
                #expect(tool["args"] as? [String] == ["plugin"], "\(name): args must re-enter the plugin mode")
                #expect((tool["command"] as? String)?.hasPrefix("/") == true, "\(name): command must be absolute")
                #expect(tool["toolset"] as? String == "swift-package-utilitykit")
                let schema = tool["schema"] as? [String: Any]
                #expect(schema?["type"] as? String == "object", "\(name): schema must be a bare parameters object")
                #expect(schema?["required"] as? [String] == ["path"], "\(name): path must be the required parameter")
            }
        }

        @Test("pkg_public_api returns the subcommand's JSON through the result envelope")
        func apiInvoke() async throws {
            let stdin = #"{"tool": "pkg_public_api", "args": {"path": "\#(repoRoot)/Sources/NormalizerCore", "limit": 3}}"#
            let run = try await runPluginTool(["plugin"], stdin: stdin)
            #expect(run.status == 0)
            let response = try run.stdoutJSON()
            let result = response["result"] as? String ?? ""
            #expect(result.hasPrefix("["), "expected a JSON array, got: \(result.prefix(120))")
            #expect(result.contains("CommentMode"))
        }

        @Test("unknown tools and bad arguments produce model-actionable errors")
        func errorContract() async throws {
            let unknown = try await runPluginTool(["plugin"], stdin: #"{"tool": "pkg_nope", "args": {}}"#).stdoutJSON()
            #expect((unknown["result"] as? String)?.contains("Unknown tool: pkg_nope") == true)

            let missing = try await runPluginTool(["plugin"], stdin: #"{"tool": "pkg_public_api", "args": {}}"#).stdoutJSON()
            #expect((missing["result"] as? String)?.contains("path") == true)

            let relative = try await runPluginTool(["plugin"], stdin: #"{"tool": "pkg_public_api", "args": {"path": "Sources"}}"#).stdoutJSON()
            #expect((relative["result"] as? String)?.contains("must be an absolute path") == true)
        }

        @Test("a frame that is not the plugin envelope exits 1 with a stderr diagnostic")
        func malformedFrameExitContract() async throws {
            let run = try await runPluginTool(["plugin"], stdin: "not json")
            #expect(run.status == 1)
            #expect(run.stdout.isEmpty)
            #expect(run.stderr.contains("no dialect recognized the first frame"))
        }

        @Test("pkg_validate reports a negative verdict through the isError channel with the payload intact")
        func validateVerdict() async throws {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("uk-plugin-validate-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            try "func broken( {\n".write(
                to: dir.appendingPathComponent("Broken.swift"), atomically: true, encoding: .utf8)

            let stdin = #"{"tool": "pkg_validate", "args": {"path": "\#(dir.path)"}}"#
            let response = try await runPluginTool(["plugin"], stdin: stdin).stdoutJSON()
            let result = response["result"] as? String ?? ""
            // D1 ruling: a negative verdict is a real failure and must surface
            // through the framework's isError channel (the `Error: ` prefix), not
            // hide as a plain result a model would have to parse.
            #expect(result.hasPrefix("Error: "), "a failed validation must throw: \(result.prefix(160))")
            // the diagnostics payload survives verbatim after the prefix
            let payload = String(result.dropFirst("Error: ".count))
            let data = try #require(payload.data(using: .utf8))
            let diags = try #require(try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                                     "validate payload must stay a JSON diagnostics array: \(payload.prefix(200))")
            #expect(!diags.isEmpty, "the broken fixture must emit diagnostics")
            #expect(diags.contains { ($0["severity"] as? String) == "error" })
        }

        @Test("pkg_build throws on a failing build and stays a plain result on a clean build")
        func buildFailureChannel() async throws {
            let broken = breakoutPackage(manifest: "Broken", source: "func broken( {\n")
            defer { try? FileManager.default.removeItem(atPath: broken) }
            let healthy = breakoutPackage(manifest: "Warn", source: "public func f() {\n    let unused = 1\n}\n")
            defer { try? FileManager.default.removeItem(atPath: healthy) }

            // --- the broken fixture: must throw (Error: prefix), payload intact ---
            let brokenRun = try await runPluginTool(
                ["plugin"], stdin: #"{"tool":"pkg_build","args":{"path":"\#(broken)"}}"#).stdoutJSON()
            let brokenResult = brokenRun["result"] as? String ?? ""
            #expect(brokenResult.hasPrefix("Error: "), "a failed build must throw: \(brokenResult.prefix(160))")
            let brokenObj = try payloadArray(String(brokenResult.dropFirst("Error: ".count)))
            #expect(brokenObj["succeeded"] as? Bool == false)
            #expect(brokenObj["exitCode"] as? Int == 1)
            #expect(brokenObj["ok"] as? Bool == true, "ok is a payload-internal fact; the verdict rides isError")

            // --- the healthy fixture: must NOT throw, full payload byte-path intact ---
            let healthyRun = try await runPluginTool(
                ["plugin"], stdin: #"{"tool":"pkg_build","args":{"path":"\#(healthy)"}}"#).stdoutJSON()
            let healthyResult = healthyRun["result"] as? String ?? ""
            #expect(!healthyResult.hasPrefix("Error: "), "a clean build must not throw: \(healthyResult.prefix(160))")
            let healthyObj = try payloadArray(healthyResult)
            #expect(healthyObj["succeeded"] as? Bool == true)
            #expect(healthyObj["exitCode"] as? Int == 0)
        }

        @Test("pkg_test throws on a failing test run via the isError channel")
        func testFailureChannel() async throws {
            let broken = breakoutPackage(manifest: "BrokenT", source: "func broken( {\n")
            defer { try? FileManager.default.removeItem(atPath: broken) }

            let run = try await runPluginTool(
                ["plugin"], stdin: #"{"tool":"pkg_test","args":{"path":"\#(broken)"}}"#).stdoutJSON()
            let result = run["result"] as? String ?? ""
            #expect(result.hasPrefix("Error: "), "a failing test run must throw: \(result.prefix(160))")
            let obj = try payloadArray(String(result.dropFirst("Error: ".count)))
            #expect(obj["succeeded"] as? Bool == false)
            #expect(obj["exitCode"] as? Int == 1)
        }

        /// Builds a throwaway package under the temp dir with the given manifest
        /// name and a single broken/healthy `Sources/<Name>/<Name>.swift` file.
        private func breakoutPackage(manifest: String, source: String) -> String {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("uk-fail-\(manifest.lowercased())-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let srcDir = root.appendingPathComponent("Sources/\(manifest)")
            try? FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
            let pkg = """
            // swift-tools-version: 5.9
            import PackageDescription
            let package = Package(
                name: "\(manifest)",
                products: [.library(name: "\(manifest)", targets: ["\(manifest)"])],
                targets: [.target(name: "\(manifest)")]
            )
            """
            try? pkg.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            try? source.write(to: srcDir.appendingPathComponent("\(manifest).swift"), atomically: true, encoding: .utf8)
            return root.path
        }

        /// Parses a one-element JSON payload array (build/test/validate verdicts)
        /// after the `Error: ` prefix has been removed, returning that object.
        private func payloadArray(_ payload: String) throws -> [String: Any] {
            let data = try #require(payload.data(using: .utf8))
            let array = try #require(try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                                     "expected a JSON array payload: \(payload.prefix(200))")
            return try #require(array.first, "payload array must not be empty")
        }
    }
}