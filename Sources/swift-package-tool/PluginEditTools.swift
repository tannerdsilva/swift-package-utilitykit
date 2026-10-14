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

import MCP

// MARK: - The edit tool set
//
// One `@MCPCommand` per edit verb: the surface that lets an agent EDIT Swift
// source over stdio/MCP, where the rest of the tool set only inspects. Each
// `run()` maps its typed parameters onto the CLI subcommand that implements
// it (the CLI keeps the verbs under its `edit` group), through the same
// `PluginToolRunner` the read-only tools use — the CLI stays the contract, and
// no editing logic is duplicated here.
//
// `path` is the absolute path to the Swift source file to edit (for
// `pkg_edit_batch` it is the plan file instead — the one verb whose subject is
// a set of edits rather than a single file).
//
// Every verb shares the same safety contract, inherited verbatim from the CLI:
// the result is RE-PARSED and the write is withheld when the edit would not
// parse (unless `force` is set), and `dry_run` previews the change — diff
// included — without touching the file. A selector that matched nothing, or a
// write withheld by verification, is a real failure: it surfaces as
// `isError: true` on the JSON-RPC dialect, while the one-shot plugin dialect
// renders it as the `result` string prefixed `Error: ` — either way the
// EditResult payload rides along verbatim. Output is the compact single-line
// EditResult JSON.
//
// Verb-specific parameters are optional in the schema (the wrapper's `@Option`
// is optional-by-construction); the subcommand validates the combination and
// reports a missing or contradictory selector as a model-actionable error. A
// few CLI flags are keywords in Swift (`--in`, `--else`, `--case`, `--default`)
// and are surfaced under their readable names (`container`, `else_body`,
// `case_name`, `default_value`) — the CLI flag each maps to is named in the
// parameter's description where it could surprise.
//
// Every content-bearing verb passes `--literal-content`: the CLI expands `\n`
// and `\\` in content arguments for shell callers, but an MCP argument is
// already exact bytes (JSON decodes its own escapes), so the content must
// arrive verbatim. Without the flag a Swift string literal such as
// `print("a\nb")` would be rewritten into a line break.

@MCPCommand(
    description: "replace exact text in a Swift source file (every occurrence). a selector that matches nothing, or a result that would not parse, is a real failure, reported through `isError` on the JSON-RPC dialect; the one-shot plugin dialect renders the same failure as `result` prefixed `Error: `; set dry_run to preview the change (diff included) without writing.",
    name: "pkg_edit_replace"
)
struct PkgEditReplace {
    @Argument(description: "absolute path to the Swift source file to edit")
    var path: String = ""

    @Option(description: "the exact text to find")
    var old_text: String? = nil

    @Option(description: "the replacement text (taken verbatim: real newlines land as newlines and backslashes as backslashes)")
    var new_text: String? = nil

    @Flag(description: "preview the change without writing")
    var dry_run: Bool = false

    @Flag(description: "write even if the result does not parse")
    var force: Bool = false

    func run() async throws -> String {
        var argv = ["edit", "replace", try requiredAbsolutePath(path)]
        if let old_text { argv += ["--old", old_text] }
        if let new_text { argv += ["--new", new_text] }
        argv.append("--literal-content")
        if dry_run { argv.append("--dry-run") }
        if force { argv.append("--force") }
        argv += ["--output-format", "compact"]
        return try await PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "rename a symbol and every one of its references in a Swift source file (AST-aware: the token tree is rewritten, not the text). a miss or a result that would not parse is a real failure, reported through `isError` on the JSON-RPC dialect; the one-shot plugin dialect renders the same failure as `result` prefixed `Error: `; set dry_run to preview the diff without writing.",
    name: "pkg_edit_rename"
)
struct PkgEditRename {
    @Argument(description: "absolute path to the Swift source file to edit")
    var path: String = ""

    @Option(description: "the current name of the symbol to rename")
    var old_name: String? = nil

    @Option(description: "the new name for the symbol")
    var new_name: String? = nil

    @Flag(description: "preview the change without writing")
    var dry_run: Bool = false

    @Flag(description: "write even if the result does not parse")
    var force: Bool = false

    func run() async throws -> String {
        var argv = ["edit", "rename", try requiredAbsolutePath(path)]
        if let old_name { argv += ["--old-name", old_name] }
        if let new_name { argv += ["--new-name", new_name] }
        if dry_run { argv.append("--dry-run") }
        if force { argv.append("--force") }
        argv += ["--output-format", "compact"]
        return try await PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "insert code into a Swift source file at a precise location: after the first line containing a pattern, before it, or at an absolute line number. exactly one of after/before/at_line is required. inserted lines inherit the anchor line's indentation. a miss or a result that would not parse is a real failure, reported through `isError` on the JSON-RPC dialect; the one-shot plugin dialect renders the same failure as `result` prefixed `Error: `.",
    name: "pkg_edit_insert"
)
struct PkgEditInsert {
    @Argument(description: "absolute path to the Swift source file to edit")
    var path: String = ""

