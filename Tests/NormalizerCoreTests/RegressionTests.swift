import Testing
import Foundation
import SubprocessCore

/// regression tests for bugs found while testing swift-package-tool against a
/// large real-world package (rawdog). each test drives the built binary as a
/// subprocess and asserts on the fixed behavior, so a re-regression fails.
extension NormalizerCoreTestsRoot {
    @Suite("swift-package-tool regression tests")
    struct RegressionTests {

        let binaryPath: String
        let normalizerPath: String
        let packageDir: String

        init() throws {
            let pkgDir = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            binaryPath = pkgDir
                .appendingPathComponent(".build/debug/swift-package-tool").path
            normalizerPath = pkgDir
                .appendingPathComponent(".build/debug/normalizer-tool").path
            packageDir = pkgDir.path
        }

        // MARK: - helpers

        /// run the binary; returns (stdout+stderr, exit code).
        private func runTool(
            _ args: [String],
            binary: String? = nil,
            cwd: String? = nil,
            env: [String: String]? = nil,
            stdin: String? = nil
        ) async throws -> (output: String, exitCode: Int32) {
            var mergedEnv = ProcessInfo.processInfo.environment
            if let env { mergedEnv.merge(env) { _, new in new } }
            let outcome = try await Subprocess.capture(
                binary ?? binaryPath,
                args,
                workingDirectory: cwd,
                environment: mergedEnv,
                stdin: stdin
            )
            return (outcome.stdout + outcome.stderr, outcome.exitCode)
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
        func deleteSymbol() async throws {
            let path = try makeTempFile("import RAW\n\nstruct Foo: Sendable {}\nstruct Bar: Sendable {}\n", "del.swift")
            defer { try? FileManager.default.removeItem(atPath: path) }

            let (output, code) = try await runTool(["edit", "delete", path, "--symbol", "Foo"])
            #expect(code == 0)
            let json = parsedJSON(output)
            #expect(json["modified"] as? Bool == true)
            #expect(json["verified"] as? Bool == true)

            let content = try String(contentsOfFile: path, encoding: .utf8)
            #expect(!content.contains("struct Foo"))
            #expect(content.contains("struct Bar"))
        }

        @Test("delete --symbol reports untouched when symbol absent")
        func deleteSymbolMissing() async throws {
            let path = try makeTempFile("struct Bar: Sendable {}\n", "del2.swift")
            defer { try? FileManager.default.removeItem(atPath: path) }

            let (output, code) = try await runTool(["edit", "delete", path, "--symbol", "Nope"])
            #expect(code != 0, "a delete --symbol miss must not exit 0: \(output)")
            let json = parsedJSON(output)
            #expect(json["modified"] as? Bool == false)
            #expect(json["status"] as? String == "missed", "\(output)")
        }

        // MARK: - --force gating (bug: verify-failing edits wrote anyway)

        @Test("verify-failing edit is blocked without --force")
        func forceBlocksUnverified() async throws {
            let path = try makeTempFile("struct S {\n  var value: Int\n}\n", "fx.swift")
            let original = try String(contentsOfFile: path, encoding: .utf8)
            defer { try? FileManager.default.removeItem(atPath: path) }

            // removing the closing brace breaks the syntax
            let (output, code) = try await runTool(["edit", "replace", path, "--old", "}", "--new", ""])
            #expect(code != 0, "a blocked write must not exit 0: \(output)")
            let json = parsedJSON(output)
            #expect(json["modified"] as? Bool == false)
            #expect(json["verified"] as? Bool == false)
            #expect(json["status"] as? String == "blocked", "\(output)")

            // file must be untouched on disk
            let after = try String(contentsOfFile: path, encoding: .utf8)
            #expect(after == original)
        }

        @Test("--force allows the unverified write")
        func forceWritesWhenForced() async throws {
            let path = try makeTempFile("struct S {\n  var value: Int\n}\n", "fx2.swift")
            defer { try? FileManager.default.removeItem(atPath: path) }

            let (output, code) = try await runTool(["edit", "replace", path, "--old", "}", "--new", "", "--force"])
            #expect(code == 0)
            let json = parsedJSON(output)
            #expect(json["modified"] as? Bool == true)
            #expect(json["verified"] as? Bool == false)
        }

        // MARK: - minify token separation (bug: space between tokens dropped)

        @Test("minify preserves required token separation")
        func minifyPreservesSeparation() async throws {
            let source = """
            import __crawdog_sha256
            import RAW

            /// a static length structure
            @RAW_staticbuff(bytes:32)
            public struct Hash:Sendable {}

            """
            let path = try makeTempFile(source, "min.swift")
            defer { try? FileManager.default.removeItem(atPath: path) }

            let (_, code) = try await runTool(["format", path, "--minify"])
            #expect(code == 0)

            let minified = try String(contentsOfFile: path, encoding: .utf8)
            // the regression collapsed `import __crawdog_sha256` -> `import__crawdog_sha256`
            #expect(minified.contains("import __crawdog_sha256"))
            #expect(minified.contains("import RAW"))
            #expect(minified.contains("public struct Hash"))
            #expect(minified.contains("@RAW_staticbuff(bytes:32)"))
        }

        @Test("minified output still parses cleanly")
        func minifiedReparses() async throws {
            let source = """
            import __crawdog_sha256
            import RAW

            @RAW_staticbuff(bytes:32)
            public struct Hash:Sendable {}

            """
            let path = try makeTempFile(source, "min2.swift")
            defer { try? FileManager.default.removeItem(atPath: path) }

            _ = try await runTool(["format", path, "--minify"])
            let (validation, _) = try await runTool(["validate", path, "--output-format", "json"])
            let data = validation.data(using: .utf8) ?? Data()
            let diags = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            let errors = diags.filter { ($0["severity"] as? String) == "error" }
            #expect(errors.isEmpty)
        }

        // MARK: - LCS diff (bug: insertion flagged the whole tail as changed)

        @Test("insert-at-top diff shows only the added line")
        func diffInsertAtTopIsMinimal() async throws {
            let path = try makeTempFile("let x = 1\nlet y = 2\nlet z = 3\n", "d1.swift")
            defer { try? FileManager.default.removeItem(atPath: path) }

            let (output, _) = try await runTool(
                ["edit", "replace", path, "--old", "let x = 1", "--new", "let pre = 0\nlet x = 1", "--show-diff"]
            )
            let json = parsedJSON(output)
            let diff = json["diff"] as? String ?? ""
            #expect(diff.contains("+let pre = 0"))
            // unchanged lines must NOT appear in the diff
            #expect(!diff.contains("-let x = 1"))
            #expect(!diff.contains("-let z = 3"))
        }

        @Test("mid-file delete diff shows only the removed line")
        func diffMiddleDeleteIsMinimal() async throws {
            let path = try makeTempFile("let x = 1\nlet y = 2\nlet z = 3\n", "d2.swift")
            defer { try? FileManager.default.removeItem(atPath: path) }

            let (output, _) = try await runTool(["edit", "delete", path, "--lines", "2-2", "--show-diff"])
            let json = parsedJSON(output)
            let diff = json["diff"] as? String ?? ""
            #expect(diff.contains("-let y = 2"))
            #expect(!diff.contains("-let x = 1"))
            #expect(!diff.contains("-let z = 3"))
        }

        // MARK: - short output (bug: raw Swift reflection dump)

        @Test("short output is human text, not reflection dumps")
        func shortFormatIsHumanReadable() async throws {
            let srcDir = packageDir + "/Sources/NormalizerCore"

            // command -> (argv, artifact that must NOT appear); argv starts with
            // the subcommand name
            let cases: [(String, [String], String)] = [
                ("members", ["members", srcDir, "--type", "Normalizer", "--output-format", "short"], "MemberItem("),
                ("complexity", ["complexity", srcDir, "--output-format", "short"], "ComplexityItem("),
                ("callgraph", ["callgraph", srcDir, "--output-format", "short"], "CallEdge("),
                ("public-api", ["public-api", srcDir, "--output-format", "short"], "ApiItem("),
                ("conformances", ["conformances", srcDir, "--output-format", "short"], "ConformanceItem("),
                ("force-unwraps", ["force-unwraps", srcDir, "--output-format", "short"], "ForceUnwrapItem("),
            ]
            for (cmd, argv, forbidden) in cases {
                let (output, code) = try await runTool(argv)
                #expect(code == 0, "\(cmd) short should exit 0")
                #expect(!output.contains(forbidden), "\(cmd) short must not dump reflection")
                // short output must carry a file:line prefix — unless the command
                // legitimately found nothing (e.g. force-unwraps on a clean dir)
                if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    #expect(output.contains(".swift:"), "\(cmd) short should be location-prefixed")
                }
            }
        }

