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

/// Ports of the package-inspector's Python assertions
/// (`hermes-plugin/test_tools.py`) onto the shimless CLI: the same fixtures and
/// the same behaviors, with no interpreter in the path.
///
/// Serialized: each case spawns the tool (and some spawn `swift package` /
/// `swift build` behind it), and the house rule for subprocess-heavy suites is
/// to keep them out of each other's way.

// MARK: - fixture helpers

/// create a throwaway directory under the test temp dir.
func makeInspectorFixture(_ prefix: String) throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.path
}

/// write a file, creating intermediate directories.
func writeFixture(_ text: String, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func manifestFixture(_ name: String, targets: String) -> String {
    """
    // swift-tools-version: 5.9
    import PackageDescription
    let package = Package(
        name: "\(name)",
        products: [.library(name: "\(name)", targets: ["\(name)"])],
        targets: [
    \(targets)
        ]
    )
    """
}

/// run the tool with a bounded timeout: a nested SwiftPM run that hangs must
/// fail the test, never the suite.
private func fixtureTool(_ args: String..., timeout: Duration = .seconds(180)) async throws -> [String: Any] {
    let outcome = try await Subprocess.capture(absoluteToolPath(), args, timeout: timeout)
    guard let json = try JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8)) as? [String: Any] else {
        throw TestError("Failed to parse JSON output: \(outcome.stdout.prefix(400)) (stderr: \(outcome.stderr.prefix(300)))")
    }
    return json
}

/// the same, for a tool whose payload is a JSON array (`pkg_api`).
private func fixtureToolArray(_ args: [String], timeout: Duration = .seconds(180)) async throws -> [[String: Any]] {
    let outcome = try await Subprocess.capture(absoluteToolPath(), args, timeout: timeout)
    guard let json = try JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8)) as? [[String: Any]] else {
        throw TestError("Failed to parse JSON array: \(outcome.stdout.prefix(400)) (stderr: \(outcome.stderr.prefix(300)))")
    }
    return json
}

/// invoke one tool through the plugin envelope (the harness contract).
private func pluginTool(_ tool: String, _ args: [String: Any]) async throws -> String {
    let envelope: [String: Any] = ["tool": tool, "args": args]
    let payload = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
    let outcome = try await Subprocess.capture(
        absoluteToolPath(), ["plugin"], stdin: payload + "\n", timeout: .seconds(240))
    guard let json = try JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8)) as? [String: Any],
          let result = json["result"] as? String else {
        throw TestError("\(tool): no result envelope (stdout: \(outcome.stdout.prefix(300)), stderr: \(outcome.stderr.prefix(300)))")
    }
    return result
}

// MARK: - targets

@Suite("Inspector port: targets", .serialized)
struct InspectorTargetsPortTests {

