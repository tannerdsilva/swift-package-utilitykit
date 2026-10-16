import Testing
import Foundation
import SubprocessCore

/// the exit-code contract for edit commands, pinned black-box against the
/// built binary: a selector miss or a blocked write prints its EditResult and
/// exits non-zero; an applied edit or an already-satisfied state exits 0.
///
/// this suite exists because the tool used to exit 0 for every one of these
/// paths while the payload said `modified:false` — the failure was visible
/// only to a consumer parsing stdout (bugfix202).
///
/// it also owns the SEMANTIC contract the exit codes ride on: every `wrap`
/// container keeps the code it wraps, content escapes expand unless
/// `--literal-content` says the bytes are already exact, and a `batch` plan's
/// operations behave exactly like the standalone command they name.
extension NormalizerCoreTestsRoot {
    @Suite("edit exit-code contract")
    struct EditExitContractTests {

        let binaryPath: String

        init() throws {
            let pkgDir = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // Tests/NormalizerCoreTests/
                .deletingLastPathComponent()  // Tests/
                .deletingLastPathComponent()  // swift-package-utilitykit/
            binaryPath = pkgDir
                .appendingPathComponent(".build/debug/swift-package-tool").path
        }

        // MARK: - helpers

        private func runTool(_ args: [String]) async throws -> (output: String, exitCode: Int32) {
            let outcome = try await Subprocess.capture(binaryPath, args)
            return (outcome.stdout + outcome.stderr, outcome.exitCode)
        }