        // MARK: - audit fixes (unknown subcommand, UTF-8 drops, validate exit)

        @Test("unknown subcommand is a hard error, not a silent find fall-through")
        func unknownSubcommandIsHardError() async throws {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("unk-\\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let (output, code) = try await runTool(["indexx", "."], cwd: dir.path)
            #expect(code != 0, "typo'd subcommand must not exit 0")
            #expect(
                output.localizedCaseInsensitiveContains("unexpected") || output.localizedCaseInsensitiveContains("unknown"),
                "should reject the unknown token: \(output)"
            )
        }

        @Test("non-utf8 file is skipped with a stderr warning, exit 0")
        func nonUtf8FileWarns() async throws {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("u8-\\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            // latin-1 byte sequence not valid utf-8
            let bad = dir.appendingPathComponent("Latino.swift")
            var bytes = Array("public func ok() {}\n".utf8)
            bytes.append(0xE9) // é in latin-1, invalid utf-8 continuation
            try Data(bytes).write(to: bad)

            let (output, code) = try await runTool(["declarations", dir.path, "--all"])
            #expect(code == 0)
            #expect(output.localizedCaseInsensitiveContains("skipped"), "should warn about the dropped file: \\(output)")
        }

        @Test("validate exits non-zero when syntax errors are found")
        func validateExitsNonZeroOnErrors() async throws {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("val-\\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let broken = dir.appendingPathComponent("Broken.swift")
            try "struct S { func f( }\n".write(to: broken, atomically: true, encoding: .utf8)

            let (output, code) = try await runTool(["validate", broken.path, "--output-format", "compact"])
            #expect(code != 0, "validate with syntax errors must exit non-zero")
            #expect(output.contains("expected"))
        }

        // MARK: - bare invocation defaults (bug: paths were required at parse time)

        @Test("declarations/imports/index work with no path args")
        func bareInvocationDefaultsToCwd() async throws {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bare-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let src = dir.appendingPathComponent("Sample.swift")
            try "public struct SampleThing {}\n".write(to: src, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: dir) }

            let (queryOut, queryCode) = try await runTool(["declarations", "--all", "--count"], cwd: dir.path)
            #expect(queryCode == 0)
            #expect(queryOut.trimmingCharacters(in: .whitespacesAndNewlines) == "1")

            let (depsOut, depsCode) = try await runTool(["imports"], cwd: dir.path)
            #expect(depsCode == 0)
            let trimmedDeps = depsOut.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(trimmedDeps.contains("Sample.swift") || trimmedDeps == "[]")

            let (idxOut, idxCode) = try await runTool(["index"], cwd: dir.path)
            #expect(idxCode == 0)
            #expect(idxOut.contains("Sample.swift"))
        }

        // MARK: - build exit-code contract

        @Test("build exits non-zero when the build cannot succeed")
        func buildFailsLoudly() async throws {
            // an empty dir with no Package.swift — `swift build` cannot succeed
            // here. `build` must signal the failure on its exit code: a failed or
            // timed-out build used to be reported as exit 0, which nested callers
            // (the install lifecycle test) mistook for success.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("buildfail-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let (out, code) = try await runTool(["build", dir.path])
            #expect(code != 0, "failed build must not exit 0: \(out)")
            #expect(out.contains("\"succeeded\":false"), "result JSON should mark the build as not succeeded: \(out)")
        }

        // MARK: - install/uninstall lifecycle (new subcommands)

        @Test("install then uninstall lands and removes binaries + plugin")
        func installUninstallLifecycle() async throws {
            let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("life-\(UUID().uuidString)")
            let binDir = sandbox.appendingPathComponent("bin").path
            let pluginDir = sandbox.appendingPathComponent("plugins").path
            let prefix = sandbox.appendingPathComponent("prefix").path
            try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: sandbox) }