    @Option(description: "the code to insert (taken verbatim: real newlines land as newlines and backslashes as backslashes)")
    var content: String? = nil

    @Option(description: "insert after the first line containing this text")
    var after: String? = nil

    @Option(description: "insert before the first line containing this text")
    var before: String? = nil

    @Option(description: "insert at this absolute line number (1-indexed)")
    var at_line: Int? = nil

    @Flag(description: "preview the change without writing")
    var dry_run: Bool = false

    @Flag(description: "write even if the result does not parse")
    var force: Bool = false

    func run() async throws -> String {
        var argv = ["edit", "insert", try requiredAbsolutePath(path)]
        if let content { argv += ["--content", content] }
        if let after { argv += ["--after", after] }
        if let before { argv += ["--before", before] }
        if let at_line { argv += ["--at-line", String(at_line)] }
        argv.append("--literal-content")
        if dry_run { argv.append("--dry-run") }
        if force { argv.append("--force") }
        argv += ["--output-format", "compact"]
        return try await PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "remove code from a Swift source file by line range ('10-20'), by symbol name (AST-aware: the declaration and its doc comment go together), or by removing every line matching a pattern. exactly one of lines/symbol/matching is required. a miss or a result that would not parse is a real failure, reported through `isError` on the JSON-RPC dialect; the one-shot plugin dialect renders the same failure as `result` prefixed `Error: `.",
    name: "pkg_edit_delete"
)
struct PkgEditDelete {
    @Argument(description: "absolute path to the Swift source file to edit")
    var path: String = ""

    @Option(description: "line range to remove, e.g. '10-20'")
    var lines: String? = nil

    @Option(description: "name of the declaration to remove (AST-aware)")
    var symbol: String? = nil

    @Option(description: "remove every line containing this text")
    var matching: String? = nil

    @Flag(description: "preview the change without writing")
    var dry_run: Bool = false

    @Flag(description: "write even if the result does not parse")
    var force: Bool = false

    func run() async throws -> String {
        var argv = ["edit", "delete", try requiredAbsolutePath(path)]
        if let lines { argv += ["--lines", lines] }
        if let symbol { argv += ["--symbol", symbol] }
        if let matching { argv += ["--matching", matching] }
        if dry_run { argv.append("--dry-run") }
        if force { argv.append("--force") }
        argv += ["--output-format", "compact"]
        return try await PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "add code at the beginning of a Swift source file, or (after_imports) immediately after the last import statement. a result that would not parse is a real failure, reported through `isError` on the JSON-RPC dialect; the one-shot plugin dialect renders the same failure as `result` prefixed `Error: `; set dry_run to preview the diff without writing.",
    name: "pkg_edit_prepend"
)
struct PkgEditPrepend {
    @Argument(description: "absolute path to the Swift source file to edit")
    var path: String = ""

    @Option(description: "the code to prepend (taken verbatim: real newlines land as newlines and backslashes as backslashes)")
    var content: String? = nil

    @Flag(description: "insert after the last import instead of at line 1")
    var after_imports: Bool = false

    @Flag(description: "preview the change without writing")
    var dry_run: Bool = false

    @Flag(description: "write even if the result does not parse")
    var force: Bool = false

    func run() async throws -> String {
        var argv = ["edit", "prepend", try requiredAbsolutePath(path)]
        if let content { argv += ["--content", content] }
        if after_imports { argv.append("--after-imports") }
        argv.append("--literal-content")
        if dry_run { argv.append("--dry-run") }
        if force { argv.append("--force") }
        argv += ["--output-format", "compact"]
        return try await PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "add code at the end of a Swift source file. a result that would not parse is a real failure, reported through `isError` on the JSON-RPC dialect; the one-shot plugin dialect renders the same failure as `result` prefixed `Error: `; set dry_run to preview the diff without writing.",
    name: "pkg_edit_append"
)
struct PkgEditAppend {
    @Argument(description: "absolute path to the Swift source file to edit")
    var path: String = ""

    @Option(description: "the code to append (taken verbatim: real newlines land as newlines and backslashes as backslashes)")
    var content: String? = nil

    @Flag(description: "preview the change without writing")
    var dry_run: Bool = false

