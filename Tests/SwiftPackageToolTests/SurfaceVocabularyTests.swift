import Testing
import Foundation
import SubprocessCore

// MARK: - the vocabulary

/// the v3 surface vocabulary — the one place this release's names are written
/// down, for both surfaces at once.
///
/// a rename is a contract change: it breaks harness registrations, prompts and
/// muscle memory. keeping the tables here means a future rename has to change
/// *this* file deliberately, and the built artifact has to match it (the tests
/// below run the real binary), instead of drifting silently. the rename tables
/// are the same ones the CHANGELOG publishes as the 2.x → 3.0 migration guide.
enum SurfaceVocabulary {
    /// the 23 agent-facing MCP tool names, in declaration order.
    static let mcpTools: [String] = [
        "pkg_build", "pkg_security_scan", "pkg_dependencies", "pkg_targets",
        "pkg_test", "pkg_clean", "pkg_doc_coverage", "pkg_overview",
        "pkg_public_api", "pkg_force_unwraps", "pkg_validate",
        "pkg_edit_replace", "pkg_edit_rename", "pkg_edit_insert",
        "pkg_edit_delete", "pkg_edit_prepend", "pkg_edit_append",
        "pkg_edit_add_import", "pkg_edit_add_conformance", "pkg_edit_add_member",
        "pkg_edit_wrap", "pkg_edit_sort", "pkg_edit_batch",
    ]

    /// the 12 verbs under the `edit` group, in help order.
    static let editVerbs: [String] = [
        "replace", "rename", "insert", "delete", "prepend", "append",
        "add-import", "add-conformance", "add-member", "wrap", "sort", "batch",
    ]

    /// every root verb, in help order — grouped by family (source questions,
    /// then the package, then `edit`, then harness/install). the `edit` group
    /// is one entry: its verbs live on their own page.
    static let cliRootVerbs: [String] = [
        "find", "declarations", "search", "inspect", "references", "imports",
        "members", "tree", "callgraph", "conformances", "complexity", "index",
        "diff", "format", "macro-expand",
        "overview", "targets", "package-dependencies", "security-scan",
        "doc-coverage", "doc-reference-check", "public-api", "force-unwraps",
        "validate", "build", "test", "clean",
        "edit",
        "install", "uninstall", "path-wire", "skill-generate", "plugin",
    ]

    /// v2 → v3 MCP tool renames.
    static let mcpRenames: [String: String] = [
        "pkg_inspector": "pkg_overview",
        "pkg_scan": "pkg_security_scan",
        "pkg_list_targets": "pkg_targets",
        "pkg_list_dependencies": "pkg_dependencies",
        "pkg_docc_check": "pkg_doc_coverage",
        "pkg_api": "pkg_public_api",
    ]

    /// v2 → v3 CLI verb renames.
    static let cliRenames: [String: String] = [
        "query": "declarations",
        "dependencies": "imports",
        "api": "public-api",
        "inspector": "overview",
        "scan": "security-scan",
        "docc-check": "doc-reference-check",
    ]

    /// MCP edit-tool parameters that were renamed to read like the request.
    static let editParameterRenames: [String: [String: String]] = [
        "pkg_edit_replace": ["old": "old_text", "new": "new_text"],
        "pkg_edit_rename": ["symbol": "old_name", "rename": "new_name"],
    ]
}

// MARK: - black-box helpers

/// run the built binary and return stdout (bounded, like the other port tests).
private func surfaceOutput(_ args: [String], timeout: Duration = .seconds(60)) async throws -> String {
    let outcome = try await Subprocess.capture(absoluteToolPath(), args, timeout: timeout)
    return outcome.stdout
}

/// the tool names the compiled manifest serves, in order.
private func manifestToolNames(_ stdout: String) throws -> [String] {
    guard let json = try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any],
          let tools = json["tools"] as? [[String: Any]] else {
        throw TestError("no manifest envelope in: \(stdout.prefix(300))")
    }
    return tools.compactMap { $0["name"] as? String }
}

/// the parameter names of one tool's schema, sorted.
private func manifestParameters(_ stdout: String, tool name: String) throws -> Set<String> {
    guard let json = try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any],
          let tools = json["tools"] as? [[String: Any]],
          let tool = tools.first(where: { $0["name"] as? String == name }),
          let schema = tool["inputSchema"] as? [String: Any],
          let properties = schema["properties"] as? [String: Any] else {
        throw TestError("no schema for \(name) in: \(stdout.prefix(300))")
    }
    return Set(properties.keys)
}

/// the subcommand names in a help screen.
///
/// ArgumentParser lays the SUBCOMMANDS table out as `  <name>` padded to
/// column 26, then the abstract — so a verb line is one that starts at column
/// 3, whose columns 3…25 hold the name, and whose column 27 is not a space.
/// wrapped abstract continuations are indented past 26 and are skipped.
private func helpSubcommands(_ stdout: String) -> [String] {
    var names: [String] = []
    var inTable = false
    for line in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
        let text = String(line)
        if text.hasPrefix("SUBCOMMANDS") { inTable = true; continue }
        guard inTable else { continue }
        if text.isEmpty { break }
        guard text.hasPrefix("  "), text.count > 26 else { continue }
        let nameField = String(text[text.index(text.startIndex, offsetBy: 2)..<text.index(text.startIndex, offsetBy: 26)])
        let name = nameField.trimmingCharacters(in: .whitespaces)
        let after = text[text.index(text.startIndex, offsetBy: 26)]
        guard !name.isEmpty, after != " " else { continue }
        names.append(name)
    }
    return names
}

// MARK: - tests

@Suite("Surface vocabulary (v3)")
struct SurfaceVocabularyTests {

    @Test("the compiled manifest serves exactly the 23 pinned tool names")
    func manifestServesPinnedToolNames() async throws {
        let names = try manifestToolNames(try await surfaceOutput(["plugin", "--mcp-list"]))
        #expect(names == SurfaceVocabulary.mcpTools)
    }

    @Test("the manifest carries no v2 tool name")
    func manifestHasNoLegacyToolNames() async throws {
        let stdout = try await surfaceOutput(["plugin", "--mcp-list"])
        for legacy in SurfaceVocabulary.mcpRenames.keys {
            #expect(!stdout.contains("\"\(legacy)\""), "legacy tool name still served: \(legacy)")
        }
    }

    @Test("the edit tools expose their renamed, self-describing parameters")
    func editToolsExposeRenamedParameters() async throws {
        let stdout = try await surfaceOutput(["plugin", "--mcp-list"])
        for (tool, renames) in SurfaceVocabulary.editParameterRenames {
            let params = try manifestParameters(stdout, tool: tool)
            for (old, new) in renames {
                #expect(params.contains(new), "\(tool) is missing its \(new) parameter")
                #expect(!params.contains(old), "\(tool) still exposes the v2 \(old) parameter")
            }
        }
    }

    @Test("the root help lists every verb in family order, with one edit entry")
    func rootHelpListsEveryVerb() async throws {
        let verbs = helpSubcommands(try await surfaceOutput(["--help"]))
        #expect(verbs == SurfaceVocabulary.cliRootVerbs)
    }

    @Test("the edit group has its own help page listing its twelve verbs")
    func editGroupListsItsVerbs() async throws {
        let verbs = helpSubcommands(try await surfaceOutput(["help", "edit"]))
        #expect(verbs == SurfaceVocabulary.editVerbs)
    }
}