            // sandbox HOME + env so nothing touches the real host. PLUGINS_DIR is
            // explicitly empty here — the skip path must stay deterministic even
            // when the developer's shell exports it.
            let env: [String: String] = [
                "HOME": sandbox.appendingPathComponent("home").path,
                "BIN_DIR": binDir,
                "PLUGINS_DIR": "",
                "PREFIX": prefix,
                "PATH_UPDATE": "0",
            ]
            var pluginEnv = env
            pluginEnv["PLUGINS_DIR"] = pluginDir
            try FileManager.default.createDirectory(atPath: pluginDir, withIntermediateDirectories: true)

            // the installer's --no-build path requires both prebuilt binaries in
            // the dir it is pointed at; the package's own .build holds them, but
            // the install below reads from a disjoint scratch workspace, so build
            // normalizer-tool into that scratch explicitly.
            //
            // the build goes into a scratch workspace OUTSIDE the package's
            // `.build`: SwiftPM 6.x holds the package's build lock for the whole
            // `swift test` invocation, so a nested `swift build` sharing that
            // `.build` serializes behind the parent until BuildCommand's timeout
            // fires. a disjoint scratch workspace escapes the lock entirely.
            let scratch = sandbox.appendingPathComponent("scratch-build")
            let scratchBin = "\(scratch.path)/out/Products/Debug"
            try FileManager.default.createDirectory(atPath: scratchBin, withIntermediateDirectories: true)
            let (prebuild, prebuildCode) = try await runTool(
                ["build", packageDir, "--extra-args=--scratch-path \(scratch.path) --product normalizer-tool"],
                cwd: packageDir
            )
            #expect(prebuildCode == 0, "prebuild normalizer-tool should succeed: \(prebuild)")
            // stage the already-built harness binary beside it so install --no-build
            // sees both products where it looks
            try FileManager.default.copyItem(atPath: binaryPath, toPath: "\(scratchBin)/swift-package-tool")
            #expect(FileManager.default.fileExists(atPath: "\(scratchBin)/normalizer-tool"), "normalizer-tool should land in the scratch build dir: \(scratchBin)")
            #expect(FileManager.default.fileExists(atPath: "\(scratchBin)/swift-package-tool"), "staged harness binary should exist: \(scratchBin)/swift-package-tool")

