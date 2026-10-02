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
///     stdin:  {"tool": "pkg_api", "args": {"path": "/abs/path/to/pkg"}}
///     stdout: {"result": "<the subcommand's output>"}
///
/// `plugin --mcp-manifest arc` renders the harness plugin manifest instead —
/// pipe it into `<plugins-dir>/swift-package-utilitykit/manifest.json`.
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