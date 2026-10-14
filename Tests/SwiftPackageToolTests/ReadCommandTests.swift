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

/// Black-box tests for the `read` verb — the read half of read-before-write.
/// Each test spawns the built binary, so the numbered text, the range
/// handling, and the truncation note are exercised exactly as a harness
/// sees them. Run `swift build` first (the other spawned suites' discipline).

// MARK: - helpers

/// a temp file on disk, removed when the test ends.
private struct TempFile {
    let path: String
    private let dir: String

    init(contents: String, ext: String = "swift") throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uk-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Fixture.\(ext)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        self.dir = dir.path
        self.path = url.path
    }

    func remove() { try? FileManager.default.removeItem(atPath: dir) }
}

/// one `swift-package-tool read …` invocation, as a harness would run it.
private struct ReadRun {
    let status: Int32
    let stdout: String
    let stderr: String
}

private func runRead(_ args: [String]) async throws -> ReadRun {
    let outcome = try await Subprocess.capture(absoluteToolPath(), ["read"] + args, timeout: .seconds(30))
    return ReadRun(status: outcome.exitCode, stdout: outcome.stdout, stderr: outcome.stderr)
}

// MARK: - the suite

extension SwiftPackageToolTestsRoot {
    @Suite("read verb")
    struct ReadCommandTests {

        @Test("read prints every line with its number")
        func printsNumberedLines() async throws {
            let url = try TempFile(contents: "let a = 1\nlet b = 2\n")
            defer { url.remove() }
            let out = try await runRead([url.path])
            #expect(out.status == 0, "\(out.stderr)")
            #expect(out.stdout.contains("1\tlet a = 1"), "\(out.stdout)")
            #expect(out.stdout.contains("2\tlet b = 2"), "\(out.stdout)")
        }

        @Test("read honours --lines 2-3 (1-based, inclusive)")
        func honoursLineRange() async throws {
            let url = try TempFile(contents: "one\ntwo\nthree\nfour\n")
            defer { url.remove() }
            let out = try await runRead([url.path, "--lines", "2-3"])
            #expect(out.status == 0, "\(out.stderr)")
            #expect(out.stdout.contains("2\ttwo"), "\(out.stdout)")
            #expect(out.stdout.contains("3\tthree"), "\(out.stdout)")
            #expect(!out.stdout.contains("four"), "\(out.stdout)")
        }

        @Test("read reports truncation instead of truncating silently")
        func reportsTruncation() async throws {
            let url = try TempFile(contents: (1...500).map { "line \($0)" }.joined(separator: "\n"))
            defer { url.remove() }
            let out = try await runRead([url.path, "--max-lines", "10"])
            #expect(out.status == 0, "\(out.stderr)")
            #expect(out.stdout.contains("line 10"), "\(out.stdout)")
            #expect(!out.stdout.contains("line 11"), "\(out.stdout)")
            #expect(out.stdout.contains("truncated") || out.stdout.contains("--lines"), "\(out.stdout)")
        }

        @Test("read json carries the machine-readable range and total")
        func jsonShape() async throws {
            let url = try TempFile(contents: "a\nb\nc\n")
            defer { url.remove() }
            let out = try await runRead([url.path, "--output-format", "json"])
            #expect(out.status == 0, "\(out.stderr)")
            #expect(out.stdout.contains("\"total_lines\":3"), "\(out.stdout)")
            #expect(out.stdout.contains("\"n\":1"), "\(out.stdout)")
        }

        @Test("read does not need a Swift file (Package.swift, README, json are all fair game)")
        func anyTextFile() async throws {
            let url = try TempFile(contents: "{ \"name\": \"pkg\" }\n", ext: "json")
            defer { url.remove() }
            let out = try await runRead([url.path])
            #expect(out.status == 0, "\(out.stderr)")
            #expect(out.stdout.contains("name"), "\(out.stdout)")
        }
    }
}