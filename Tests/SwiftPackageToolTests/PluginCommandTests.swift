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

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Black-box tests for `plugin` (the agent tool protocol over stdin/stdout):
/// dispatch through the CLI subcommands, the model-actionable error contract,
/// and the framework-generated arc manifest. Run `swift build` first so
/// `.build/debug/swift-package-tool` exists.
///
/// The children are spawned with `posix_spawn` (not Foundation `Process`): the
/// one-shot host reads stdin through a NIO pipe channel, and under the test
/// runner a Foundation-Process spawn's child never receives the channel's
/// read events — the same Foundation-pipe hazard the arc harness hit and
/// worked around with its posix_spawn subscriber. posix_spawn is what both
/// production harnesses use, so the test exercises the real spawn shape.
///
/// The suite is SERIALIZED: each child runs a `ServiceGroup` whose signal
/// watchers race startup/shutdown under parallel spawns (the house rule for
/// subprocess-heavy suites — swift-mcp's spawned E2E suite is serialized for
/// the same reason).
@Suite("Plugin mode", .serialized)
struct PluginCommandTests {

    private var repoRoot: String { FileManager.default.currentDirectoryPath }

    // MARK: - posix_spawn harness

    private struct ToolRun {
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

    private func readToEOF(_ fd: Int32) -> String {
        var out: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            out.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Spawns the built tool, writes `stdin` (when given) and closes the
    /// stream, waits (bounded) for the exit, and drains both output pipes.
    private func runPluginTool(_ args: [String], stdin: String? = nil) throws -> ToolRun {
        let absolute = toolPath.hasPrefix("/")
            ? toolPath
            : FileManager.default.currentDirectoryPath + "/" + toolPath

        var stdinPipe: [Int32] = [-1, -1]
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        guard pipe(&stdinPipe) == 0, pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            throw TestError("pipe() failed: \(String(cString: strerror(errno)))")
        }
        for fd in [stdinPipe[0], stdinPipe[1], stdoutPipe[0], stdoutPipe[1], stderrPipe[0], stderrPipe[1]] {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO)

        var argv: [UnsafeMutablePointer<CChar>?] = ([absolute] + args).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = []
        envp.append(nil)
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, absolute, &actions, nil, &argv, &envp)
        posix_spawn_file_actions_destroy(&actions)
        close(stdinPipe[0])
        close(stdoutPipe[1])
        close(stderrPipe[1])
        guard spawnResult == 0 else {
            close(stdinPipe[1])
            close(stdoutPipe[0])
            close(stderrPipe[0])
            throw TestError("posix_spawn failed: \(String(cString: strerror(spawnResult)))")
        }

        if let stdin {
            // newline-delimited framing: the host's frame codec delivers a
            // frame on its terminating newline (the envelope's own examples —
            // `echo '{...}' | tool` — terminate every frame).
            var bytes = Array(stdin.utf8)
            bytes.append(0x0A)
            var offset = 0
            while offset < bytes.count {
                let written = bytes.withUnsafeBytes { buffer -> Int in
                    write(stdinPipe[1], buffer.baseAddress?.advanced(by: offset), bytes.count - offset)
                }
                if written <= 0 { break }
                offset += written
            }
        }
        close(stdinPipe[1])

        var status: Int32 = 0
        var exited = false
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { exited = true; break }
            if result < 0 { throw TestError("waitpid failed: \(String(cString: strerror(errno)))") }
            usleep(20_000)
        }
        guard exited else {
            kill(pid, SIGKILL)
            _ = waitpid(pid, &status, 0)
            throw TestError("tool did not exit within the test bound")
        }

        let run = ToolRun(
            status: (status & 0x7F) == 0 ? (status >> 8) & 0xFF : -(status & 0x7F),
            stdout: readToEOF(stdoutPipe[0]),
            stderr: readToEOF(stderrPipe[0])
        )
        close(stdoutPipe[0])
        close(stderrPipe[0])
        return run
    }

    // MARK: - Tests

    @Test("manifest is generated from the compiled surface, addressed at this binary")
    func manifest() throws {
        let run = try runPluginTool(["plugin", "--mcp-manifest", "arc"])
        #expect(run.status == 0)
        let manifest = try run.stdoutJSON()
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
        let run = try runPluginTool(["plugin"], stdin: stdin)
        #expect(run.status == 0)
        let response = try run.stdoutJSON()
        let result = response["result"] as? String ?? ""
        #expect(result.hasPrefix("["), "expected a JSON array, got: \(result.prefix(120))")
        #expect(result.contains("CommentMode"))
    }

    @Test("unknown tools and bad arguments produce model-actionable errors")
    func errorContract() throws {
        let unknown = try runPluginTool(["plugin"], stdin: #"{"tool": "pkg_nope", "args": {}}"#).stdoutJSON()
        #expect((unknown["result"] as? String)?.contains("Unknown tool: pkg_nope") == true)

        let missing = try runPluginTool(["plugin"], stdin: #"{"tool": "pkg_api", "args": {}}"#).stdoutJSON()
        #expect((missing["result"] as? String)?.contains("path") == true)

        let relative = try runPluginTool(["plugin"], stdin: #"{"tool": "pkg_api", "args": {"path": "Sources"}}"#).stdoutJSON()
        #expect((relative["result"] as? String)?.contains("must be an absolute path") == true)
    }

    @Test("a frame that is not the plugin envelope exits 1 with a stderr diagnostic")
    func malformedFrameExitContract() throws {
        let run = try runPluginTool(["plugin"], stdin: "not json")
        #expect(run.status == 1)
        #expect(run.stdout.isEmpty)
        #expect(run.stderr.contains("no dialect recognized the first frame"))
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
        let response = try runPluginTool(["plugin"], stdin: stdin).stdoutJSON()
        let result = response["result"] as? String ?? ""
        #expect(result.contains("error"), "diagnostics must survive the rc=1 exit: \(result.prefix(200))")
        #expect(!result.hasPrefix("Error"), "a negative verdict is a result, not an error")
    }
}