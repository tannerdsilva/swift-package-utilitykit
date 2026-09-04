import Testing
import Foundation

/// regression tests for bugs found while testing swift-package-tool against a
/// large real-world package (rawdog). each test drives the built binary as a
/// subprocess and asserts on the fixed behavior, so a re-regression fails.
@Suite("swift-package-tool regression tests")
struct RegressionTests {

    let binaryPath: String
    let packageDir: String

    init() throws {
        let pkgDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        binaryPath = pkgDir
            .appendingPathComponent(".build/debug/swift-package-tool").path
        packageDir = pkgDir.path
    }

    // MARK: - helpers

    /// run the binary; returns (stdout+stderr, exit code).
    private func runTool(
        _ args: [String],
        cwd: String? = nil,
        env: [String: String]? = nil,
        stdin: String? = nil
    ) throws -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var mergedEnv = ProcessInfo.processInfo.environment
        if let env { mergedEnv.merge(env) { _, new in new } }
        process.environment = mergedEnv

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        if let stdin {
            let inPipe = Pipe()
            process.standardInput = inPipe
            try process.run()
            inPipe.fileHandleForWriting.write(stdin.data(using: .utf8)!)
            try inPipe.fileHandleForWriting.close()
        } else {
            try process.run()
        }
        process.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let output = (String(data: outData, encoding: .utf8) ?? "")
            + (String(data: errData, encoding: .utf8) ?? "")
        return (output, process.terminationStatus)
    }

    private func makeTempFile(_ content: String, _ name: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("regress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(name).path
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func parsedJSON(_ output: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: output.data(using: .utf8) ?? Data()))
            as? [String: Any] ?? [:]
    }

    // MARK: - delete --symbol (bug: visitAny never intercepted typed nodes)

    @Test("delete --symbol removes the declaration and verifies")
    func deleteSymbol() throws {
        let path = try makeTempFile("import RAW\n\nstruct Foo: Sendable {}\nstruct Bar: Sendable {}\n", "del.swift")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let (output, code) = try runTool(["delete", path, "--symbol", "Foo"])
        #expect(code == 0)
        let json = parsedJSON(output)
        #expect(json["modified"] as? Bool == true)
        #expect(json["verified"] as? Bool == true)

        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(!content.contains("struct Foo"))
        #expect(content.contains("struct Bar"))
    }

    @Test("delete --symbol reports untouched when symbol absent")
    func deleteSymbolMissing() throws {
        let path = try makeTempFile("struct Bar: Sendable {}\n", "del2.swift")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let (output, _) = try runTool(["delete", path, "--symbol", "Nope"])
        let json = parsedJSON(output)
        #expect(json["modified"] as? Bool == false)
    }

    // MARK: - --force gating (bug: verify-failing edits wrote anyway)

    @Test("verify-failing edit is blocked without --force")
    func forceBlocksUnverified() throws {
        let path = try makeTempFile("struct S {\n  var value: Int\n}\n", "fx.swift")
        let original = try String(contentsOfFile: path, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        // removing the closing brace breaks the syntax
        let (output, code) = try runTool(["replace", path, "--old", "}", "--new", ""])
        #expect(code == 0)
        let json = parsedJSON(output)
        #expect(json["modified"] as? Bool == false)
        #expect(json["verified"] as? Bool == false)

        // file must be untouched on disk
        let after = try String(contentsOfFile: path, encoding: .utf8)
        #expect(after == original)
    }

    @Test("--force allows the unverified write")
    func forceWritesWhenForced() throws {
        let path = try makeTempFile("struct S {\n  var value: Int\n}\n", "fx2.swift")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let (output, code) = try runTool(["replace", path, "--old", "}", "--new", "", "--force"])
        #expect(code == 0)
        let json = parsedJSON(output)
        #expect(json["modified"] as? Bool == true)
        #expect(json["verified"] as? Bool == false)
    }

    // MARK: - minify token separation (bug: space between tokens dropped)

    @Test("minify preserves required token separation")
    func minifyPreservesSeparation() throws {
        let source = """
        import __crawdog_sha256
        import RAW

        /// a static length structure
        @RAW_staticbuff(bytes:32)
        public struct Hash:Sendable {}

        """
        let path = try makeTempFile(source, "min.swift")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let (_, code) = try runTool(["format", path, "--minify"])
        #expect(code == 0)

        let minified = try String(contentsOfFile: path, encoding: .utf8)
        // the regression collapsed `import __crawdog_sha256` -> `import__crawdog_sha256`
        #expect(minified.contains("import __crawdog_sha256"))
        #expect(minified.contains("import RAW"))
        #expect(minified.contains("public struct Hash"))
        #expect(minified.contains("@RAW_staticbuff(bytes:32)"))
    }

    @Test("minified output still parses cleanly")
    func minifiedReparses() throws {
        let source = """
        import __crawdog_sha256
        import RAW

        @RAW_staticbuff(bytes:32)
        public struct Hash:Sendable {}

        """
        let path = try makeTempFile(source, "min2.swift")
        defer { try? FileManager.default.removeItem(atPath: path) }

        _ = try runTool(["format", path, "--minify"])
        let (validation, _) = try runTool(["validate", path, "--output-format", "json"])
        let data = validation.data(using: .utf8) ?? Data()
        let diags = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        let errors = diags.filter { ($0["severity"] as? String) == "error" }
        #expect(errors.isEmpty)
    }

    // MARK: - LCS diff (bug: insertion flagged the whole tail as changed)

    @Test("insert-at-top diff shows only the added line")
    func diffInsertAtTopIsMinimal() throws {
        let path = try makeTempFile("let x = 1\nlet y = 2\nlet z = 3\n", "d1.swift")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let (output, _) = try runTool(
            ["replace", path, "--old", "let x = 1", "--new", "let pre = 0\nlet x = 1", "--show-diff"]
        )
        let json = parsedJSON(output)
        let diff = json["diff"] as? String ?? ""
        #expect(diff.contains("+let pre = 0"))
        // unchanged lines must NOT appear in the diff
        #expect(!diff.contains("-let x = 1"))
        #expect(!diff.contains("-let z = 3"))
    }

    @Test("mid-file delete diff shows only the removed line")
    func diffMiddleDeleteIsMinimal() throws {
        let path = try makeTempFile("let x = 1\nlet y = 2\nlet z = 3\n", "d2.swift")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let (output, _) = try runTool(["delete", path, "--lines", "2-2", "--show-diff"])
        let json = parsedJSON(output)
        let diff = json["diff"] as? String ?? ""
        #expect(diff.contains("-let y = 2"))
        #expect(!diff.contains("-let x = 1"))
        #expect(!diff.contains("-let z = 3"))
    }

    // MARK: - short output (bug: raw Swift reflection dump)

    @Test("short output is human text, not reflection dumps")
    func shortFormatIsHumanReadable() throws {
        let srcDir = packageDir + "/Sources/NormalizerCore"

        // command -> (argv, artifact that must NOT appear); argv starts with
        // the subcommand name
        let cases: [(String, [String], String)] = [
            ("members", ["members", srcDir, "--type", "Normalizer", "--output-format", "short"], "MemberItem("),
            ("complexity", ["complexity", srcDir, "--output-format", "short"], "ComplexityItem("),
            ("callgraph", ["callgraph", srcDir, "--output-format", "short"], "CallEdge("),
            ("api", ["api", srcDir, "--output-format", "short"], "ApiItem("),
            ("conformances", ["conformances", srcDir, "--output-format", "short"], "ConformanceItem("),
            ("force-unwraps", ["force-unwraps", srcDir, "--output-format", "short"], "ForceUnwrapItem("),
        ]
        for (cmd, argv, forbidden) in cases {
            let (output, code) = try runTool(argv)
            #expect(code == 0, "\(cmd) short should exit 0")
            #expect(!output.contains(forbidden), "\(cmd) short must not dump reflection")
            // short output must carry a file:line prefix — unless the command
            // legitimately found nothing (e.g. force-unwraps on a clean dir)
            if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                #expect(output.contains(".swift:"), "\(cmd) short should be location-prefixed")
            }
        }
    }

    // MARK: - bare invocation defaults (bug: paths were required at parse time)

    @Test("query/dependencies/index work with no path args")
    func bareInvocationDefaultsToCwd() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("Sample.swift")
        try "public struct SampleThing {}\n".write(to: src, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let (queryOut, queryCode) = try runTool(["query", "--all", "--count"], cwd: dir.path)
        #expect(queryCode == 0)
        #expect(queryOut.trimmingCharacters(in: .whitespacesAndNewlines) == "1")

        let (depsOut, depsCode) = try runTool(["dependencies"], cwd: dir.path)
        #expect(depsCode == 0)
        let trimmedDeps = depsOut.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(trimmedDeps.contains("Sample.swift") || trimmedDeps == "[]")

        let (idxOut, idxCode) = try runTool(["index"], cwd: dir.path)
        #expect(idxCode == 0)
        #expect(idxOut.contains("Sample.swift"))
    }

    // MARK: - install/uninstall lifecycle (new subcommands)

    @Test("install then uninstall lands and removes binaries + plugin")
    func installUninstallLifecycle() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("life-\(UUID().uuidString)")
        let binDir = sandbox.appendingPathComponent("bin").path
        let pluginDir = sandbox.appendingPathComponent("plugins").path
        let prefix = sandbox.appendingPathComponent("prefix").path
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        // sandbox HOME + env so nothing touches the real host
        let env: [String: String] = [
            "HOME": sandbox.appendingPathComponent("home").path,
            "BIN_DIR": binDir,
            "HERMES_PLUGINS": pluginDir,
            "PREFIX": prefix,
            "PATH_UPDATE": "0",
            "PLUGIN_MODE": "copy",
        ]
        try FileManager.default.createDirectory(atPath: pluginDir, withIntermediateDirectories: true)

        // install: both binaries appear, plugin copy appears
        let (installOut, installCode) = try runTool(
            ["install", "--no-build", "--debug", "--no-path-update", "--no-interactive"],
            cwd: packageDir, env: env
        )
        #expect(installCode == 0, "install should succeed: \(installOut)")
        #expect(FileManager.default.fileExists(atPath: "\(binDir)/swift-package-tool"))
        #expect(FileManager.default.fileExists(atPath: "\(binDir)/normalizer-tool"))
        let pluginManifest = "\(pluginDir)/swift-package-utilitykit/plugin.yaml"
        #expect(FileManager.default.fileExists(atPath: pluginManifest))

        // uninstall: both binaries and the plugin are removed
        let (removeOut, removeCode) = try runTool(
            ["uninstall", "--force", "--no-path-update", "--bin-dir", binDir, "--hermes-plugins", pluginDir, "--prefix", prefix],
            env: env
        )
        #expect(removeCode == 0, "uninstall should succeed: \(removeOut)")
        #expect(!FileManager.default.fileExists(atPath: "\(binDir)/swift-package-tool"))
        #expect(!FileManager.default.fileExists(atPath: "\(binDir)/normalizer-tool"))
        #expect(!FileManager.default.fileExists(atPath: pluginManifest))
    }
}