    @Test("targets applies SwiftPM default-path rules and flags explicit paths")
    func targetsDefaultPath() async throws {
        let root = try makeInspectorFixture("uk-targets")
        defer { try? FileManager.default.removeItem(atPath: root) }

        try writeFixture("""
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(
            name: "MultiTarget",
            products: [.library(name: "Core", targets: ["Core"])],
            targets: [
                .target(name: "Core"),
                .target(name: "HasPath", path: "Custom/Dir"),
                .testTarget(name: "CoreTests", dependencies: ["Core"]),
                .executableTarget(name: "CLI"),
            ]
        )
        """, to: root + "/Package.swift")
        try writeFixture("public struct Core {}\n", to: root + "/Sources/Core/Core.swift")
        try writeFixture("import XCTest\n", to: root + "/Tests/CoreTests/T.swift")
        try writeFixture("public struct P {}\n", to: root + "/Custom/Dir/P.swift")
        try writeFixture("print(\"hi\")\n", to: root + "/Sources/CLI/main.swift")

        let report = try await fixtureTool("targets", root)
        #expect(report["ok"] as? Bool == true)
        #expect(report["count"] as? Int == 4)

        let targets = report["targets"] as? [[String: Any]] ?? []
        var byName: [String: [String: Any]] = [:]
        for target in targets { byName[target["name"] as? String ?? ""] = target }

        let core = try #require(byName["Core"])
        #expect(core["path_kind"] as? String == "default")
        #expect(core["type"] as? String == "library")
        #expect(core["exists"] as? Bool == true)
        #expect(core["swift_file_count"] as? Int == 1)
        #expect((core["path"] as? String)?.hasSuffix("Sources/Core") == true)

        let hasPath = try #require(byName["HasPath"])
        #expect(hasPath["path_kind"] as? String == "explicit")
        #expect((hasPath["path"] as? String)?.hasSuffix("Custom/Dir") == true)
        #expect(hasPath["swift_file_count"] as? Int == 1)

        let coreTests = try #require(byName["CoreTests"])
        #expect(coreTests["type"] as? String == "test")
        #expect(coreTests["path_kind"] as? String == "default")
        #expect((coreTests["path"] as? String)?.hasSuffix("Tests/CoreTests") == true)

        let cli = try #require(byName["CLI"])
        #expect(cli["type"] as? String == "executable")
        #expect(cli["exists"] as? Bool == true)
        #expect(cli["swift_file_count"] as? Int == 1)
    }

    @Test("targets reports a per-file symbol heatmap and a largest-files ranking")
    func targetsHeatmap() async throws {
        let root = try makeInspectorFixture("uk-heatmap")
        defer { try? FileManager.default.removeItem(atPath: root) }

        try writeFixture("""
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(
            name: "Heat",
            products: [.library(name: "Heat", targets: ["Heat"])],
            targets: [.target(name: "Heat")]
        )
        """, to: root + "/Package.swift")
        try writeFixture("""
        public struct Alpha {
            public func one() {}
            public func two() {}
        }
        public enum Beta { case a }
        """, to: root + "/Sources/Heat/Alpha.swift")
        try writeFixture("public struct Gamma {}\n", to: root + "/Sources/Heat/Gamma.swift")

        let report = try await fixtureTool("targets", root)
        let targets = report["targets"] as? [[String: Any]] ?? []
        let heat = try #require(targets.first)

        #expect(heat["total_symbols"] as? Int == 5, "2 structs + 2 funcs + 1 enum")
        #expect((heat["total_lines"] as? Int ?? 0) > 0)

        let stats = heat["file_stats"] as? [[String: Any]] ?? []
        #expect(stats.count == 2)
        let alpha = try #require(stats.first { ($0["path"] as? String)?.hasSuffix("Alpha.swift") == true })
        let symbols = alpha["symbols"] as? [String: Int] ?? [:]
        #expect(symbols["function"] == 2)
        #expect(symbols["struct"] == 1)
        #expect(symbols["enum"] == 1)

        let largest = heat["largest_files"] as? [[String: Any]] ?? []
        #expect(largest.first?["path"] as? String == "Sources/Heat/Alpha.swift", "longest file ranks first")
    }
}

// MARK: - dependencies

@Suite("Inspector port: dependencies", .serialized)
struct InspectorDependenciesPortTests {