        private func makeTempFile(_ content: String, _ name: String) throws -> String {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("editcontract-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let path = dir.appendingPathComponent(name).path
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            return path
        }

        private func cleanup(_ path: String) {
            try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
        }

        private func parsedJSON(_ output: String) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: output.data(using: .utf8) ?? Data()))
                as? [String: Any] ?? [:]
        }

        private func readFile(_ path: String) -> String {
            (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        }

        // MARK: - misses

        @Test("every selector miss exits non-zero with status missed and leaves the file untouched")
        func everySelectorMissExitsNonZero() async throws {
            let fixture = "let a = 1\n\nstruct S {\n    var b: Int\n    var a: Int\n}\n"
            let cases: [(String, [String])] = [
                ("replace-text", ["edit", "replace", "{f}", "--old", "NOT-THERE", "--new", "x"]),
                ("rename-miss", ["edit", "rename", "{f}", "--old-name", "Nope", "--new-name", "X"]),
                ("insert-after", ["edit", "insert", "{f}", "--content", "let c = 3", "--after", "NOPE"]),
                ("insert-before", ["edit", "insert", "{f}", "--content", "let c = 3", "--before", "NOPE"]),
                ("delete-matching", ["edit", "delete", "{f}", "--matching", "NOPE"]),
                ("delete-lines", ["edit", "delete", "{f}", "--lines", "100-200"]),
                ("delete-symbol", ["edit", "delete", "{f}", "--symbol", "Nope"]),
                ("wrap-lines", ["edit", "wrap", "{f}", "--lines", "100-200", "--in", "do"]),
                ("add-member", ["edit", "add-member", "{f}", "--type", "Nope", "--property", "var x: Int"]),
                ("add-conformance", ["edit", "add-conformance", "{f}", "--type", "Nope", "--protocol", "Sendable"]),
                ("sort", ["edit", "sort", "{f}", "--type", "Nope"]),
            ]
            for (name, template) in cases {
                let path = try makeTempFile(fixture, "\(name).swift")
                defer { cleanup(path) }
                let argv = template.map { $0 == "{f}" ? path : $0 }
                let (out, code) = try await runTool(argv)
                #expect(code != 0, "\(name) must exit non-zero: \(out)")
                #expect(parsedJSON(out)["status"] as? String == "missed", "\(name): \(out)")
                #expect(readFile(path) == fixture, "\(name) must not modify the file")
            }
        }

        @Test("a replace miss exits non-zero in every output format")
        func replaceMissEveryFormat() async throws {
            for fmt in ["json", "compact", "short", "csv", "jsonl"] {
                let path = try makeTempFile("let a = 1\n", "fmt-\(fmt).swift")
                defer { cleanup(path) }
                let (out, code) = try await runTool(
                    ["edit", "replace", path, "--old", "NOT-THERE", "--new", "x", "--output-format", fmt]
                )
                #expect(code != 0, "\(fmt) must exit non-zero: \(out)")
                #expect(readFile(path) == "let a = 1\n", "\(fmt) must not modify the file")
            }
        }

        // MARK: - hits

        @Test("every selector hit exits 0 with status applied and changes the file")
        func everyHitExitsZero() async throws {
            let fixture = "let a = 1\n\nstruct S {\n    var b: Int\n    var a: Int\n}\n"
            let cases: [(String, [String])] = [
                ("replace-text", ["edit", "replace", "{f}", "--old", "let a = 1", "--new", "let a = 9"]),
                ("rename-hit", ["edit", "rename", "{f}", "--old-name", "a", "--new-name", "z"]),
                ("insert-at-line", ["edit", "insert", "{f}", "--content", "let c = 3", "--at-line", "1"]),
                ("delete-lines", ["edit", "delete", "{f}", "--lines", "1-1"]),
                ("delete-symbol", ["edit", "delete", "{f}", "--symbol", "S"]),
                ("wrap-lines", ["edit", "wrap", "{f}", "--lines", "1-1", "--in", "do"]),
                ("add-import", ["edit", "add-import", "{f}", "--module", "Foundation"]),
                ("add-member", ["edit", "add-member", "{f}", "--type", "S", "--property", "var z: Int"]),
                ("add-conformance", ["edit", "add-conformance", "{f}", "--type", "S", "--protocol", "Sendable"]),
                ("sort", ["edit", "sort", "{f}", "--type", "S"]),
            ]
            for (name, template) in cases {
                let path = try makeTempFile(fixture, "\(name).swift")
                defer { cleanup(path) }
                let argv = template.map { $0 == "{f}" ? path : $0 }
                let (out, code) = try await runTool(argv)
                #expect(code == 0, "\(name) must exit 0: \(out)")
                #expect(parsedJSON(out)["status"] as? String == "applied", "\(name): \(out)")
                #expect(readFile(path) != fixture, "\(name) must change the file")
            }
        }

        // MARK: - blocked writes

        @Test("a blocked write exits non-zero unless --force applies it")
        func blockedWriteExitsNonZero() async throws {
            let fixture = "struct S {\n  var value: Int\n}\n"

            // blocked: the edit would not parse and --force was not set
            let path = try makeTempFile(fixture, "blocked.swift")
            defer { cleanup(path) }
            let (out, code) = try await runTool(["edit", "replace", path, "--old", "}", "--new", ""])
            #expect(code != 0, "a blocked write must not exit 0: \(out)")
            let json = parsedJSON(out)
            #expect(json["status"] as? String == "blocked", "\(out)")
            #expect(json["verified"] as? Bool == false, "\(out)")
            #expect(readFile(path) == fixture, "blocked write must not touch the file")

            // --force applies the same edit and exits 0
            let (forcedOut, forcedCode) = try await runTool(["edit", "replace", path, "--old", "}", "--new", "", "--force"])
            #expect(forcedCode == 0, "a forced write must exit 0: \(forcedOut)")
            #expect(parsedJSON(forcedOut)["status"] as? String == "applied", "\(forcedOut)")
            #expect(readFile(path) != fixture, "forced write must change the file")
        }

        // MARK: - dry-run mirrors the real run

        @Test("--dry-run exits like the real run would")
        func dryRunMirrorsRealRun() async throws {
            let fixture = "let a = 1\n"

            let missPath = try makeTempFile(fixture, "dry-miss.swift")
            defer { cleanup(missPath) }
            let (missOut, missCode) = try await runTool(["edit", "replace", missPath, "--old", "NOPE", "--new", "x", "--dry-run"])
            #expect(missCode != 0, "a dry-run miss must not exit 0: \(missOut)")
            #expect(parsedJSON(missOut)["status"] as? String == "missed", "\(missOut)")
            #expect(readFile(missPath) == fixture, "dry-run must not write")

            let hitPath = try makeTempFile(fixture, "dry-hit.swift")
            defer { cleanup(hitPath) }
            let (hitOut, hitCode) = try await runTool(["edit", "replace", hitPath, "--old", "let a = 1", "--new", "let a = 2", "--dry-run"])
            #expect(hitCode == 0, "a dry-run hit must exit 0: \(hitOut)")
            #expect(parsedJSON(hitOut)["status"] as? String == "applied", "\(hitOut)")
            #expect(readFile(hitPath) == fixture, "dry-run must not write")

            let blockedPath = try makeTempFile("struct S {\n  var value: Int\n}\n", "dry-blocked.swift")
            defer { cleanup(blockedPath) }
            let (blockedOut, blockedCode) = try await runTool(["edit", "replace", blockedPath, "--old", "}", "--new", "", "--dry-run"])
            #expect(blockedCode != 0, "a dry-run of a blocked edit must not exit 0: \(blockedOut)")
            #expect(parsedJSON(blockedOut)["status"] as? String == "blocked", "\(blockedOut)")
        }

        // MARK: - already-satisfied no-ops stay exit 0

        @Test("already-satisfied edits exit 0 with status alreadyCurrent")
        func alreadySatisfiedStaysZero() async throws {
            // add-import twice: the second run is a skip, not a failure
            let importPath = try makeTempFile("let q = 0\n", "dup-import.swift")
            defer { cleanup(importPath) }
            let (_, firstCode) = try await runTool(["edit", "add-import", importPath, "--module", "Foundation"])
            #expect(firstCode == 0, "first add-import must apply")
            let (dupOut, dupCode) = try await runTool(["edit", "add-import", importPath, "--module", "Foundation"])
            #expect(dupCode == 0, "an already-imported module must stay exit 0: \(dupOut)")
            #expect(parsedJSON(dupOut)["status"] as? String == "alreadyCurrent", "\(dupOut)")

            // add-conformance on an already-conforming type
            let confPath = try makeTempFile("struct U: Sendable {\n}\n", "dup-conformance.swift")
            defer { cleanup(confPath) }
            let (confOut, confCode) = try await runTool(["edit", "add-conformance", confPath, "--type", "U", "--protocol", "Sendable"])
            #expect(confCode == 0, "an already-conforming type must stay exit 0: \(confOut)")
            #expect(parsedJSON(confOut)["status"] as? String == "alreadyCurrent", "\(confOut)")

            // sort: one member is nothing to sort; an already-sorted type is a no-op
            let onePath = try makeTempFile("struct S {\n    var value: Int\n}\n", "sort-one.swift")
            defer { cleanup(onePath) }
            let (oneOut, oneCode) = try await runTool(["edit", "sort", onePath, "--type", "S"])
            #expect(oneCode == 0, "nothing-to-sort must stay exit 0: \(oneOut)")
            #expect(parsedJSON(oneOut)["status"] as? String == "alreadyCurrent", "\(oneOut)")

            let sortedFixture = "struct S {\n    var a: Int\n    var b: Int\n}\n"
            let sortedPath = try makeTempFile(sortedFixture, "sort-sorted.swift")
            defer { cleanup(sortedPath) }
            let (sortedOut, sortedCode) = try await runTool(["edit", "sort", sortedPath, "--type", "S"])
            #expect(sortedCode == 0, "an already-sorted type must stay exit 0: \(sortedOut)")
            let sortedJSON = parsedJSON(sortedOut)
            #expect(sortedJSON["status"] as? String == "alreadyCurrent", "\(sortedOut)")
            #expect(sortedJSON["modified"] as? Bool == false, "byte-identical sort must not claim modified: \(sortedOut)")
            #expect(readFile(sortedPath) == sortedFixture, "the file must be untouched")

            // replace with identical text satisfies the request trivially
            let identityPath = try makeTempFile("let x = 1\n", "identity.swift")
            defer { cleanup(identityPath) }
            let (idOut, idCode) = try await runTool(["edit", "replace", identityPath, "--old", "let x = 1", "--new", "let x = 1"])
            #expect(idCode == 0, "an identity replace must stay exit 0: \(idOut)")
            #expect(parsedJSON(idOut)["status"] as? String == "alreadyCurrent", "\(idOut)")
        }

        // MARK: - batch

        @Test("batch exits non-zero when an operation missed, and --fail-fast stops")
        func batchExitsNonZeroOnFailure() async throws {
            // a miss deep in the plan: rc reflects it, and without --fail-fast the
            // later operations still run
            let path = try makeTempFile("let a = 1\n", "batch-miss.swift")
            defer { cleanup(path) }
            let plan: [String: Any] = ["operations": [
                ["command": "replace", "file": path, "old": "NOT-THERE", "new": "x"],
                ["command": "append", "file": path, "content": "let c = 3"],
            ]]
            let planPath = try makeTempFile(
                String(data: try JSONSerialization.data(withJSONObject: plan), encoding: .utf8) ?? "{}",
                "plan-miss.json"
            )
            defer { cleanup(planPath) }
            let (out, code) = try await runTool(["edit", "batch", planPath])
            #expect(code != 0, "a batch with a missed operation must not exit 0: \(out)")
            let results = parsedJSON(out)["results"] as? [[String: Any]] ?? []
            #expect(results.count == 2, "without --fail-fast every operation is still attempted: \(out)")
            #expect(results.first?["status"] as? String == "missed", "\(out)")

            // --fail-fast stops at the miss: one result, the append never runs
            let ffPath = try makeTempFile("let a = 1\n", "batch-ff.swift")
            defer { cleanup(ffPath) }
            let ffPlan: [String: Any] = ["operations": [
                ["command": "replace", "file": ffPath, "old": "NOT-THERE", "new": "x"],
                ["command": "append", "file": ffPath, "content": "let c = 3"],
            ]]
            let ffPlanPath = try makeTempFile(
                String(data: try JSONSerialization.data(withJSONObject: ffPlan), encoding: .utf8) ?? "{}",
                "plan-ff.json"
            )
            defer { cleanup(ffPlanPath) }
            let (ffOut, ffCode) = try await runTool(["edit", "batch", ffPlanPath, "--fail-fast"])
            #expect(ffCode != 0, "a fail-fast batch with a miss must not exit 0: \(ffOut)")
            let ffResults = parsedJSON(ffOut)["results"] as? [[String: Any]] ?? []
            #expect(ffResults.count == 1, "--fail-fast must stop at the miss: \(ffOut)")
            #expect(readFile(ffPath) == "let a = 1\n", "the append must not have run")

            // an all-hit batch stays exit 0
            let okPath = try makeTempFile("let a = 1\n", "batch-ok.swift")
            defer { cleanup(okPath) }
            let okPlan: [String: Any] = ["operations": [
                ["command": "replace", "file": okPath, "old": "let a = 1", "new": "let a = 9"],
                ["command": "append", "file": okPath, "content": "let c = 3"],
            ]]
            let okPlanPath = try makeTempFile(
                String(data: try JSONSerialization.data(withJSONObject: okPlan), encoding: .utf8) ?? "{}",
                "plan-ok.json"
            )
            defer { cleanup(okPlanPath) }
            let (okOut, okCode) = try await runTool(["edit", "batch", okPlanPath])
            #expect(okCode == 0, "an all-hit batch must exit 0: \(okOut)")
        }

        // MARK: - schema

        @Test("the EditResult schema carries status")
        func schemaCarriesStatus() async throws {
            let path = try makeTempFile("let a = 1\n", "schema.swift")
            defer { cleanup(path) }
            let (out, code) = try await runTool(["edit", "replace", path, "--schema"])
            #expect(code == 0, "\(out)")
            #expect(out.contains("\"status\""), "the schema must document status: \(out)")
            #expect(out.contains("\"missed\"") && out.contains("\"blocked\""), "\(out)")
        }

        // MARK: - wrap: every container keeps the code it wraps

        @Test("wrap --in guard-let inserts the guard above the code instead of deleting it")
        func guardLetWrapKeepsBody() async throws {
            let fixture = "func f() {\n    let a = 1\n    print(a)\n}\n"
            let path = try makeTempFile(fixture, "wrap-guard.swift")
            defer { cleanup(path) }

            let (out, code) = try await runTool(
                ["edit", "wrap", path, "--lines", "2-3", "--in", "guard-let", "--variable", "x", "--else", "return"])
            #expect(code == 0, "\(out)")
            let content = readFile(path)
            // a guard conditions the code that FOLLOWS it, so the selected lines
            // must survive: replacing them (the other containers' shape) deleted
            // the very code the guard protects, and the write was still reported
            // as applied + verified.
            let guardLine = try #require(content.range(of: "guard let x else"), "\(content)")
            let body = try #require(content.range(of: "let a = 1"), "\(content)")
            #expect(guardLine.lowerBound < body.lowerBound, "the guard goes ABOVE the body: \(content)")
            #expect(content.contains("print(a)"), "the wrapped lines survive: \(content)")
        }

        @Test("wrap --in do-catch writes a compilable catch body")
        func doCatchWrapApplies() async throws {
            let fixture = "func f() {\n    let a = 1\n    print(a)\n}\n"
            let path = try makeTempFile(fixture, "wrap-docatch.swift")
            defer { cleanup(path) }

            let (out, code) = try await runTool(["edit", "wrap", path, "--lines", "2-3", "--in", "do-catch"])
            #expect(code == 0, "do-catch must apply, not block on a placeholder: \(out)")
            #expect(parsedJSON(out)["status"] as? String == "applied", "\(out)")

            let content = readFile(path)
            #expect(content.contains("} catch {"), "\(content)")
            #expect(!content.contains("<#"), "no editor placeholder may be written: \(content)")
            #expect(content.contains("let a = 1") && content.contains("print(a)"), "\(content)")
        }

        @Test("wrap --in guard-let refuses an else-less guard")
        func guardLetWrapRequiresElse() async throws {
            let fixture = "func f() {\n    let a = 1\n}\n"
            let path = try makeTempFile(fixture, "wrap-guard-noelse.swift")
            defer { cleanup(path) }

            // `guard let x else {}` parses, so the syntax gate cannot catch it —
            // the command refuses it instead of writing code that cannot compile.
            let (out, code) = try await runTool(
                ["edit", "wrap", path, "--lines", "2-2", "--in", "guard-let", "--variable", "x"])
            #expect(code != 0, "\(out)")
            #expect(readFile(path) == fixture, "a refused wrap must not touch the file")
        }

        // MARK: - content escaping

        @Test("content escapes expand by default and pass through under --literal-content")
        func contentEscaping() async throws {
            // the shell convention still holds: the two characters `\n` become a newline
            let expanded = try makeTempFile("// top\n", "escape-expand.swift")
            defer { cleanup(expanded) }
            let (eOut, eCode) = try await runTool(
                ["edit", "insert", expanded, "--after", "// top", "--content", #"let a = 1\nlet b = 2"#])
            #expect(eCode == 0, "\(eOut)")
            #expect(readFile(expanded).contains("let a = 1\nlet b = 2"), "\(readFile(expanded))")

            // a LITERAL backslash-n is expressible by escaping the backslash
            let literal = try makeTempFile("// top\n", "escape-literal.swift")
            defer { cleanup(literal) }
            let (lOut, lCode) = try await runTool(
                ["edit", "insert", literal, "--after", "// top", "--content", #"print("x\\ny")"#])
            #expect(lCode == 0, "\(lOut)")
            #expect(readFile(literal).contains(#"print("x\ny")"#),
                    "a Swift string-literal escape must be writable: \(readFile(literal))")

            // --literal-content delivers the bytes exactly as given (what a caller
            // building arguments as data, not through a shell, needs)
            let raw = try makeTempFile("// top\n", "escape-raw.swift")
            defer { cleanup(raw) }
            let (rOut, rCode) = try await runTool(
                ["edit", "insert", raw, "--after", "// top", "--content", #"print("x\ny")"#, "--literal-content"])
            #expect(rCode == 0, "\(rOut)")
            #expect(readFile(raw).contains(#"print("x\ny")"#),
                    "--literal-content must not reinterpret the bytes: \(readFile(raw))")
        }

        // MARK: - batch shares the commands' semantics

        @Test("a batch delete by symbol removes the declaration, not every line mentioning it")
        func batchDeleteSymbolIsASTAware() async throws {
            let fixture = """
            struct Keep {
                var value: Int
            }

            struct Drop {
                var value: Int
            }

            func make() -> Drop {
                Drop(value: 1)
            }

            """
            let path = try makeTempFile(fixture, "batch-delete-symbol.swift")
            defer { cleanup(path) }
            let planPath = try makeTempFile(
                #"{"operations":[{"command":"delete","file":"\#(path)","symbol":"Drop"}]}"#,
                "batch-delete-symbol.json")
            defer { cleanup(planPath) }

            let (out, code) = try await runTool(["edit", "batch", planPath])
            #expect(code == 0, "\(out)")
            let content = readFile(path)
            #expect(!content.contains("struct Drop"), "the named declaration must go: \(content)")
            #expect(content.contains("struct Keep"), "\(content)")
            // the old line-based form removed every non-comment line containing the
            // name — including these two, which only MENTION the type
            #expect(content.contains("func make() -> Drop {"), "a mention must survive: \(content)")
            #expect(content.contains("Drop(value: 1)"), "a mention must survive: \(content)")
        }

        @Test("a batch add-member is indented to match the type's existing members")
        func batchAddMemberUsesAST() async throws {
            let fixture = "struct S {\n    var a: Int\n}\n"
            let path = try makeTempFile(fixture, "batch-add-member.swift")
            defer { cleanup(path) }
            let planPath = try makeTempFile(
                #"{"operations":[{"command":"add-member","file":"\#(path)","typeName":"S","property":"var z: Int"}]}"#,
                "batch-add-member.json")
            defer { cleanup(planPath) }

            let (out, code) = try await runTool(["edit", "batch", planPath])
            #expect(code == 0, "\(out)")
            let content = readFile(path)
            // the old form inserted the raw declaration with no indentation
            #expect(content.contains("\n    var z: Int"), "the member is indented: \(content)")
            #expect(content.contains("    var a: Int"), "existing members survive: \(content)")
        }

        @Test("a batch append refuses prepend's afterImports instead of ignoring it")
        func batchAppendRefusesAfterImports() async throws {
            let fixture = "import Foundation\n\nlet a = 1\n"
            let path = try makeTempFile(fixture, "batch-append-afterimports.swift")
            defer { cleanup(path) }
            let planPath = try makeTempFile(
                #"{"operations":[{"command":"append","file":"\#(path)","content":"let b = 2","afterImports":true}]}"#,
                "batch-append-afterimports.json")
            defer { cleanup(planPath) }

            // `afterImports` belongs to prepend; the CLI's append has no such flag.
            // decoding it and writing at the end anyway would be a silent wrong
            // edit, so the operation must fail loudly instead.
            let (out, code) = try await runTool(["edit", "batch", planPath])
            #expect(code != 0, "\(out)")
            #expect(readFile(path) == fixture, "a refused plan must not touch the file")
        }

        @Test("a batch field error names the plan's key, not the standalone flag")
        func batchFieldErrorsNamePlanKeys() async throws {
            let path = try makeTempFile("struct S {}\n", "batch-keys.swift")
            defer { cleanup(path) }
            // "type" is what the standalone command takes; the PLAN spells it
            // "typeName". the error has to name the key a caller can actually write.
            let planPath = try makeTempFile(
                #"{"operations":[{"command":"add-member","file":"\#(path)","type":"S","property":"var a: Int"}]}"#,
                "batch-keys.json")
            defer { cleanup(planPath) }

            let (out, code) = try await runTool(["edit", "batch", planPath])
            #expect(code != 0, "\(out)")
            #expect(out.contains("typeName"), "the plan's own key must be named: \(out)")
        }

        @Test("a malformed batch plan names its JSON location — never '?' and never Swift's Index")
        func batchPlanDiagnosticsNameJSONLocations() async throws {
            // the location has to be the JSON the author wrote. before this, a
            // top-level array decoded to `... for key '?'` and an array element
            // was reported as a KEY with Swift's own `Index 0` description.
            let cases: [(name: String, plan: String, expected: [String])] = [
                ("bare-array", #"[{"command":"insert","file":"a.swift"}]"#,
                 ["expected an object like", "at root"]),
                ("no-operations", #"{}"#, ["missing key 'operations' at root"]),
                ("operations-not-array", #"{"operations":{}}"#, ["expected array at operations"]),
                ("operation-not-object", #"{"operations":[42]}"#, ["expected object at operations[0]"]),
                ("second-op-not-object",
                 #"{"operations":[{"command":"insert","file":"a.swift"},42]}"#,
                 ["expected object at operations[1]"]),
                ("null-command", #"{"operations":[{"command":null,"file":"a.swift"}]}"#,
                 ["expected string at operations[0].command, found null"]),
                ("missing-file", #"{"operations":[{"command":"insert"}]}"#,
                 ["missing key 'file' at operations[0]"]),
                ("not-json", "not json at all", ["data corrupted"]),
            ]

            for c in cases {
                let planPath = try makeTempFile(c.plan, "batch-diag-\(c.name).json")
                defer { cleanup(planPath) }

                let (out, code) = try await runTool(["edit", "batch", planPath])
                #expect(code != 0, "\(c.name): a malformed plan must exit non-zero: \(out)")
                for needle in c.expected {
                    #expect(out.contains(needle), "\(c.name): expected '\(needle)' in: \(out)")
                }
                #expect(!out.contains("'?'"), "\(c.name): the location never falls back to '?': \(out)")
                #expect(!out.contains("Index "), "\(c.name): never Swift's index vocabulary: \(out)")
                #expect(!out.contains("Dictionary<"), "\(c.name): JSON shapes, not Swift metatypes: \(out)")
            }
        }
    }

    /// `replace-range` is the matching-free single call: the caller names the
    /// lines (from `read`) and the content, and the verb never searches text.
    ///
    /// it exists because the measured `no_edit` class spent its whole budget
    /// trying to make `old_text` match, and the workaround it reached for —
    /// `delete` then `insert` — half-applies whenever the second call misses
    /// the turn budget: the destructive partial edit run 019 measured. the
    /// contract below is therefore the one the read→edit loop rides on: the
    /// lines `read` numbers are the lines this verb replaces, and the file is
    /// written once or not at all.
    @Suite("edit replace-range contract")
    struct ReplaceRangeContractTests {
        private let tool = EditContractHarness()

        @Test("replace-range replaces the named lines in one call, trailing newline intact")
        func replacesTheNamedRange() async throws {
            let path = try tool.makeTempFile("let a = 1\nlet b = 2\nlet c = 3\n", "range-hit.swift")
            defer { tool.cleanup(path) }
            let (out, code) = try await tool.run(
                ["edit", "replace-range", path, "--lines", "2-3", "--content", "let fixed = 42"])
            #expect(code == 0, "\(out)")
            #expect(tool.parsedJSON(out)["status"] as? String == "applied", "\(out)")
            #expect(tool.parsedJSON(out)["modified"] as? Bool == true, "\(out)")
            #expect(tool.readFile(path) == "let a = 1\nlet fixed = 42\n", "\(tool.readFile(path))")
        }

        @Test("every content line takes the range's first-line indent")
        func contentInheritsTheRangeIndent() async throws {
            let path = try tool.makeTempFile(
                "struct S {\n\tvar a: Int\n\tvar b: Int\n}\n", "range-indent.swift")
            defer { tool.cleanup(path) }
            // the anchor is line 2, one tab deep: the replacement takes that
            // indentation, and the content's own relative shape is preserved
            // (the `insert` precedent).
            let (out, code) = try await tool.run(
                ["edit", "replace-range", path, "--lines", "2-3", "--content", "func f() {\nprint(1)\n}"])
            #expect(code == 0, "\(out)")
            let expected = "struct S {\n\tfunc f() {\n\tprint(1)\n\t}\n}\n"
            #expect(tool.readFile(path) == expected, "\(tool.readFile(path))")
        }

        @Test("--content expands \\n like every other content-bearing verb")
        func contentEscapesExpand() async throws {
            let path = try tool.makeTempFile("// top\nlet a = 1\n", "range-escape.swift")
            defer { tool.cleanup(path) }
            let (out, code) = try await tool.run(
                ["edit", "replace-range", path, "--lines", "2-2", "--content", #"let a = 1\nlet b = 2"#])
            #expect(code == 0, "\(out)")
            #expect(tool.readFile(path) == "// top\nlet a = 1\nlet b = 2\n", "\(tool.readFile(path))")

            // a caller whose bytes are already exact skips the expansion: the
            // backslash-n must land in the file as the two characters written
            let literal = try tool.makeTempFile("// top\nlet a = 1\n", "range-literal.swift")
            defer { tool.cleanup(literal) }
            let (lOut, lCode) = try await tool.run(
                ["edit", "replace-range", literal, "--lines", "2-2", "--content",
                 #"print("x\ny")"#, "--literal-content"])
            #expect(lCode == 0, "\(lOut)")
            #expect(tool.readFile(literal) == "// top\nprint(\"x\\ny\")\n", "\(tool.readFile(literal))")
        }

        @Test("an end beyond the file clamps to the last line")
        func endBeyondTheFileClamps() async throws {
            let path = try tool.makeTempFile("let a = 1\nlet b = 2\nlet c = 3\n", "range-clamp.swift")
            defer { tool.cleanup(path) }
            let (out, code) = try await tool.run(
                ["edit", "replace-range", path, "--lines", "3-99", "--content", "let z = 9"])
            #expect(code == 0, "\(out)")
            #expect(tool.parsedJSON(out)["status"] as? String == "applied", "\(out)")
            #expect(tool.readFile(path) == "let a = 1\nlet b = 2\nlet z = 9\n", "\(tool.readFile(path))")
        }

        @Test("a range that selects no lines is missed, and the file is untouched")
        func rangePastTheEndMisses() async throws {
            for range in ["100-200", "4-4"] {
                let fixture = "let a = 1\nlet b = 2\nlet c = 3\n"
                let path = try tool.makeTempFile(fixture, "range-miss-\(range).swift")
                defer { tool.cleanup(path) }
                let (out, code) = try await tool.run(
                    ["edit", "replace-range", path, "--lines", range, "--content", "let z = 9"])
                #expect(code != 0, "\(range) must exit non-zero: \(out)")
                #expect(tool.parsedJSON(out)["status"] as? String == "missed", "\(range): \(out)")
                #expect(tool.readFile(path) == fixture, "\(range) must not touch the file")
            }
        }

        @Test("an inverted or non-positive range is a usage error (exit 64)")
        func malformedRangesAreUsageErrors() async throws {
            for range in ["5-2", "0-2", "-1-3", "nonsense"] {
                let fixture = "let a = 1\nlet b = 2\nlet c = 3\n"
                let path = try tool.makeTempFile(fixture, "range-usage.swift")
                defer { tool.cleanup(path) }
                let (out, code) = try await tool.run(
                    ["edit", "replace-range", path, "--lines", range, "--content", "let z = 9"])
                #expect(code == 64, "\(range) must be a usage error, got \(code): \(out)")
                #expect(tool.readFile(path) == fixture, "\(range) must not touch the file")
            }
        }

        @Test("empty content is refused, and the refusal names the verb that removes lines")
        func emptyContentIsRefused() async throws {
            let fixture = "let a = 1\nlet b = 2\n"
            let path = try tool.makeTempFile(fixture, "range-empty.swift")
            defer { tool.cleanup(path) }
            let (out, code) = try await tool.run(
                ["edit", "replace-range", path, "--lines", "1-1", "--content", ""])
            #expect(code == 64, "empty content must be a usage error: \(out)")
            #expect(out.contains("delete"), "the refusal must name `delete`: \(out)")
            #expect(tool.readFile(path) == fixture, "a refused edit must not touch the file")
        }

        @Test("content identical to the selected lines is alreadyCurrent at exit 0")
        func identityContentIsAlreadyCurrent() async throws {
            let fixture = "let a = 1\nlet b = 2\nlet c = 3\n"
            let path = try tool.makeTempFile(fixture, "range-identity.swift")
            defer { tool.cleanup(path) }
            let (out, code) = try await tool.run(
                ["edit", "replace-range", path, "--lines", "2-2", "--content", "let b = 2"])
            #expect(code == 0, "\(out)")
            #expect(tool.parsedJSON(out)["status"] as? String == "alreadyCurrent", "\(out)")
            #expect(tool.readFile(path) == fixture, "an identity edit must not rewrite the file")
        }

        @Test("--dry-run mirrors the real run and writes nothing")
        func dryRunMirrorsTheRealRun() async throws {
            let fixture = "let a = 1\nlet b = 2\n"

            let hit = try tool.makeTempFile(fixture, "range-dry-hit.swift")
            defer { tool.cleanup(hit) }
            let (hitOut, hitCode) = try await tool.run(
                ["edit", "replace-range", hit, "--lines", "1-1", "--content", "let a = 9", "--dry-run"])
            #expect(hitCode == 0, "\(hitOut)")
            #expect(tool.parsedJSON(hitOut)["status"] as? String == "applied", "\(hitOut)")
            #expect(tool.parsedJSON(hitOut)["diff"] is String, "a preview carries its diff: \(hitOut)")
            #expect(tool.readFile(hit) == fixture, "dry-run must not write")

            let miss = try tool.makeTempFile(fixture, "range-dry-miss.swift")
            defer { tool.cleanup(miss) }
            let (missOut, missCode) = try await tool.run(
                ["edit", "replace-range", miss, "--lines", "50-60", "--content", "let z = 1", "--dry-run"])
            #expect(missCode != 0, "\(missOut)")
            #expect(tool.parsedJSON(missOut)["status"] as? String == "missed", "\(missOut)")
            #expect(tool.readFile(miss) == fixture, "dry-run must not write")
        }

        @Test("a result that would not parse is blocked, and --force lands it")
        func unparseableResultIsBlockedUnlessForced() async throws {
            let fixture = "let a = 1\nlet b = 2\n"
            let path = try tool.makeTempFile(fixture, "range-blocked.swift")
            defer { tool.cleanup(path) }

            let (out, code) = try await tool.run(
                ["edit", "replace-range", path, "--lines", "1-1", "--content", "let a = ("])
            #expect(code != 0, "\(out)")
            #expect(tool.parsedJSON(out)["status"] as? String == "blocked", "\(out)")
            #expect(tool.parsedJSON(out)["verified"] as? Bool == false, "\(out)")
            #expect(tool.readFile(path) == fixture, "a blocked write must not touch the file")

            let (forcedOut, forcedCode) = try await tool.run(
                ["edit", "replace-range", path, "--lines", "1-1", "--content", "let a = (", "--force"])
            #expect(forcedCode == 0, "\(forcedOut)")
            #expect(tool.parsedJSON(forcedOut)["status"] as? String == "applied", "\(forcedOut)")
            #expect(tool.readFile(path) != fixture, "a forced write must land")
        }

        @Test("the lines `read` numbers are the lines replace-range replaces")
        func readNumberingMatchesReplaceRange() async throws {
            // the loop this verb exists for: `read` says line N holds the text,
            // the model names N. a trailing newline must not shift the
            // numbering between the two verbs.
            let fixture = "import Foundation\n\nstruct Ledger {\n\tfunc balance() -> Int {\n\t\treturn \"0\"\n\t}\n}\n"
            let path = try tool.makeTempFile(fixture, "range-read-agree.swift")
            defer { tool.cleanup(path) }

            let (readOut, readCode) = try await tool.run(
                ["read", path, "--lines", "5-5", "--output-format", "json"])
            #expect(readCode == 0, "\(readOut)")
            #expect(readOut.contains(#""n":5"#), "read must call it line 5: \(readOut)")

            let (out, code) = try await tool.run(
                ["edit", "replace-range", path, "--lines", "5-5", "--content", "return 0"])
            #expect(code == 0, "\(out)")
            #expect(tool.readFile(path) == fixture.replacingOccurrences(
                of: "\t\treturn \"0\"", with: "\t\treturn 0"), "\(tool.readFile(path))")
        }
    }

    /// `batch` used to take its plan from a file and nothing else — and no tool
    /// on either surface can create a file, so the verb was unreachable by an
    /// agent in practice (every recorded `pkg_edit_batch` call in the bench's
    /// census died on a path that did not exist). `--plan` is that missing
    /// route, and it must mean exactly what a plan file means.
    @Suite("batch plan sources")
    struct BatchPlanSourceTests {
        private let tool = EditContractHarness()

        @Test("an inline plan and a plan file produce the same outcome for the same plan")
        func inlinePlanEqualsPlanFile() async throws {
            let fixture = "let a = 1\nlet b = 2\n"

            let fileTarget = try tool.makeTempFile(fixture, "plan-file.swift")
            defer { tool.cleanup(fileTarget) }
            let planPath = try tool.makeTempFile(
                #"{"operations":[{"command":"replace","file":"\#(fileTarget)","old":"let a = 1","new":"let a = 9"},{"command":"append","file":"\#(fileTarget)","content":"let c = 3"}]}"#,
                "plan.json")
            defer { tool.cleanup(planPath) }
            let (fileOut, fileCode) = try await tool.run(["edit", "batch", planPath, "--output-format", "compact"])
            #expect(fileCode == 0, "\(fileOut)")

            let inlineTarget = try tool.makeTempFile(fixture, "plan-inline.swift")
            defer { tool.cleanup(inlineTarget) }
            let inlineJSON = #"{"operations":[{"command":"replace","file":"\#(inlineTarget)","old":"let a = 1","new":"let a = 9"},{"command":"append","file":"\#(inlineTarget)","content":"let c = 3"}]}"#
            let (inlineOut, inlineCode) = try await tool.run(["edit", "batch", "--plan", inlineJSON, "--output-format", "compact"])
            #expect(inlineCode == 0, "\(inlineOut)")

            // same plan, same meaning: same per-operation statuses, same bytes
            #expect(tool.statuses(fileOut) == ["applied", "applied"], "\(fileOut)")
            #expect(tool.statuses(inlineOut) == tool.statuses(fileOut), "\(inlineOut) vs \(fileOut)")
            #expect(tool.readFile(inlineTarget) == tool.readFile(fileTarget), "\(tool.readFile(inlineTarget))")
            #expect(tool.parsedJSON(inlineOut)["results"] != nil, "\(inlineOut)")
        }

        @Test("neither a plan file nor --plan is a usage error, and so is both")
        func planSourceIsRequiredExactlyOnce() async throws {
            let (noneOut, noneCode) = try await tool.run(["edit", "batch"])
            #expect(noneCode == 64, "no plan at all must be a usage error: \(noneOut)")
            #expect(noneOut.contains("--plan"), "the error must name the missing route: \(noneOut)")

            let path = try tool.makeTempFile("let a = 1\n", "plan-both.swift")
            defer { tool.cleanup(path) }
            let planPath = try tool.makeTempFile(#"{"operations":[]}"#, "plan-both.json")
            defer { tool.cleanup(planPath) }
            let (bothOut, bothCode) = try await tool.run(
                ["edit", "batch", planPath, "--plan", #"{"operations":[]}"#])
            #expect(bothCode == 64, "both routes at once must be a usage error: \(bothOut)")
            #expect(tool.readFile(path) == "let a = 1\n", "nothing may be applied")
        }

        @Test("a malformed inline plan names its JSON location, exactly as a plan file does")
        func malformedInlinePlanNamesItsLocation() async throws {
            let (out, code) = try await tool.run(
                ["edit", "batch", "--plan", #"{"operations":[{"command":"insert","file":"a.swift"},42]}"#])
            #expect(code != 0, "\(out)")
            #expect(out.contains("operations[1]"), "the location must be the JSON the caller wrote: \(out)")
            #expect(!out.contains("'?'"), "never a bare '?': \(out)")
        }
    }

    /// `--atomic` is all-or-nothing: operations stage in memory and the files
    /// are written only if every one applied. the failure it answers is the
    /// measured c2 cascade — a `delete` that landed while its re-insert died at
    /// the turn cap, leaving a destructive partial edit behind.
    @Suite("batch --atomic")
    struct BatchAtomicTests {
        private let tool = EditContractHarness()

        private func writePlan(_ json: String, _ name: String) throws -> String {
            try tool.makeTempFile(json, name)
        }

        @Test("a plan whose second operation misses writes NOTHING — the first op's edit is not landed")
        func failedAtomicPlanWritesNothing() async throws {
            let fixture = "let a = 1\nlet b = 2\n"
            let path = try tool.makeTempFile(fixture, "atomic-miss.swift")
            defer { tool.cleanup(path) }
            let planPath = try writePlan(
                #"{"operations":[{"command":"replace","file":"\#(path)","old":"let a = 1","new":"let a = 9"},{"command":"replace","file":"\#(path)","old":"NOT-THERE","new":"x"}]}"#,
                "atomic-miss.json")
            defer { tool.cleanup(planPath) }

            let (out, code) = try await tool.run(["edit", "batch", planPath, "--atomic", "--output-format", "compact"])
            #expect(code != 0, "an atomic plan with a miss must not exit 0: \(out)")
            #expect(tool.statuses(out) == ["applied", "missed"], "every op still reports: \(out)")
            #expect(tool.readFile(path) == fixture, "NOTHING may be written: \(tool.readFile(path))")

            // the same plan without --atomic keeps the 3.0 behavior: op 1 lands
            let loosePath = try tool.makeTempFile(fixture, "atomic-miss-loose.swift")
            defer { tool.cleanup(loosePath) }
            let loosePlan = try writePlan(
                #"{"operations":[{"command":"replace","file":"\#(loosePath)","old":"let a = 1","new":"let a = 9"},{"command":"replace","file":"\#(loosePath)","old":"NOT-THERE","new":"x"}]}"#,
                "atomic-miss-loose.json")
            defer { tool.cleanup(loosePlan) }
            let (_, looseCode) = try await tool.run(["edit", "batch", loosePlan, "--output-format", "compact"])
            #expect(looseCode != 0, "a plain batch with a miss still exits non-zero")
            #expect(tool.readFile(loosePath) == "let a = 9\nlet b = 2\n",
                    "the default stays sequential continue-on-failure: \(tool.readFile(loosePath))")
        }

        @Test("an all-hit atomic plan applies, and operation 2 sees operation 1's staged result")
        func allHitAtomicPlanAppliesAndChains() async throws {
            let path = try tool.makeTempFile("let a = 1\nlet b = 2\n", "atomic-hit.swift")
            defer { tool.cleanup(path) }
            // op 2's selector exists ONLY after op 1's change: chaining is the
            // only way this plan can succeed.
            let planPath = try writePlan(
                #"{"operations":[{"command":"replace","file":"\#(path)","old":"let a = 1","new":"let a = 9"},{"command":"replace","file":"\#(path)","old":"let a = 9","new":"let a = 10"}]}"#,
                "atomic-chain.json")
            defer { tool.cleanup(planPath) }

            let (out, code) = try await tool.run(["edit", "batch", planPath, "--atomic", "--output-format", "compact"])
            #expect(code == 0, "\(out)")
            #expect(tool.statuses(out) == ["applied", "applied"], "\(out)")
            #expect(tool.readFile(path) == "let a = 10\nlet b = 2\n", "\(tool.readFile(path))")
        }

        @Test("a multi-file atomic plan with one failing op changes NO file")
        func multiFileAtomicPlanIsAllOrNothing() async throws {
            let first = "let a = 1\n"
            let second = "let b = 2\n"
            let firstPath = try tool.makeTempFile(first, "atomic-multi-a.swift")
            defer { tool.cleanup(firstPath) }
            let secondPath = try tool.makeTempFile(second, "atomic-multi-b.swift")
            defer { tool.cleanup(secondPath) }
            let planPath = try writePlan(
                #"{"operations":[{"command":"replace","file":"\#(firstPath)","old":"let a = 1","new":"let a = 9"},{"command":"replace","file":"\#(secondPath)","old":"NOT-THERE","new":"x"}]}"#,
                "atomic-multi.json")
            defer { tool.cleanup(planPath) }

            let (out, code) = try await tool.run(["edit", "batch", planPath, "--atomic", "--output-format", "compact"])
            #expect(code != 0, "\(out)")
            #expect(tool.statuses(out) == ["applied", "missed"], "\(out)")
            #expect(tool.readFile(firstPath) == first, "the applied op's file must not change: \(tool.readFile(firstPath))")
            #expect(tool.readFile(secondPath) == second, "\(tool.readFile(secondPath))")
        }

        @Test("--atomic --dry-run previews every operation and writes nothing")
        func atomicDryRunWritesNothing() async throws {
            let fixture = "let a = 1\nlet b = 2\n"
            let path = try tool.makeTempFile(fixture, "atomic-dry.swift")
            defer { tool.cleanup(path) }
            let planPath = try writePlan(
                #"{"operations":[{"command":"replace","file":"\#(path)","old":"let a = 1","new":"let a = 9"},{"command":"append","file":"\#(path)","content":"let c = 3"}]}"#,
                "atomic-dry.json")
            defer { tool.cleanup(planPath) }

            let (out, code) = try await tool.run(
                ["edit", "batch", planPath, "--atomic", "--dry-run", "--output-format", "compact"])
            #expect(code == 0, "\(out)")
            #expect(tool.statuses(out) == ["applied", "applied"], "every op is previewed: \(out)")
            #expect(tool.parsedJSON(out)["results"] != nil, "\(out)")
            #expect(tool.readFile(path) == fixture, "a preview writes nothing: \(tool.readFile(path))")
        }

        @Test("--atomic --fail-fast stops at the first failure and writes nothing")
        func atomicFailFastStopsAndWritesNothing() async throws {
            let fixture = "let a = 1\nlet b = 2\n"
            let path = try tool.makeTempFile(fixture, "atomic-ff.swift")
            defer { tool.cleanup(path) }
            // op 1 misses; op 2 would have hit. fail-fast must not evaluate it,
            // and atomic must not write anything either way.
            let planPath = try writePlan(
                #"{"operations":[{"command":"replace","file":"\#(path)","old":"NOT-THERE","new":"x"},{"command":"replace","file":"\#(path)","old":"let a = 1","new":"let a = 9"}]}"#,
                "atomic-ff.json")
            defer { tool.cleanup(planPath) }

            let (out, code) = try await tool.run(
                ["edit", "batch", planPath, "--atomic", "--fail-fast", "--output-format", "compact"])
            #expect(code != 0, "\(out)")
            #expect(tool.statuses(out) == ["missed"], "--fail-fast must stop at the miss: \(out)")
            #expect(tool.readFile(path) == fixture, "nothing may be written: \(tool.readFile(path))")
        }
    }
}

// MARK: - shared harness

/// the black-box harness the contract suites share: run the built binary
/// against a throwaway fixture file, then read back what it did.
///
/// the exit-code suite above keeps its own private copies on purpose — it is
/// the release's tripwire for the paths that already shipped, and it does not
/// move when new suites arrive.
private struct EditContractHarness {
    let binaryPath: String

    init() {
        let pkgDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/NormalizerCoreTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // swift-package-utilitykit/
        binaryPath = pkgDir
            .appendingPathComponent(".build/debug/swift-package-tool").path
    }

    func run(_ args: [String]) async throws -> (output: String, exitCode: Int32) {
        let outcome = try await Subprocess.capture(binaryPath, args)
        return (outcome.stdout + outcome.stderr, outcome.exitCode)
    }

    func makeTempFile(_ content: String, _ name: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("editcontract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(name).path
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    func parsedJSON(_ output: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: output.data(using: .utf8) ?? Data()))
            as? [String: Any] ?? [:]
    }

    /// the per-operation statuses of a BatchResult payload, in plan order.
    func statuses(_ output: String) -> [String] {
        (parsedJSON(output)["results"] as? [[String: Any]] ?? []).compactMap { $0["status"] as? String }
    }

    func readFile(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }
}