            // install with no plugins dir: binaries land, the plugin step skips
            let (installOut, installCode) = try await runTool(
                ["install", "--no-build", "--debug", "--build-dir", scratchBin, "--no-path-update", "--no-interactive"],
                cwd: packageDir, env: env
            )
            #expect(installCode == 0, "install should succeed: \(installOut)")
            #expect(FileManager.default.fileExists(atPath: "\(binDir)/swift-package-tool"))
            #expect(FileManager.default.fileExists(atPath: "\(binDir)/normalizer-tool"))
            let pluginManifest = "\(pluginDir)/swift-package-utilitykit/manifest.json"
            #expect(!FileManager.default.fileExists(atPath: pluginManifest), "no plugins dir requested — adapter must be skipped: \(installOut)")

            // install with PLUGINS_DIR: the adapter manifest lands
            let (pluginInstallOut, pluginInstallCode) = try await runTool(
                ["install", "--no-build", "--debug", "--build-dir", scratchBin, "--no-path-update", "--no-interactive"],
                cwd: packageDir, env: pluginEnv
            )
            #expect(pluginInstallCode == 0, "adapter install should succeed: \(pluginInstallOut)")
            #expect(FileManager.default.fileExists(atPath: pluginManifest))

            // uninstall: both binaries and the plugin are removed
            let (removeOut, removeCode) = try await runTool(
                ["uninstall", "--force", "--no-path-update", "--bin-dir", binDir, "--plugins-dir", pluginDir, "--prefix", prefix],
                env: env
            )
            #expect(removeCode == 0, "uninstall should succeed: \(removeOut)")
            #expect(!FileManager.default.fileExists(atPath: "\(binDir)/swift-package-tool"))
            #expect(!FileManager.default.fileExists(atPath: "\(binDir)/normalizer-tool"))
            #expect(!FileManager.default.fileExists(atPath: pluginManifest))
        }