    @Test("package-dependencies lists local path deps with requirement kinds")
    func localPathDependencies() async throws {
        let root = try makeInspectorFixture("uk-deps")
        defer { try? FileManager.default.removeItem(atPath: root) }

        for name in ["LibA", "LibB"] {
            try writeFixture("""
            // swift-tools-version: 5.9
            import PackageDescription
            let package = Package(name: "\(name)",
                products: [.library(name: "\(name)", targets: ["\(name)"])],
                targets: [.target(name: "\(name)")])
            """, to: "\(root)/\(name)/Package.swift")
            try writeFixture("public struct \(name) {}\n", to: "\(root)/\(name)/Sources/\(name)/\(name).swift")
        }
        try writeFixture("""
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(
            name: "D",
            dependencies: [
                .package(name: "libA", path: "\(root)/LibA"),
                .package(name: "libB", path: "\(root)/LibB"),
            ],
            targets: [
                .target(name: "D", dependencies: [
                    .product(name: "LibA", package: "libA"),
                    .product(name: "LibB", package: "libB"),
                ])
            ]
        )
        """, to: root + "/Package.swift")
        try writeFixture("import LibA\nimport LibB\npublic func f() {}\n", to: root + "/Sources/D/D.swift")

        let report = try await fixtureTool("package-dependencies", root)
        #expect(report["ok"] as? Bool == true, "\(report["error"] ?? "")")
        #expect(report["count"] as? Int == 2)

        let deps = report["dependencies"] as? [[String: Any]] ?? []
        let names = Set(deps.compactMap { $0["name"] as? String })
        #expect(names == ["liba", "libb"], "identity-form names, got \(names)")
        for dep in deps {
            let kind = dep["requirement_kind"] as? String
            #expect(["unknown", "from", "exact"].contains(kind ?? ""), "requirement kind present: \(dep)")
        }
    }
}

// MARK: - scan severity + classification

@Suite("Inspector port: scan", .serialized)
struct InspectorScanPortTests {

    @Test("force unwraps are classified by subkind and `!=` is ignored")
    func forceUnwrapClassification() async throws {
        let root = try makeInspectorFixture("uk-force")
        defer { try? FileManager.default.removeItem(atPath: root) }

        try writeFixture(manifestFixture("F", targets: "        .target(name: \"F\")"), to: root + "/Package.swift")
        try writeFixture("""
        public struct F {
            public func a() { let x = optional! }
            public func b() { try! risky() }
            public func c() { let y = value as! Int }
            public func d() { let z = a != b }
        }
        """, to: root + "/Sources/F/F.swift")

        let report = try await fixtureTool("scan", root, "--categories", "force_unwraps", "--output-format", "json")
        let byCategory = report["by_category"] as? [String: Any] ?? [:]
        let forceCategory = byCategory["force_unwraps"] as? [String: Any] ?? [:]
        #expect(forceCategory["count"] as? Int == 3, "plain + try! + as!, `!=` ignored")

        let findings = forceCategory["findings"] as? [[String: Any]] ?? []
        let primaries = findings.compactMap { $0["primary"] as? String }
        #expect(primaries.contains("force_unwrap"))
        #expect(primaries.contains("try_force"))
        #expect(primaries.contains("as_cast"))

        let tryForce = try #require(findings.first { $0["primary"] as? String == "try_force" })
        let subkinds = tryForce["subkinds"] as? [String: Int] ?? [:]
        #expect(subkinds["try_force"] == 1)
    }

    @Test("severity reflects reachability: input stays high, cleanup caps low")
    func reachabilitySeverity() async throws {
        let root = try makeInspectorFixture("uk-reach")
        defer { try? FileManager.default.removeItem(atPath: root) }

        try writeFixture(manifestFixture("R", targets: "        .target(name: \"R\")"), to: root + "/Package.swift")
        try writeFixture("""
        public struct R {
            public func parseInput(_ d: String) {
                let s = try! value(d)
            }
            public func closeChannel() {
                let h = handle!
            }
        }
        """, to: root + "/Sources/R/R.swift")

        let report = try await fixtureTool("scan", root, "--categories", "force_unwraps", "--output-format", "json")
        let findings = (report["by_category"] as? [String: Any])
            .flatMap { $0["force_unwraps"] as? [String: Any] }
            .flatMap { $0["findings"] as? [[String: Any]] } ?? []

        var byLine: [Int: [String: Any]] = [:]
        for finding in findings { byLine[finding["line"] as? Int ?? 0] = finding }

        let inputLine = try #require(byLine[3], "try! inside parseInput")
        #expect(inputLine["severity"] as? String == "high")
        #expect(inputLine["reachability"] as? String == "input")

        let cleanupLine = try #require(byLine[6], "plain ! inside closeChannel")
        #expect(cleanupLine["severity"] as? String == "low")
        #expect(cleanupLine["reachability"] as? String == "cleanup")

        for finding in findings {
            let severity = finding["severity"] as? String
            #expect(["high", "medium", "low"].contains(severity ?? ""), "stable severity key: \(finding)")
        }
    }