    @Flag(description: "write even if the result does not parse")
    var force: Bool = false

    func run() async throws -> String {
        var argv = ["edit", "append", try requiredAbsolutePath(path)]
        if let content { argv += ["--content", content] }
        argv.append("--literal-content")
        if dry_run { argv.append("--dry-run") }
        if force { argv.append("--force") }
        argv += ["--output-format", "compact"]
        return try await PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "add an import statement to a Swift source file. it is inserted alphabetically among the existing imports and skipped (status alreadyCurrent, not a failure) when the module is already imported.",
    name: "pkg_edit_add_import"
)
struct PkgEditAddImport {
    @Argument(description: "absolute path to the Swift source file to edit")
    var path: String = ""

    @Option(description: "the module name to import")
    var module: String? = nil

    @Flag(description: "preview the change without writing")
    var dry_run: Bool = false

    @Flag(description: "write even if the result does not parse")
    var force: Bool = false

    func run() async throws -> String {
        var argv = ["edit", "add-import", try requiredAbsolutePath(path)]
        if let module { argv += ["--module", module] }
        if dry_run { argv.append("--dry-run") }
        if force { argv.append("--force") }
        argv += ["--output-format", "compact"]
        return try await PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "add a protocol conformance to a type declaration (AST-aware: it appends to the type's inheritance clause). a type that already conforms is a benign skip (status alreadyCurrent); a type that is not found is a real failure, reported through `isError` on the JSON-RPC dialect; the one-shot plugin dialect renders the same failure as `result` prefixed `Error: `.",
    name: "pkg_edit_add_conformance"
)
struct PkgEditAddConformance {
    @Argument(description: "absolute path to the Swift source file to edit")
    var path: String = ""

    @Option(description: "the name of the type to add the conformance to")
    var type: String? = nil

    @Option(description: "the protocol to conform to (maps to the CLI's --protocol)")
    var protocol_name: String? = nil

    @Flag(description: "preview the change without writing")
    var dry_run: Bool = false

    @Flag(description: "write even if the result does not parse")
    var force: Bool = false

    func run() async throws -> String {
        var argv = ["edit", "add-conformance", try requiredAbsolutePath(path)]
        if let type { argv += ["--type", type] }
        if let protocol_name { argv += ["--protocol", protocol_name] }
        if dry_run { argv.append("--dry-run") }
        if force { argv.append("--force") }
        argv += ["--output-format", "compact"]
        return try await PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "add a member to a type declaration (AST-aware: it inserts before the type's closing brace, indented to match). exactly one of property/method/case_name is required. the method body is taken verbatim. a type that is not found is a real failure, reported through `isError` on the JSON-RPC dialect; the one-shot plugin dialect renders the same failure as `result` prefixed `Error: `.",
    name: "pkg_edit_add_member"
)
struct PkgEditAddMember {
    @Argument(description: "absolute path to the Swift source file to edit")
    var path: String = ""

    @Option(description: "the name of the type to add the member to")
    var type: String? = nil

    @Option(description: "a property declaration, e.g. 'var x: Int'")
    var property: String? = nil

    @Option(description: "a method signature, e.g. 'func foo()'")
    var method: String? = nil

    @Option(description: "the method body (used with method; (taken verbatim: real newlines land as newlines and backslashes as backslashes))")
    var body: String? = nil

    @Option(description: "an enum case name (maps to the CLI's --case)")
    var case_name: String? = nil

    @Option(description: "associated value types for an enum case, comma-separated")
    var associated: String? = nil

    @Option(description: "a default value for a property (maps to the CLI's --default)")
    var default_value: String? = nil

    @Option(description: "an access modifier: public, private, or internal")
    var access: String? = nil

    @Flag(description: "preview the change without writing")
    var dry_run: Bool = false

    @Flag(description: "write even if the result does not parse")
    var force: Bool = false

    func run() async throws -> String {
        var argv = ["edit", "add-member", try requiredAbsolutePath(path)]
        if let type { argv += ["--type", type] }
        if let property { argv += ["--property", property] }
        if let method { argv += ["--method", method] }
        if let body { argv += ["--body", body] }
        if let case_name { argv += ["--case", case_name] }
        if let associated { argv += ["--associated", associated] }
        if let default_value { argv += ["--default", default_value] }
        if let access { argv += ["--access", access] }
        argv.append("--literal-content")
        if dry_run { argv.append("--dry-run") }
        if force { argv.append("--force") }
        argv += ["--output-format", "compact"]
        return try await PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "wrap a range of lines in a syntactic container: do-catch, if-let, guard-let, or do. variable is required for if-let/guard-let; else_body is the else block for guard-let. the wrapped lines are re-indented inside the container. a range that selects no lines is a real failure, reported through `isError` on the JSON-RPC dialect; the one-shot plugin dialect renders the same failure as `result` prefixed `Error: `.",
    name: "pkg_edit_wrap"
)
struct PkgEditWrap {
    @Argument(description: "absolute path to the Swift source file to edit")
    var path: String = ""