        @Test("uninstall without --plugins-dir leaves the plugin untouched")
        func uninstallSkipsPluginWithoutDir() async throws {
            let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("uninst-\(UUID().uuidString)")
            let binDir = sandbox.appendingPathComponent("bin").path
            let pluginDir = sandbox.appendingPathComponent("plugins").path
            try FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: "\(pluginDir)/swift-package-utilitykit", withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: sandbox) }

            // fake installed binaries + adapter manifest so uninstall has real targets
            try "fake".write(toFile: "\(binDir)/swift-package-tool", atomically: true, encoding: .utf8)
            try "{}\n".write(toFile: "\(pluginDir)/swift-package-utilitykit/manifest.json", atomically: true, encoding: .utf8)

            let env: [String: String] = [
                "HOME": sandbox.appendingPathComponent("home").path,
                "PATH_UPDATE": "0",
                "PLUGINS_DIR": "",
            ]
            let (out, code) = try await runTool(
                ["uninstall", "--force", "--no-path-update", "--bin-dir", binDir, "--prefix", sandbox.appendingPathComponent("prefix").path],
                env: env
            )
            #expect(code == 0, "uninstall should succeed: \(out)")
            #expect(!FileManager.default.fileExists(atPath: "\(binDir)/swift-package-tool"))
            #expect(FileManager.default.fileExists(atPath: "\(pluginDir)/swift-package-utilitykit/manifest.json"), "adapter must be untouched without --plugins-dir")
            #expect(out.contains("Skipping adapter plugin removal"), "uninstall should report the skip: \(out)")
        }

        // MARK: - hide-comments safety (bug: any code line containing /* was
        //           rewritten — a glob string could lose its whole declaration)

        @Test("normalizer --minify keeps code lines containing /* inside strings")
        func minifyKeepsGlobStrings() async throws {
            let source = "let glob = \"Sources/*.swift\"\nlet x = 1\n"
            let path = try makeTempFile(source, "hide-code.swift")
            defer { try? FileManager.default.removeItem(atPath: path) }

            let (out, code) = try await runTool(["--minify", "--file", path], binary: normalizerPath)
            #expect(code == 0, "\(out)")
            let content = try String(contentsOfFile: path, encoding: .utf8)
            #expect(content == source, "minify must not touch code lines: \(content)")
        }

        @Test("normalizer --minify hides multi-line block comment interiors")
        func minifyHidesBlockCommentInterior() async throws {
            let source = "/* secret one\n   secret two\n   secret three */\nlet y = 2\n"
            let path = try makeTempFile(source, "hide-block.swift")
            defer { try? FileManager.default.removeItem(atPath: path) }

            let (out, code) = try await runTool(["--minify", "--file", path], binary: normalizerPath)
            #expect(code == 0, "\(out)")
            let content = try String(contentsOfFile: path, encoding: .utf8)
            #expect(content == "/* comment invisible\n* comment invisible\ncomment invisible */\nlet y = 2\n", "interior comment content must be hidden: \(content)")
        }

        @Test("normalizer --minify keeps code after a same-line block comment")
        func minifyKeepsCodeAfterBlockComment() async throws {
            let source = "/* note */ let x = 1\n"
            let path = try makeTempFile(source, "hide-mixed.swift")
            defer { try? FileManager.default.removeItem(atPath: path) }

            let (out, code) = try await runTool(["--minify", "--file", path], binary: normalizerPath)
            #expect(code == 0, "\(out)")
            let content = try String(contentsOfFile: path, encoding: .utf8)
            #expect(content == "/* comment invisible */ let x = 1\n")
        }

        // MARK: - format --minify string-literal safety (bug: the whole-string
        //           cleanup ran inside multi-line literals, changing values)

        @Test("format --minify preserves whitespace inside multi-line string literals")
        func formatMinifyPreservesMultilineString() async throws {
            let source = "let s = \"\"\"\n    line1\n        indented\n        deepLast\n    keep   \n    \"\"\"\nprint(s)\n"
            let path = try makeTempFile(source, "minify-string.swift")
            defer { try? FileManager.default.removeItem(atPath: path) }

            let (out, code) = try await runTool(["format", path, "--minify"])
            #expect(code == 0, "\(out)")
            let minified = try String(contentsOfFile: path, encoding: .utf8)
            // the closing delimiter is dedented to column 0, so preserved interior
            // whitespace is exactly the literal's value: relative indentation on a
            // middle line, on the last content line, and trailing spaces.
            #expect(minified.contains("\n    indented\n"), "interior indentation lost: \(minified)")
            #expect(minified.contains("\n    deepLast\n"), "last content line indentation lost: \(minified)")
            #expect(minified.contains("keep   \n"), "trailing spaces inside the literal lost: \(minified)")
        }

        @Test("format --minify preserves blank lines inside multi-line string literals")
        func formatMinifyPreservesStringBlankLines() async throws {
            let source = "let a = \"\"\"\n    first\n\n\n    after\n    \"\"\"\n"
            let path = try makeTempFile(source, "minify-string-blanks.swift")
            defer { try? FileManager.default.removeItem(atPath: path) }

            let (out, code) = try await runTool(["format", path, "--minify"])
            #expect(code == 0, "\(out)")
            let minified = try String(contentsOfFile: path, encoding: .utf8)
            #expect(minified.contains("first\n\n\nafter"), "blank lines inside the literal collapsed: \(minified)")
        }

        // MARK: - utf-8 byte offsets in edits (bug: byte offsets were used as
        //           character indices — a trap, or a silently misplaced edit)

        @Test("add-member does not trap on files with multi-byte characters")
        func addMemberWithMultibyteCharacters() async throws {
            let source = "// éééé\nstruct Foo {\n    let a = 1\n}\n"
            let path = try makeTempFile(source, "add-member-unicode.swift")
            defer { try? FileManager.default.removeItem(atPath: path) }

            let (out, code) = try await runTool(["edit", "add-member", path, "--type", "Foo", "--property", "var b: Int"])
            #expect(code == 0, "must not trap: \(out)")
            let json = parsedJSON(out)
            #expect(json["modified"] as? Bool == true)
            #expect(json["verified"] as? Bool == true)
            let content = try String(contentsOfFile: path, encoding: .utf8)
            #expect(content == "// éééé\nstruct Foo {\n    let a = 1\n\n    var b: Int\n}\n")
        }

        @Test("add-member keeps the member inside the type when bytes shift the offset")
        func addMemberStaysInsideTheType() async throws {
            // 17 two-byte characters shift the closing brace 17 characters; the
            // old math landed inside the next declaration and wrote there
            let source = "// " + String(repeating: "é", count: 17) + "\n"
                + "struct Foo {\n    let a = 1\n}\nstruct Bar {}\nstruct Baz {}\n"
            let path = try makeTempFile(source, "add-member-shift.swift")
            defer { try? FileManager.default.removeItem(atPath: path) }

            let (out, code) = try await runTool(["edit", "add-member", path, "--type", "Foo", "--property", "var b: Int"])
            #expect(code == 0, "\(out)")
            let content = try String(contentsOfFile: path, encoding: .utf8)
            #expect(content.contains("    let a = 1\n\n    var b: Int\n}"), "member must land inside Foo: \(content)")
            #expect(content.contains("}\nstruct Bar {}\nstruct Baz {}\n"), "other declarations must stay intact: \(content)")
        }

        @Test("force-unwraps does not trap on files with multi-byte characters")
        func forceUnwrapsWithMultibyteCharacters() async throws {
            let source = "// " + String(repeating: "é", count: 60) + "\nlet x = maybe()!\n"
            let path = try makeTempFile(source, "force-unwrap-unicode.swift")
            defer { try? FileManager.default.removeItem(atPath: path) }

            let (out, code) = try await runTool(["force-unwraps", path, "--output-format", "json"])
            #expect(code == 0, "must not trap: \(out)")
            #expect(out.contains("maybe()!"), "context snippet must include the finding: \(out)")
        }

        // MARK: - location reporting (bug: positions included leading trivia, so a
        //           declaration's line pointed at the previous token; columns
        //           counted bytes instead of characters)

        @Test("declarations reports each declaration's own line, not its leading trivia")
        func queryReportsDeclarationLines() async throws {
            let source = "import Foundation\n\n/// doc for alpha\nfunc alpha() {}\n\n// note\nfunc beta() {}\n"
            let path = try makeTempFile(source, "locations.swift")
            defer { try? FileManager.default.removeItem(atPath: path) }

            let (out, code) = try await runTool(["declarations", path, "--all", "--output-format", "json"])
            #expect(code == 0, "\(out)")
            let decls = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [[String: Any]] ?? []
            var lines: [String: Int] = [:]
            for decl in decls {
                if let name = decl["name"] as? String, let line = decl["line"] as? Int { lines[name] = line }
            }
            #expect(lines["alpha"] == 4, "alpha must report its own line: \(out)")
            #expect(lines["beta"] == 7, "beta must report its own line: \(out)")
        }

        @Test("inspect reports the symbol's own line")
        func inspectReportsDeclarationLine() async throws {
            let path = try makeTempFile("/// doc\nfunc alpha() {}\n", "inspect-loc.swift")
            defer { try? FileManager.default.removeItem(atPath: path) }

            let (out, code) = try await runTool(["inspect", path, "--symbol", "alpha", "--output-format", "json"])
            #expect(code == 0, "\(out)")
            let json = parsedJSON(out)
            #expect(json["line"] as? Int == 2, "\(out)")
            #expect(json["column"] as? Int == 1, "\(out)")
        }

        @Test("columns count characters, not bytes")
        func columnsCountCharacters() async throws {
            // `struct` starts at character column 10; the two é are two bytes each
            let path = try makeTempFile("/* éé */ struct Foo {}\n", "unicode-column.swift")
            defer { try? FileManager.default.removeItem(atPath: path) }

            let (out, code) = try await runTool(["declarations", path, "--all", "--output-format", "json"])
            #expect(code == 0, "\(out)")
            let decls = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [[String: Any]] ?? []
            let foo = decls.first { $0["name"] as? String == "Foo" }
            #expect(foo?["line"] as? Int == 1, "\(out)")
            #expect(foo?["column"] as? Int == 10, "column must count characters: \(out)")
        }

        @Test("doc-reference-check points at the reference, not the declaration")
        func doccCheckReportsReferenceLocation() async throws {
            let source = "struct S {\n    /// bad `Missing` ref here\n    func gamma() {}\n}\n"
            let path = try makeTempFile(source, "docc-loc.swift")
            defer { try? FileManager.default.removeItem(atPath: path) }

            let (out, code) = try await runTool(["doc-reference-check", path, "--output-format", "json"])
            #expect(code == 0, "\(out)")
            let warnings = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [[String: Any]] ?? []
            #expect(warnings.first?["referencedSymbol"] as? String == "Missing", "\(out)")
            #expect(warnings.first?["line"] as? Int == 2, "\(out)")
            #expect(warnings.first?["column"] as? Int == 14, "\(out)")
        }

        @Test("doc-reference-check locates a reference in a later doc-comment line")
        func doccCheckReportsMultiLineCommentLocation() async throws {
            let source = "/// first line is fine\n/// second line references `AlsoMissing`\nfunc beta() {}\n"
            let path = try makeTempFile(source, "docc-loc2.swift")
            defer { try? FileManager.default.removeItem(atPath: path) }

            let (out, code) = try await runTool(["doc-reference-check", path, "--output-format", "json"])
            #expect(code == 0, "\(out)")
            let warnings = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [[String: Any]] ?? []
            #expect(warnings.first?["line"] as? Int == 2, "reference is on the second comment line: \(out)")
            #expect(warnings.first?["column"] as? Int == 29, "\(out)")
        }

        // MARK: - nested types (bug: rewriters returned non-matching nodes without
        //           visiting children, so a nested target was never found)

        @Test("add-conformance finds a nested type")
        func addConformanceFindsNestedType() async throws {
            let source = "struct Outer {\n    struct Inner {}\n}\n"
            let path = try makeTempFile(source, "nested-conformance.swift")
            defer { try? FileManager.default.removeItem(atPath: path) }

            let (out, code) = try await runTool(["edit", "add-conformance", path, "--type", "Inner", "--protocol", "Sendable"])
            #expect(code == 0, "\(out)")
            let json = parsedJSON(out)
            #expect(json["modified"] as? Bool == true, "nested type must be found: \(out)")
            let content = try String(contentsOfFile: path, encoding: .utf8)
            // the clause is written flush against the type name (`Inner: Sendable`,
            // not `Inner : Sendable`)
            #expect(content.contains("struct Inner: Sendable {}"), "\(content)")
        }

        @Test("sort finds a nested type")
        func sortFindsNestedType() async throws {
            let source = "struct Outer {\n    struct Inner {\n        var b = 2\n        var a = 1\n    }\n}\n"
            let path = try makeTempFile(source, "nested-sort.swift")
            defer { try? FileManager.default.removeItem(atPath: path) }

            let (out, code) = try await runTool(["edit", "sort", path, "--type", "Inner"])
            #expect(code == 0, "\(out)")
            let json = parsedJSON(out)
            #expect(json["modified"] as? Bool == true, "nested type must be found: \(out)")

            let content = try String(contentsOfFile: path, encoding: .utf8)
            let lines = content.split(separator: "\n").map(String.init)
            let aIndex = lines.firstIndex { $0.contains("var a") } ?? -1
            let bIndex = lines.firstIndex { $0.contains("var b") } ?? -1
            #expect(aIndex >= 0 && bIndex >= 0, "both members must survive: \(content)")
            #expect(aIndex < bIndex, "members must sort inside the nested type: \(content)")
        }

        // MARK: - backup reuse (bug: a stale .bak made the second edit fail)

        @Test("--backup works twice on the same file")
        func backupReplacesStaleBackup() async throws {
            let path = try makeTempFile("let a = 1\n", "backup-twice.swift")
            defer { try? FileManager.default.removeItem(atPath: path) }

            let (out1, code1) = try await runTool(["edit", "insert", path, "--content", "let first = 1", "--after", "let a = 1", "--backup"])
            #expect(code1 == 0, "\(out1)")
            let (out2, code2) = try await runTool(["edit", "insert", path, "--content", "let second = 2", "--after", "let first = 1", "--backup"])
            #expect(code2 == 0, "second run must not fail on the stale backup: \(out2)")
            #expect(parsedJSON(out2)["modified"] as? Bool == true, "\(out2)")

            let content = try String(contentsOfFile: path, encoding: .utf8)
            #expect(content.contains("let first = 1"), "\(content)")
            #expect(content.contains("let second = 2"), "\(content)")

            let backup = try String(contentsOfFile: path + ".bak", encoding: .utf8)
            #expect(backup.contains("let first = 1"), "backup holds the state before the second edit: \(backup)")
            #expect(!backup.contains("let second = 2"), "backup must be refreshed, not stale: \(backup)")
        }

        // MARK: - edit diagnostics (bug: a transform's note was discarded, so a
        //           no-op edit and a malformed range were both silent)

        @Test("an insert anchor miss reports why and exits non-zero")
        func insertAnchorMissReportsNote() async throws {
            let path = try makeTempFile("let a = 1\n", "anchor-miss.swift")
            defer { try? FileManager.default.removeItem(atPath: path) }

            let (out, code) = try await runTool(["edit", "insert", path, "--content", "let x = 1", "--after", "NOT-THERE"])
            #expect(code != 0, "an anchor miss must not exit 0: \(out)")
            let json = parsedJSON(out)
            #expect(json["modified"] as? Bool == false, "\(out)")
            #expect(json["warning"] as? String == "no line containing 'NOT-THERE' found", "\(out)")
            #expect(json["status"] as? String == "missed", "\(out)")
        }

        @Test("a delete range beyond the file reports why and exits non-zero")
        func deleteRangeBeyondEOFReportsNote() async throws {
            let path = try makeTempFile("let a = 1\nlet b = 2\n", "range-miss.swift")
            defer { try? FileManager.default.removeItem(atPath: path) }

            let (out, code) = try await runTool(["edit", "delete", path, "--lines", "100-200"])
            #expect(code != 0, "a range that selects no lines must not exit 0: \(out)")
            let json = parsedJSON(out)
            #expect(json["modified"] as? Bool == false, "\(out)")
            #expect(json["warning"] as? String == "line range '100-200' selects no lines", "\(out)")
            #expect(json["status"] as? String == "missed", "\(out)")
        }

        @Test("a malformed --lines range is a usage error, not a silent no-op")
        func malformedLineRangeIsUsageError() async throws {
            let path = try makeTempFile("let a = 1\n", "range-bad.swift")
            defer { try? FileManager.default.removeItem(atPath: path) }

            let (out, code) = try await runTool(["edit", "delete", path, "--lines", "garbage"])
            #expect(code != 0, "malformed range must not exit 0: \(out)")
            #expect(out.contains("invalid line range"), "\(out)")
            let content = try String(contentsOfFile: path, encoding: .utf8)
            #expect(content == "let a = 1\n", "file must be untouched: \(content)")
        }

        @Test("a replace that matches nothing reports why and exits non-zero")
        func replaceMissReportsNote() async throws {
            let path = try makeTempFile("let a = 1\n", "replace-miss.swift")
            defer { try? FileManager.default.removeItem(atPath: path) }

            let (out, code) = try await runTool(["edit", "replace", path, "--old", "NOT-THERE", "--new", "x"])
            #expect(code != 0, "a replace miss must not exit 0: \(out)")
            let json = parsedJSON(out)
            #expect(json["warning"] as? String == "no occurrence of 'NOT-THERE' found", "\(out)")
            #expect(json["status"] as? String == "missed", "\(out)")
            let content = try String(contentsOfFile: path, encoding: .utf8)
            #expect(content == "let a = 1\n", "file must be untouched: \(content)")
        }

        @Test("batch reports the miss and exits non-zero")
        func batchAnchorMissReportsNote() async throws {
            let target = try makeTempFile("let a = 1\n", "batch-miss.swift")
            defer { try? FileManager.default.removeItem(atPath: target) }
            let plan = "{\"operations\":[{\"command\":\"insert\",\"file\":\"\(target)\",\"content\":\"x\",\"after\":\"NOPE\"}]}"
            let planPath = try makeTempFile(plan, "plan.json")
            defer { try? FileManager.default.removeItem(atPath: planPath) }

            let (out, code) = try await runTool(["edit", "batch", planPath])
            #expect(code != 0, "a batch whose operation missed must not exit 0: \(out)")
            let results = parsedJSON(out)["results"] as? [[String: Any]] ?? []
            #expect(results.first?["warning"] as? String == "no line containing 'NOPE' found", "\(out)")
            #expect(results.first?["status"] as? String == "missed", "\(out)")
        }

        // MARK: - CLI contract (bugs: format silently ignored most output formats,
        //           a failed clean exited 0, and normalizer-tool swallowed
        //           file-level failures)

        @Test("format emits csv and short output when asked")
        func formatHonorsAllOutputFormats() async throws {
            let path = try makeTempFile("let x = 1\n", "format-csv.swift")
            defer { try? FileManager.default.removeItem(atPath: path) }

            let (shortOut, shortCode) = try await runTool(["format", path, "--output-format", "short"])
            #expect(shortCode == 0, "\(shortOut)")
            #expect(shortOut.contains("\(path): unchanged"), "short must be human text: \(shortOut)")
            #expect(!shortOut.contains("FormatResult("), "short must not dump reflection: \(shortOut)")

            let (csvOut, csvCode) = try await runTool(["format", path, "--output-format", "csv"])
            #expect(csvCode == 0, "\(csvOut)")
            #expect(!csvOut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "csv must emit output: \(csvOut)")
            #expect(csvOut.contains("unchanged"), "\(csvOut)")
        }

        @Test("a failed clean exits non-zero")
        func failedCleanExitsNonZero() async throws {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cleanfail-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            try "// swift-tools-version:6.0\nimport PackageDescription\nlet package = Package(name: \"CleanFail\")\n"
                .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

            // an empty PATH makes the spawned `swift package clean` unrunnable — a
            // deterministic clean failure for the exit-code contract
            let (out, code) = try await runTool(["clean", dir.path], env: ["PATH": "/nonexistent"])
            #expect(code != 0, "a failed clean must not exit 0: \(out)")
            let payload = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [[String: Any]] ?? []
            #expect(payload.first?["success"] as? Bool == false, "the payload must report the failure: \(out)")

            // a clean that succeeds stays exit 0
            let (okOut, okCode) = try await runTool(["clean", dir.path])
            #expect(okCode == 0, "a successful clean must stay exit 0: \(okOut)")
        }

        @Test("normalizer-tool exits non-zero when a file cannot be normalized")
        func normalizerFailsLoudly() async throws {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("norm-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let bad = dir.appendingPathComponent("Bad.swift")
            var bytes = Array("let ok = 1\n".utf8)
            bytes.append(0xE9)   // latin-1 é: not valid utf-8
            try Data(bytes).write(to: bad)

            let (out, code) = try await runTool(["--file", bad.path], binary: normalizerPath)
            #expect(code != 0, "a failed file must fail the run: \(out)")
            #expect(out.contains("1 failed"), "the summary must report it: \(out)")

            let good = dir.appendingPathComponent("Good.swift")
            try "let ok = 1\n".write(to: good, atomically: true, encoding: .utf8)
            let (okOut, okCode) = try await runTool(["--file", good.path], binary: normalizerPath)
            #expect(okCode == 0, "a clean run stays exit 0: \(okOut)")
        }

        // MARK: - git provenance (build tool plugin)

        @Test("git-metadata-tool reports the checkout's commit")
        func gitMetadataToolReportsCommit() async throws {
            let tool = packageDir + "/.build/debug/git-metadata-tool"
            guard FileManager.default.isExecutableFile(atPath: tool) else {
                Issue.record("build git-metadata-tool first (swift build) — \(tool) is missing")
                return
            }
            let (headOut, headCode) = try await runTool(["rev-parse", "--short", "HEAD"], binary: "/usr/bin/git", cwd: packageDir)
            #expect(headCode == 0, "\(headOut)")
            let short = headOut.trimmingCharacters(in: .whitespacesAndNewlines)

            let (out, code) = try await runTool(["--print", "--repo", packageDir], binary: tool)
            #expect(code == 0, "\(out)")
            #expect(out.contains("shortCommitHash: \(short)"), "\(out)")
            #expect(out.contains("branch: "), "\(out)")
        }

        @Test("--version names the commit the binary was built from")
        func versionReportsGitMetadata() async throws {
            let (headOut, headCode) = try await runTool(["rev-parse", "--short", "HEAD"], binary: "/usr/bin/git", cwd: packageDir)
            let short = headOut.trimmingCharacters(in: .whitespacesAndNewlines)

            let (out, code) = try await runTool(["--version"])
            #expect(code == 0, "\(out)")
            #expect(out.contains("3.0.0"), "the semantic version leads: \(out)")
            if headCode == 0, !short.isEmpty {
                #expect(out.contains("+\(short)"), "the version must name the commit it was built from: \(out)")
            }
        }
    }
}