    @Test("a try! in a test file is capped below high")
    func testContextSeverityCap() async throws {
        let root = try makeInspectorFixture("uk-testsev")
        defer { try? FileManager.default.removeItem(atPath: root) }

        try writeFixture(manifestFixture("T", targets: "        .target(name: \"T\")"), to: root + "/Package.swift")
        try writeFixture("""
        import XCTest
        final class TTests: XCTestCase {
            func testSomething() { try! risky()
        }
        """, to: root + "/Tests/TTests/TTests.swift")

        let report = try await fixtureTool("scan", root, "--categories", "force_unwraps", "--output-format", "json")
        let findings = (report["by_category"] as? [String: Any])
            .flatMap { $0["force_unwraps"] as? [String: Any] }
            .flatMap { $0["findings"] as? [[String: Any]] } ?? []
        #expect(findings.count == 1, "finds the test try!")
        let finding = try #require(findings.first)
        #expect(finding["severity"] as? String == "medium", "test context caps a high-consequence operator")
        #expect(finding["context"] as? String == "test")
    }

    @Test("process-safety hits carry the api and a reachability-ranked severity")
    func processSafety() async throws {
        let root = try makeInspectorFixture("uk-proc")
        defer { try? FileManager.default.removeItem(atPath: root) }

        try writeFixture(manifestFixture("P", targets: "        .target(name: \"P\")"), to: root + "/Package.swift")
        try writeFixture("""
        public struct P {
            public func runChild() {
                let pid = fork()
            }
        }
        """, to: root + "/Sources/P/P.swift")

        let report = try await fixtureTool("scan", root, "--categories", "process_safety", "--output-format", "json")
        let findings = (report["by_category"] as? [String: Any])
            .flatMap { $0["process_safety"] as? [String: Any] }
            .flatMap { $0["findings"] as? [[String: Any]] } ?? []
        #expect(findings.count >= 1)
        let finding = try #require(findings.first)
        #expect(finding["api"] as? String == "raw_fork_without_exec")
        #expect(finding["severity"] as? String == "medium", "internal reach caps a high-consequence api")
        #expect(finding["reachability"] as? String == "internal")
    }

    @Test("secrets are reported once per line with a severity hint")
    func secrets() async throws {
        let root = try makeInspectorFixture("uk-secret")
        defer { try? FileManager.default.removeItem(atPath: root) }

        try writeFixture(manifestFixture("S", targets: "        .target(name: \"S\")"), to: root + "/Package.swift")
        try writeFixture("""
        let key = "AKIAIOSFODNN7EXAMPLE"
        let password = "hunter2secret"
        """, to: root + "/Sources/S/S.swift")

        let report = try await fixtureTool("scan", root, "--categories", "secrets", "--output-format", "json")
        let findings = (report["by_category"] as? [String: Any])
            .flatMap { $0["secrets"] as? [String: Any] }
            .flatMap { $0["findings"] as? [[String: Any]] } ?? []
        #expect(findings.count == 2, "one finding per line, got \(findings)")
        let kinds = Set(findings.compactMap { $0["kind"] as? String })
        #expect(kinds == ["aws_access_key", "generic_password"], "got \(kinds)")
        for finding in findings {
            #expect(["critical", "high"].contains(finding["severity_hint"] as? String ?? ""))
        }
    }
}

// MARK: - doc coverage