    @Option(description: "the line range to wrap, e.g. '10-20'")
    var lines: String? = nil

    @Option(
        description: "the container to wrap the lines in (maps to the CLI's --in)",
        enumValues: ["do-catch", "if-let", "guard-let", "do"]
    )
    var container: String? = nil

    @Option(description: "the variable name for if-let / guard-let")
    var variable: String? = nil

    @Option(description: "the else body for guard-let (maps to the CLI's --else)")
    var else_body: String? = nil

    @Flag(description: "preview the change without writing")
    var dry_run: Bool = false

    @Flag(description: "write even if the result does not parse")
    var force: Bool = false

    func run() async throws -> String {
        var argv = ["edit", "wrap", try requiredAbsolutePath(path)]
        if let lines { argv += ["--lines", lines] }
        if let container { argv += ["--in", container] }
        if let variable { argv += ["--variable", variable] }
        if let else_body { argv += ["--else", else_body] }
        if dry_run { argv.append("--dry-run") }
        if force { argv.append("--force") }
        argv += ["--output-format", "compact"]
        return try await PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "sort the members of a type declaration (AST-aware). by name (default) orders by member name; by kind groups properties before methods before nested types. a type that is not found is a real failure, reported through `isError` on the JSON-RPC dialect; the one-shot plugin dialect renders the same failure as `result` prefixed `Error: `; an already-sorted type is a benign skip.",
    name: "pkg_edit_sort"
)
struct PkgEditSort {
    @Argument(description: "absolute path to the Swift source file to edit")
    var path: String = ""

    @Option(description: "the name of the type whose members to sort")
    var type: String? = nil

    @Option(description: "the sort key", enumValues: ["name", "kind"])
    var by: String? = nil

    @Flag(description: "preview the change without writing")
    var dry_run: Bool = false

    @Flag(description: "write even if the result does not parse")
    var force: Bool = false

    func run() async throws -> String {
        var argv = ["edit", "sort", try requiredAbsolutePath(path)]
        if let type { argv += ["--type", type] }
        if let by { argv += ["--by", by] }
        if dry_run { argv.append("--dry-run") }
        if force { argv.append("--force") }
        argv += ["--output-format", "compact"]
        return try await PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "apply a sequence of edit operations to one or more Swift files from a JSON plan file — a single round-trip for a multi-file refactor. the plan is {\"operations\": [ {\"command\": ..., \"file\": ...} ]}, applied in plan order. each command adds its own fields: add-import module; insert content + one anchor (after | before | atLine); replace old + new; append content (at end of file) / prepend content (+ afterImports, which append refuses); delete one selector (pattern | startLine+endLine | symbol); add-member typeName + one of property | method | caseName (plus body, associated, defaultValue, access); add-conformance typeName + protocolName. these are the PLAN's keys, not always the standalone command's flags (the plan spells --type as typeName), and a mistyped key decodes to null, surfacing as that command's 'requires ...' error rather than a hint about the typo. every operation is applied in plan order; a plan with any missed or failed operation is a real failure, reported through `isError` on the JSON-RPC dialect; the one-shot plugin dialect renders the same failure as `result` prefixed `Error: ` (each per-operation EditResult rides along). set fail_fast to stop at the first failure. content fields inside the plan are taken verbatim too — backslashes land as written, so a Swift string-literal escape needs no doubling.",
    name: "pkg_edit_batch"
)
struct PkgEditBatch {
    @Argument(description: "absolute path to the JSON edit-plan file to apply")
    var path: String = ""

    @Flag(description: "stop at the first operation that fails")
    var fail_fast: Bool = false

    @Flag(description: "preview every change without writing")
    var dry_run: Bool = false

    @Flag(description: "write even if an operation's result does not parse")
    var force: Bool = false

    func run() async throws -> String {
        var argv = ["edit", "batch", try requiredAbsolutePath(path)]
        argv.append("--literal-content")
        if fail_fast { argv.append("--fail-fast") }
        if dry_run { argv.append("--dry-run") }
        if force { argv.append("--force") }
        argv += ["--output-format", "compact"]
        return try await PluginToolRunner.run(argv)
    }
}