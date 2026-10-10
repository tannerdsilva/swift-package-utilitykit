import Testing
import Foundation

/// Black-box verdict tests whose ABSENCE let the F-1 defect ship: the old
/// suite only ever built a healthy fixture, so `0 errors` was indistinguishable
/// from `errors not parsed`.  These build real fixture packages through the
/// built executable and assert on the verdict fields a model depends on.
@Suite("Build verdict: parser fidelity", .serialized)
struct BuildVerdictTests {

    /// a warning fixture build must report `warningCount > 0`.
    @Test("warning fixture build yields warningCount > 0")
    func warningFixtureCounts() async throws {
        let dir = try makeInspectorFixture("uv-verdict-warn")
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try writeFixture("""
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name:"W", products:[.library(name:"W", targets:["W"])], targets:[.target(name:"W")])
        """, to: dir + "/Package.swift")
        try writeFixture("public func f() {\n    let unused = 1\n}\n", to: dir + "/Sources/W/W.swift")

        // the build subcommand emits a JSON array of results
        let results = try await runToolArray("build", dir, "--output-format", "json")
        let diagnostics = results[0]["diagnostics"] as? [String: Any]
        #expect((diagnostics?["warningCount"] as? Int ?? 0) > 0,
                "warning fixture must be parsed as warningCount > 0")
    }

    /// an error fixture build must report `errorCount > 0`, `succeeded == false`,
    /// `exitCode == 1`, and a populated `diagnostics.errors[0]` carrying file,
    /// line, column and message.
    @Test("error fixture build yields errorCount>0, succeeded false, exit 1, populated error")
    func errorFixtureVerdict() async throws {
        let dir = try makeInspectorFixture("uv-verdict-err")
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try writeFixture("""
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name:"E", products:[.library(name:"E", targets:["E"])], targets:[.target(name:"E")])
        """, to: dir + "/Package.swift")
        try writeFixture("func broken( {\n", to: dir + "/Sources/E/E.swift")

        let results = try await runToolArray("build", dir, "--output-format", "json")
        let json = results[0]

        #expect(json["succeeded"] as? Bool == false)
        #expect(json["exitCode"] as? Int == 1)

        let diagnostics = json["diagnostics"] as? [String: Any]
        #expect((diagnostics?["errorCount"] as? Int ?? 0) > 0,
                "error fixture must be parsed as errorCount > 0")

        let errors = diagnostics?["errors"] as? [[String: Any]] ?? []
        #expect(!errors.isEmpty, "errors[0] must be populated")
        let first = errors[0]
        #expect((first["file"] as? String)?.hasSuffix(".swift") == true)
        #expect((first["line"] as? Int ?? 0) > 0)
        #expect((first["column"] as? Int ?? 0) > 0)
        #expect(!(first["message"] as? String ?? "").isEmpty)
    }
}