@Suite("Inspector port: doc coverage", .serialized)
struct InspectorDocCoveragePortTests {

    @Test("doc-coverage counts declarations and lists the uncovered ones")
    func coverageAndUncovered() async throws {
        let root = try makeInspectorFixture("uk-docc")
        defer { try? FileManager.default.removeItem(atPath: root) }

        try writeFixture(manifestFixture("Docc", targets: "        .target(name: \"Docc\")"), to: root + "/Package.swift")
        try writeFixture("""
        /// Documented struct.
        public struct Good {}
        public struct Bad {}
        public func alsoBad() {}
        """, to: root + "/Sources/Docc/Docc.swift")

        let report = try await fixtureTool("doc-coverage", root, "--output-format", "json")
        #expect(report["ok"] as? Bool == true)
        let coverage = try #require(report["coverage"] as? [String: Any])
        #expect(coverage["declarations"] as? Int == 3)
        #expect(coverage["documented"] as? Int == 1)
        #expect(coverage["undocumented"] as? Int == 2)
        let ratio = try #require(coverage["coverage"] as? Double)
        #expect(abs(ratio - 1.0 / 3.0) < 0.001)

        let symbols = coverage["uncovered_symbols"] as? [[String: Any]] ?? []
        #expect(symbols.count == 2)
        let names = Set(symbols.compactMap { $0["name"] as? String })
        #expect(names == ["Bad", "alsoBad"], "got \(names)")
        for symbol in symbols {
            #expect(["struct", "function", "func"].contains(symbol["kind"] as? String ?? ""))
            #expect((symbol["line"] as? Int ?? 0) > 0)
            #expect((symbol["file"] as? String)?.hasSuffix("Docc.swift") == true)
        }

        // the limit bounds the list but never the count
        let limited = try await fixtureTool("doc-coverage", root, "--limit", "1", "--output-format", "json")
        let limitedCoverage = try #require(limited["coverage"] as? [String: Any])
        #expect((limitedCoverage["uncovered_symbols"] as? [[String: Any]])?.count == 1)
        #expect(limitedCoverage["undocumented"] as? Int == 2)
        #expect(limitedCoverage["uncovered_symbol_count"] as? Int == 2)
    }
}

// MARK: - inspector

@Suite("Inspector port: orientation", .serialized)
struct InspectorOrientationPortTests {

