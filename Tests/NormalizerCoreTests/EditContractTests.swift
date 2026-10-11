import Testing
import Foundation
import SubprocessCore

/// the exit-code contract for edit commands, pinned black-box against the
/// built binary: a selector miss or a blocked write prints its EditResult and
/// exits non-zero; an applied edit or an already-satisfied state exits 0.
///
/// this suite exists because 2.0.1 exited 0 for every one of these paths
/// while the payload said `modified:false` — the failure was visible only to
/// a consumer parsing stdout (bugfix202).
@Suite("edit exit-code contract", .serialized)
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
            ("replace-text", ["replace", "{f}", "--old", "NOT-THERE", "--new", "x"]),
            ("replace-symbol", ["replace", "{f}", "--symbol", "Nope", "--rename", "X"]),
            ("insert-after", ["insert", "{f}", "--content", "let c = 3", "--after", "NOPE"]),
            ("insert-before", ["insert", "{f}", "--content", "let c = 3", "--before", "NOPE"]),
            ("delete-matching", ["delete", "{f}", "--matching", "NOPE"]),
            ("delete-lines", ["delete", "{f}", "--lines", "100-200"]),
            ("delete-symbol", ["delete", "{f}", "--symbol", "Nope"]),
            ("wrap-lines", ["wrap", "{f}", "--lines", "100-200", "--in", "do"]),
            ("add-member", ["add-member", "{f}", "--type", "Nope", "--property", "var x: Int"]),
            ("add-conformance", ["add-conformance", "{f}", "--type", "Nope", "--protocol", "Sendable"]),
            ("sort", ["sort", "{f}", "--type", "Nope"]),
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
                ["replace", path, "--old", "NOT-THERE", "--new", "x", "--output-format", fmt]
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
            ("replace-text", ["replace", "{f}", "--old", "let a = 1", "--new", "let a = 9"]),
            ("replace-symbol", ["replace", "{f}", "--symbol", "a", "--rename", "z"]),
            ("insert-at-line", ["insert", "{f}", "--content", "let c = 3", "--at-line", "1"]),
            ("delete-lines", ["delete", "{f}", "--lines", "1-1"]),
            ("delete-symbol", ["delete", "{f}", "--symbol", "S"]),
            ("wrap-lines", ["wrap", "{f}", "--lines", "1-1", "--in", "do"]),
            ("add-import", ["add-import", "{f}", "--module", "Foundation"]),
            ("add-member", ["add-member", "{f}", "--type", "S", "--property", "var z: Int"]),
            ("add-conformance", ["add-conformance", "{f}", "--type", "S", "--protocol", "Sendable"]),
            ("sort", ["sort", "{f}", "--type", "S"]),
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
        let (out, code) = try await runTool(["replace", path, "--old", "}", "--new", ""])
        #expect(code != 0, "a blocked write must not exit 0: \(out)")
        let json = parsedJSON(out)
        #expect(json["status"] as? String == "blocked", "\(out)")
        #expect(json["verified"] as? Bool == false, "\(out)")
        #expect(readFile(path) == fixture, "blocked write must not touch the file")

        // --force applies the same edit and exits 0
        let (forcedOut, forcedCode) = try await runTool(["replace", path, "--old", "}", "--new", "", "--force"])
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
        let (missOut, missCode) = try await runTool(["replace", missPath, "--old", "NOPE", "--new", "x", "--dry-run"])
        #expect(missCode != 0, "a dry-run miss must not exit 0: \(missOut)")
        #expect(parsedJSON(missOut)["status"] as? String == "missed", "\(missOut)")
        #expect(readFile(missPath) == fixture, "dry-run must not write")

        let hitPath = try makeTempFile(fixture, "dry-hit.swift")
        defer { cleanup(hitPath) }
        let (hitOut, hitCode) = try await runTool(["replace", hitPath, "--old", "let a = 1", "--new", "let a = 2", "--dry-run"])
        #expect(hitCode == 0, "a dry-run hit must exit 0: \(hitOut)")
        #expect(parsedJSON(hitOut)["status"] as? String == "applied", "\(hitOut)")
        #expect(readFile(hitPath) == fixture, "dry-run must not write")

        let blockedPath = try makeTempFile("struct S {\n  var value: Int\n}\n", "dry-blocked.swift")
        defer { cleanup(blockedPath) }
        let (blockedOut, blockedCode) = try await runTool(["replace", blockedPath, "--old", "}", "--new", "", "--dry-run"])
        #expect(blockedCode != 0, "a dry-run of a blocked edit must not exit 0: \(blockedOut)")
        #expect(parsedJSON(blockedOut)["status"] as? String == "blocked", "\(blockedOut)")
    }

    // MARK: - already-satisfied no-ops stay exit 0

    @Test("already-satisfied edits exit 0 with status alreadyCurrent")
    func alreadySatisfiedStaysZero() async throws {
        // add-import twice: the second run is a skip, not a failure
        let importPath = try makeTempFile("let q = 0\n", "dup-import.swift")
        defer { cleanup(importPath) }
        let (_, firstCode) = try await runTool(["add-import", importPath, "--module", "Foundation"])
        #expect(firstCode == 0, "first add-import must apply")
        let (dupOut, dupCode) = try await runTool(["add-import", importPath, "--module", "Foundation"])
        #expect(dupCode == 0, "an already-imported module must stay exit 0: \(dupOut)")
        #expect(parsedJSON(dupOut)["status"] as? String == "alreadyCurrent", "\(dupOut)")

        // add-conformance on an already-conforming type
        let confPath = try makeTempFile("struct U: Sendable {\n}\n", "dup-conformance.swift")
        defer { cleanup(confPath) }
        let (confOut, confCode) = try await runTool(["add-conformance", confPath, "--type", "U", "--protocol", "Sendable"])
        #expect(confCode == 0, "an already-conforming type must stay exit 0: \(confOut)")
        #expect(parsedJSON(confOut)["status"] as? String == "alreadyCurrent", "\(confOut)")

        // sort: one member is nothing to sort; an already-sorted type is a no-op
        let onePath = try makeTempFile("struct S {\n    var value: Int\n}\n", "sort-one.swift")
        defer { cleanup(onePath) }
        let (oneOut, oneCode) = try await runTool(["sort", onePath, "--type", "S"])
        #expect(oneCode == 0, "nothing-to-sort must stay exit 0: \(oneOut)")
        #expect(parsedJSON(oneOut)["status"] as? String == "alreadyCurrent", "\(oneOut)")

        let sortedFixture = "struct S {\n    var a: Int\n    var b: Int\n}\n"
        let sortedPath = try makeTempFile(sortedFixture, "sort-sorted.swift")
        defer { cleanup(sortedPath) }
        let (sortedOut, sortedCode) = try await runTool(["sort", sortedPath, "--type", "S"])
        #expect(sortedCode == 0, "an already-sorted type must stay exit 0: \(sortedOut)")
        let sortedJSON = parsedJSON(sortedOut)
        #expect(sortedJSON["status"] as? String == "alreadyCurrent", "\(sortedOut)")
        #expect(sortedJSON["modified"] as? Bool == false, "byte-identical sort must not claim modified: \(sortedOut)")
        #expect(readFile(sortedPath) == sortedFixture, "the file must be untouched")

        // replace with identical text satisfies the request trivially
        let identityPath = try makeTempFile("let x = 1\n", "identity.swift")
        defer { cleanup(identityPath) }
        let (idOut, idCode) = try await runTool(["replace", identityPath, "--old", "let x = 1", "--new", "let x = 1"])
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
        let (out, code) = try await runTool(["batch", planPath])
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
        let (ffOut, ffCode) = try await runTool(["batch", ffPlanPath, "--fail-fast"])
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
        let (okOut, okCode) = try await runTool(["batch", okPlanPath])
        #expect(okCode == 0, "an all-hit batch must exit 0: \(okOut)")
    }

    // MARK: - schema

    @Test("the EditResult schema carries status")
    func schemaCarriesStatus() async throws {
        let path = try makeTempFile("let a = 1\n", "schema.swift")
        defer { cleanup(path) }
        let (out, code) = try await runTool(["replace", path, "--schema"])
        #expect(code == 0, "\(out)")
        #expect(out.contains("\"status\""), "the schema must document status: \(out)")
        #expect(out.contains("\"missed\"") && out.contains("\"blocked\""), "\(out)")
    }
}