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

import ArgumentParser

/// `swift-package-tool plugin` — serve one agent tool invocation over
/// stdin/stdout (the manifest+executable plugin protocol).
///
/// A thin shim over the one-shot stdin host built by `PluginHost.run()`
/// (see `PluginTools.swift`):
///
///     stdin:  {"tool": "pkg_scan", "args": {"path": "/abs/path/to/pkg"}}
///     stdout: {"result": "<the subcommand's output>"}
///
/// The surface is the full package-inspector set — `pkg_inspector`,
/// `pkg_scan`, `pkg_list_targets`, `pkg_list_dependencies`, `pkg_build`,
/// `pkg_test`, `pkg_clean`, `pkg_docc_check`, `pkg_api`, `pkg_force_unwraps`,
/// `pkg_validate` — one `@MCPCommand` each in `PluginTools.swift`, plus the
/// `pkg_edit_*` editing family in `PluginEditTools.swift` (replace, rename,
/// insert, delete, prepend, append, add-import, add-conformance, add-member,
/// wrap, sort, batch), which lets an agent edit Swift source over the same
/// stdio transport. Build, test and clean are the audit-safe faces of their
/// subcommands (isolated scratch, non-destructive sweep), so an agent cannot
/// destroy a consumer's build products through this surface.
///
/// `plugin --mcp-manifest arc` renders the harness plugin manifest (tools +
/// schemas) instead; `install --adapter arc` writes it into
/// `<plugins-dir>/swift-package-utilitykit/manifest.json`, so a manifest
/// harness discovers the same surface with no interpreter in the path.
///
/// The same binary answers a full MCP session on the same streams
/// (`initialize` → `tools/list` → `tools/call`), so an MCP-speaking harness
/// registers it as a plain stdio server.
///
/// The ArgumentParser and MCP imports live in separate files (`PluginCommand`
/// here, `PluginTools.swift` there): both export `Argument`/`Option`/`Flag`/
/// `OptionGroup` wrappers, and a single file importing both cannot resolve
/// them.
struct PluginCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plugin",
        abstract: "Serve one agent tool invocation over stdin/stdout (plugin protocol).",
        discussion: """
        Reads a newline-terminated {"tool": "<name>", "args": {...}} frame on \
        stdin, runs the mapped subcommand, and writes a newline-terminated \
        {"result": "<string>"} on stdout. \
        `--mcp-manifest arc` prints the harness plugin manifest (tools + \
        schemas) for this binary instead.
        """
    )

    /// Host flags (e.g. `--mcp-manifest arc`). The host reads the process
    /// arguments itself; this declaration only keeps the argument parser from
    /// rejecting them.
    @Argument(parsing: .captureForPassthrough, help: "Host flags (e.g. `--mcp-manifest arc`).")
    var hostArguments: [String] = []

    func run() async throws {
        await PluginHost.run()
    }
}