    @Test("inspector returns the orientation payload and a one-line summary")
    func inspectorPayload() async throws {
        let root = try makeInspectorFixture("uk-inspector")
        defer { try? FileManager.default.removeItem(atPath: root) }

        try writeFixture("""
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(
            name: "FixturePkg",
            products: [.library(name: "Fixture", targets: ["Fixture"])],
            targets: [
                .target(name: "Fixture"),
                .testTarget(name: "FixtureTests", dependencies: ["Fixture"]),
            ]
        )
        """, to: root + "/Package.swift")
        try writeFixture("""
        /// A fixture value.
        public struct Fixture {
            public let value: Int
            public let v: Int
            public init(_ v: Int) { value = v; self.v = v }
            /// Adds two values.
            public func add(_ other: Int) -> Int { value + other }
            public func risky() -> Int { maybe! }
        }
        """, to: root + "/Sources/Fixture/Fixture.swift")
        try writeFixture("""
        import XCTest
        @testable import Fixture
        final class FixtureTests: XCTestCase {
            func testAdd() { XCTAssertEqual(Fixture(2).add(3), 5) }
        }
        """, to: root + "/Tests/FixtureTests/FixtureTests.swift")
        try writeFixture("# FixturePkg\n\nA fixture package for the orientation payload.\n",
                         to: root + "/README.md")

        // --skip-build/--skip-test keep the shape assertions fast; the verdict
        // path itself is covered by the isolated-build suite below.
        let report = try await fixtureTool("inspector", root, "--skip-build", "--skip-test", "--output-format", "json")
        #expect(report["ok"] as? Bool == true)
        // the orientation name is the package DIRECTORY name (python parity),
        // not the manifest's declared package name
        #expect(report["name"] as? String == URL(fileURLWithPath: root).lastPathComponent)
        #expect((report["readme_intent"] as? String)?.contains("fixture package") == true)

        let git = try #require(report["git"] as? [String: Any])
        #expect(git["dirty"] as? Bool == false, "a non-repo fixture must read clean/not-a-repo, never crash")

        let targets = report["targets"] as? [[String: Any]] ?? []
        #expect(targets.count == 2)
        #expect(report["largest_files"] is [[String: Any]])

        let audit = try #require(report["audit"] as? [String: Any])
        #expect(audit["findings"] as? Int == 1, "the fixture's one force unwrap")
        let topFiles = try #require(audit["top_files"] as? [[Any]])
        #expect(topFiles.first?.count == 2, "top_files entries are [file, {category: n}] pairs")
        #expect((topFiles.first?.first as? String)?.hasSuffix("Fixture.swift") == true)

        let docs = try #require(report["docs"] as? [String: Any])
        #expect(docs["coverage_pct"] is Int)

        let build = try #require(report["build"] as? [String: Any])
        #expect(build["succeeded"] is NSNull, "skipped build reported as null, not omitted")
        let test = try #require(report["test"] as? [String: Any])
        #expect(test["succeeded"] is NSNull)

        let summary = try #require(report["summary"] as? String)
        #expect(summary.contains("2 target(s)"))
        #expect(summary.contains("does not build"), "a skipped build reads as not-built in the summary")
        #expect(summary.contains("doc coverage"))

        // compact payload: the orientation counts + verdicts only
        let compact = try await fixtureTool("inspector", root, "--skip-build", "--skip-test", "--compact", "--output-format", "json")
        #expect(compact["target_count"] as? Int == 2)
        #expect(compact["dep_count"] as? Int == 0)
        #expect(compact["finding_count"] is Int)
        #expect(compact["doc_coverage_pct"] is Int)
        #expect(compact["build_succeeded"] is NSNull)
    }
}

// MARK: - the audit scratch contract, end to end

@Suite("Inspector port: build/test/clean", .serialized)
struct InspectorBuildCleanPortTests {

    @Test("isolated build/test leave the real .build alone and clean --audit is non-destructive")
    func buildTestCleanIsolation() async throws {
        let root = try makeInspectorFixture("uk-audit")
        defer { try? FileManager.default.removeItem(atPath: root) }

        try writeFixture("""
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(
            name: "Audit",
            products: [.library(name: "Audit", targets: ["Audit"])],
            targets: [
                .target(name: "Audit"),
                .testTarget(name: "AuditTests", dependencies: ["Audit"]),
            ]
        )
        """, to: root + "/Package.swift")
        try writeFixture("public func answer() -> Int { 42 }\n", to: root + "/Sources/Audit/Audit.swift")
        try writeFixture("""
        import XCTest
        @testable import Audit
        final class AuditTests: XCTestCase {
            func testAnswer() { XCTAssertEqual(answer(), 42) }
        }
        """, to: root + "/Tests/AuditTests/AuditTests.swift")

        // a real build creates the package's own .build products
        let realBuild = try await Subprocess.capture(
            "/usr/bin/env", ["swift", "build"], workingDirectory: root, timeout: .seconds(600)
        )
        #expect(realBuild.exitCode == 0, "fixture must build: \(realBuild.stderr.prefix(300))")

        let fingerprint: () -> String = {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/find")
            proc.arguments = [root + "/.build", "-type", "f", "-exec", "stat", "-f", "%m %z %N", "{}", "+"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            try? proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").sorted().joined(separator: "\n")
        }
        let before = fingerprint()
        #expect(!before.isEmpty, "real .build must have products to protect")

        // isolated build + test (the subcommand reports one result object per phase)
        let buildRun = try await fixtureToolArray(["build", root, "--isolated", "--output-format", "json"])
        #expect(buildRun.first?["succeeded"] as? Bool == true, "\(buildRun.first?["summary"] ?? "")")

        let testRun = try await fixtureToolArray(["build", root, "--test", "--isolated", "--output-format", "json"])
        #expect(testRun.contains { $0["succeeded"] as? Bool == true }, "\(testRun.map { $0["summary"] ?? "" })")
        #expect(testRun.contains { $0["testsTotal"] as? Int == 1 }, "executed count parsed from the run log")
        #expect(testRun.contains { $0["testsFailed"] as? Int == 0 })

        #expect(fingerprint() == before, "the package's real .build must be byte-for-byte untouched")
        #expect(!FileManager.default.fileExists(atPath: root + "/.build/swift-package-audit"),
                "the audit scratch must remove itself")

        // clean --audit: stale run swept, fresh run kept, real .build intact
        let auditRoot = root + "/.build/swift-package-audit"
        try FileManager.default.createDirectory(atPath: auditRoot + "/run-stale123", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: auditRoot + "/run-fresh123", withIntermediateDirectories: true)
        let oldDate = Date().addingTimeInterval(-7200)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: auditRoot + "/run-stale123")

