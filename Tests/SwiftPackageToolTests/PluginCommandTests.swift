import Testing
import Foundation

/// black-box tests for the `plugin` mode (the agent tool protocol over
/// stdin/stdout): manifest generation, dispatch through the CLI, and the
/// model-actionable error contract. invokes the built binary as a subprocess
/// via the shared helpers in SwiftPackageToolTests.swift — run `swift build`
/// first so `.build/debug/swift-package-tool` exists.
@Suite("Plugin mode")
struct PluginCommandTests {

    private var repoRoot: String { FileManager.default.currentDirectoryPath }

    @Test("manifest lists the tool table, addressed at this binary")
    func manifest() throws {
        let manifest = try runTool("plugin", "--manifest")
        #expect(manifest["name"] as? String == "swift-package-utilitykit")
        #expect(manifest["version"] as? String == "1.0.0")

        let tools = manifest["tools"] as? [[String: Any]] ?? []
        let names = tools.compactMap { $0["name"] as? String }
        #expect(names == ["pkg_api", "pkg_build", "pkg_test", "pkg_clean",
                          "pkg_docc_check", "pkg_force_unwraps", "pkg_validate"])

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

    @Test("pkg_api returns the subcommand's JSON through the result envelope")
    func apiInvoke() throws {
        let stdin = #"{"tool": "pkg_api", "args": {"path": "\#(repoRoot)/Sources/NormalizerCore", "limit": 3}}"#
        let response = try runTool("plugin", stdin: stdin)
        let result = response["result"] as? String ?? ""
        #expect(result.hasPrefix("["), "expected a JSON array, got: \(result.prefix(120))")
        #expect(result.contains("CommentMode"))
    }

    @Test("unknown tools and bad arguments produce model-actionable errors")
    func errorContract() throws {
        let unknown = try runTool("plugin", stdin: #"{"tool": "pkg_nope", "args": {}}"#)
        #expect((unknown["result"] as? String)?.contains("unknown tool 'pkg_nope'") == true)

        let missing = try runTool("plugin", stdin: #"{"tool": "pkg_api", "args": {}}"#)
        #expect((missing["result"] as? String)?.contains("'path' is required") == true)

        let relative = try runTool("plugin", stdin: #"{"tool": "pkg_api", "args": {"path": "Sources"}}"#)
        #expect((relative["result"] as? String)?.contains("must be an absolute path") == true)

        let malformed = try runTool("plugin", stdin: "not json")
        #expect((malformed["result"] as? String)?.contains("expected one JSON object") == true)
    }

    @Test("pkg_validate carries the pass/fail verdict through as a result")
    func validateVerdict() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uk-plugin-validate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "func broken( {\n".write(
            to: dir.appendingPathComponent("Broken.swift"), atomically: true, encoding: .utf8)

        let stdin = #"{"tool": "pkg_validate", "args": {"path": "\#(dir.path)"}}"#
        let response = try runTool("plugin", stdin: stdin)
        let result = response["result"] as? String ?? ""
        #expect(result.contains("error"), "diagnostics must survive the rc=1 exit: \(result.prefix(200))")
        #expect(!result.hasPrefix("Error"), "a negative verdict is a result, not an error")
    }
}