        let clean = try await fixtureTool("clean", root, "--audit", "--output-format", "json")
        #expect(clean["ok"] as? Bool == true)
        #expect(clean["removed_runs"] as? Int == 1, "exactly the stale run")
        #expect(!FileManager.default.fileExists(atPath: auditRoot + "/run-stale123"))
        #expect(FileManager.default.fileExists(atPath: auditRoot + "/run-fresh123"), "a live run's scratch survives")
        #expect(fingerprint() == before, "clean --audit must not touch real build products")

        try? FileManager.default.removeItem(atPath: auditRoot)
    }
}

// MARK: - the tool surface

@Suite("Inspector port: tool surface", .serialized)
struct InspectorToolSurfacePortTests {

    @Test("the manifest describes all 11 tools with a path-required schema")
    func toolSchemaShape() async throws {
        let output = try await runToolStdout(["plugin", "--mcp-manifest", "arc"])
        let manifest = try #require(
            try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
        let tools = manifest["tools"] as? [[String: Any]] ?? []
        let names = Set(tools.compactMap { $0["name"] as? String })
        #expect(names == [
            "pkg_build", "pkg_scan", "pkg_list_dependencies", "pkg_list_targets",
            "pkg_test", "pkg_clean", "pkg_docc_check", "pkg_inspector",
            "pkg_api", "pkg_force_unwraps", "pkg_validate",
        ])

        for tool in tools {
            let name = tool["name"] as? String ?? "?"
            let schema = try #require(tool["schema"] as? [String: Any], "\(name): bare schema object")
            #expect(schema["type"] as? String == "object", "\(name)")
            #expect(schema["required"] as? [String] == ["path"], "\(name): path is the one required parameter")
            let properties = try #require(schema["properties"] as? [String: Any], "\(name)")
            #expect((properties["path"] as? [String: Any])?["type"] as? String == "string", "\(name)")

            // every other parameter is described (description present) so a
            // small model cannot invent one
            for (param, value) in properties {
                let info = value as? [String: Any] ?? [:]
                #expect(info["description"] is String, "\(name).\(param) must carry a description")
            }
        }

        // scan's categories is a real array with its enum values
        let scan = try #require(tools.first { $0["name"] as? String == "pkg_scan" })
        let scanSchema = scan["schema"] as? [String: Any] ?? [:]
        let categories = (scanSchema["properties"] as? [String: Any])?["categories"] as? [String: Any] ?? [:]
        #expect(categories["type"] as? String == "array")
        #expect((categories["enum"] as? [String])?.contains("secrets") == true)
    }

    @Test("every one of the 11 tools answers through the plugin envelope")
    func allToolsRoundTrip() async throws {
        let root = try makeInspectorFixture("uk-surface")
        defer { try? FileManager.default.removeItem(atPath: root) }

        try writeFixture("""
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(
            name: "Surface",
            products: [.library(name: "Surface", targets: ["Surface"])],
            targets: [
                .target(name: "Surface"),
                .testTarget(name: "SurfaceTests", dependencies: ["Surface"]),
            ]
        )
        """, to: root + "/Package.swift")
        try writeFixture("""
        /// Documented.
        public struct Surface {}
        public func undocumented() {}
        """, to: root + "/Sources/Surface/Surface.swift")
        try writeFixture("""
        import XCTest
        final class SurfaceTests: XCTestCase {
            func testNothing() { XCTAssertTrue(true) }
        }
        """, to: root + "/Tests/SurfaceTests/SurfaceTests.swift")

        func json(_ result: String) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any],
                         "expected an object payload, got: \(result.prefix(200))")
        }
        func array(_ result: String) throws -> [[String: Any]] {
            try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [[String: Any]],
                         "expected an array payload, got: \(result.prefix(200))")
        }

        // read-only tools
        let targets = try json(try await pluginTool("pkg_list_targets", ["path": root]))
        #expect(targets["count"] as? Int == 2)
        let compactTargets = try json(try await pluginTool("pkg_list_targets", ["path": root, "compact": true]))
        #expect((compactTargets["targets"] as? [[String: Any]])?.count == 2)

        let deps = try json(try await pluginTool("pkg_list_dependencies", ["path": root]))
        #expect(deps["count"] as? Int == 0)

        let scan = try json(try await pluginTool("pkg_scan", ["path": root]))
        #expect((scan["by_category"] as? [String: Any])?.count == 4, "all four categories by default")

        let compactScan = try json(try await pluginTool(
            "pkg_scan", ["path": root, "categories": ["force_unwraps"], "compact": true]))
        let scanCategories = try #require(compactScan["by_category"] as? [String: Any])
        #expect(scanCategories.keys.sorted() == ["force_unwraps"], "the array argument narrows the run")

        let docc = try json(try await pluginTool("pkg_docc_check", ["path": root]))
        #expect((docc["coverage"] as? [String: Any])?["declarations"] as? Int == 2)

        let api = try array(try await pluginTool("pkg_api", ["path": root]))
        #expect(api.contains { $0["name"] as? String == "Surface" })

        #expect(try await array(try pluginTool("pkg_force_unwraps", ["path": root])).isEmpty,
                "no force unwraps in the fixture")
        #expect(try await array(try pluginTool("pkg_validate", ["path": root])).isEmpty,
                "a clean fixture validates with no diagnostics")

        // the audit-safe mutating tools (build/test report one result object per phase)
        let buildRun = try array(try await pluginTool("pkg_build", ["path": root]))
        #expect(buildRun.first?["succeeded"] as? Bool == true, "\(buildRun.first?["summary"] ?? "")")

        let testRun = try array(try await pluginTool("pkg_test", ["path": root]))
        #expect(testRun.contains { $0["succeeded"] as? Bool == true }, "\(testRun.map { $0["summary"] ?? "" })")
        #expect(testRun.contains { $0["testsTotal"] as? Int == 1 })

        let inspector = try json(try await pluginTool("pkg_inspector", ["path": root, "compact": true]))
        #expect(inspector["target_count"] as? Int == 2)
        #expect(inspector["build_succeeded"] as? Bool == true, "the composed verdict rides the envelope too")

        let clean = try json(try await pluginTool("pkg_clean", ["path": root]))
        #expect(clean["ok"] as? Bool == true)
        #expect(FileManager.default.fileExists(atPath: root + "/.build"), "a tool call never destroys the real build")
    }
}