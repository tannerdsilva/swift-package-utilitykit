import Testing
import Foundation

/// end-to-end tests for `skill-generate`, driving the built binary as a
/// subprocess against a fixture package. asserts the hermes skill contract
/// (frontmatter invariants, ≤60-char description, byte-determinism) plus the
/// digest/article/digest-install behavior.
@Suite("swift-package-tool skill-generate tests")
struct SkillGenerateCommandTests {

    let binaryPath: String

    init() throws {
        let pkgDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        binaryPath = pkgDir
            .appendingPathComponent(".build/debug/swift-package-tool").path
    }

    // MARK: - helpers

    /// run the binary; returns (stdout+stderr, exit code).
    private func runTool(
        _ args: [String],
        cwd: String? = nil,
        env: [String: String]? = nil
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
        try process.run()
        process.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let output = (String(data: outData, encoding: .utf8) ?? "")
            + (String(data: errData, encoding: .utf8) ?? "")
        return (output, process.terminationStatus)
    }

    private func parsedJSON(_ output: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: output.data(using: .utf8) ?? Data()))
            as? [String: Any] ?? [:]
    }

    /// a tiny package with a known documented surface + a `.docc` catalog:
    /// 6 public symbols (5 documented, 1 not), 2 internal symbols, a landing
    /// article with a callout, and an article with an `@Metadata` block.
    private func makeFixture() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skilltest-\(UUID().uuidString)")
        let packageDir = root.appendingPathComponent("pkg").path
        try FileManager.default.createDirectory(atPath: "\(packageDir)/Sources/Widget/Widget.docc", withIntermediateDirectories: true)

        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "SkillFixture",
            products: [.library(name: "Widget", targets: ["Widget"])],
            targets: [.target(name: "Widget")]
        )
        """
        try manifest.write(toFile: "\(packageDir)/Package.swift", atomically: true, encoding: .utf8)

        let source = """
        /// a widget that never sleeps.
        ///
        /// it is the smallest useful widget.
        public struct Widget: Sendable, Equatable {
            /// the widget's size.
            public let size: Int

            /// make a widget.
            public init(size: Int) {
                self.size = size
            }

            /// spin the widget.
            public func spin() -> String { "spin" }

            /// not part of the public surface by default.
            func hidden() {}
        }

        /// not part of the public surface unless --include-internal.
        func topLevelHelper() -> Int { 0 }

        /// a public free function.
        public func makeWidget() -> Widget { Widget(size: 0) }

        public enum WidgetKind: String {
            case small
            case big
        }
        """
        try source.write(toFile: "\(packageDir)/Sources/Widget/Widget.swift", atomically: true, encoding: .utf8)

        let landing = """
        # ``Widget``

        The widget module makes widgets.

        ## Topics

        ### Widgets

        - ``Widget``
        - <doc:usage>

        > Important: widgets must be spun before use.
        """
        try landing.write(toFile: "\(packageDir)/Sources/Widget/Widget.docc/Widget.md", atomically: true, encoding: .utf8)

        let usage = """
        # Using Widgets

        @Metadata {
          @PageColor(purple)
        }

        Spin any widget with ``spin()``.

        ## Steps

        1. make
        2. spin
        """
        try usage.write(toFile: "\(packageDir)/Sources/Widget/Widget.docc/usage.md", atomically: true, encoding: .utf8)

        return packageDir
    }

    // MARK: - the skill tree

    @Test("skill-generate writes a valid skill tree with a correct digest")
    func generatesSkillTree() throws {
        let pkg = try makeFixture()
        let outDir = URL(fileURLWithPath: pkg).deletingLastPathComponent().appendingPathComponent("out").path
        let (output, code) = try runTool(["skill-generate", pkg, "--output-dir", outDir])
        #expect(code == 0, "exit 0: \(output)")

        let json = parsedJSON(output)
        #expect(json["ok"] as? Bool == true)
        #expect(json["skillName"] as? String == "skillfixture-api")
        #expect(json["symbols"] as? Int == 6)
        #expect(json["documented"] as? Int == 5)
        #expect(json["undocumented"] as? Int == 1)
        let kinds = json["kinds"] as? [String: Any] ?? [:]
        #expect(kinds["struct"] as? Int == 1)
        #expect(kinds["enum"] as? Int == 1)
        #expect(kinds["variable"] as? Int == 1)
        #expect(kinds["initializer"] as? Int == 1)
        #expect(kinds["function"] as? Int == 2)
        let files = json["files"] as? [String] ?? []
        #expect(files.contains("SKILL.md"))
        #expect(files.contains("references/api.md"))
        #expect(files.contains("references/articles/usage.md"))
        #expect(files.contains("references/articles/Widget.md"))

        // description hard gate: ≤60 chars, ends with a period
        let desc = json["description"] as? String ?? ""
        #expect(desc == "Swift package public API reference for agent use.")
        #expect(desc.count <= 60)
        #expect(desc.hasSuffix("."))

        // frontmatter contract
        let skill = try String(contentsOfFile: "\(outDir)/SKILL.md", encoding: .utf8)
        #expect(skill.hasPrefix("---\n"))
        #expect(skill.contains("name: skillfixture-api"))
        #expect(skill.contains("version: 0.1.0"))
        #expect(skill.contains("author: Hermes Agent"))
        #expect(skill.contains("license: MIT"))
        #expect(skill.contains("platforms: [macos, linux]"))
        #expect(skill.contains("related_skills: []"))
        #expect(skill.contains("## When to Use"))
        #expect(skill.contains("## Verification"))
        // callout folded into pitfalls
        #expect(skill.contains("widgets must be spun before use"))
        #expect(skill.contains("**Important:**"))

        // digest: nested members under their type, abstracts, no double backticks
        let digest = try String(contentsOfFile: "\(outDir)/references/api.md", encoding: .utf8)
        #expect(digest.contains("struct Widget: Sendable, Equatable"))
        #expect(digest.contains("spin() -> String"))
        #expect(digest.contains("makeWidget() -> Widget"))
        #expect(digest.contains("the widget's size"))
        #expect(digest.contains("source: `Sources/Widget/Widget.swift:"))
        #expect(!digest.contains("``"))

        // articles: directives stripped, doc links/labels flattened
        let usage = try String(contentsOfFile: "\(outDir)/references/articles/usage.md", encoding: .utf8)
        #expect(!usage.contains("@Metadata"))
        #expect(!usage.contains("``"))
        #expect(usage.contains("Spin any widget with `spin()`"))
        let landing = try String(contentsOfFile: "\(outDir)/references/articles/Widget.md", encoding: .utf8)
        #expect(landing.contains("# Widget"))
        #expect(landing.contains("- `Widget`"))
        #expect(landing.contains("`usage`"))
        #expect(landing.contains("widgets must be spun before use"))
    }

    @Test("skill-generate honors --name, --version, and --output")
    func nameVersionAndOutput() throws {
        let pkg = try makeFixture()
        let base = URL(fileURLWithPath: pkg).deletingLastPathComponent().path
        let outDir = "\(base)/out2"
        let summaryPath = "\(base)/summary.json"
        let (output, code) = try runTool([
            "skill-generate", pkg,
            "--output-dir", outDir,
            "--name", "my-skill",
            "--version", "2.3.0",
            "--output", summaryPath,
        ])
        #expect(code == 0, "exit 0: \(output)")
        #expect(FileManager.default.fileExists(atPath: summaryPath), "summary written to --output file")

        let skill = try String(contentsOfFile: "\(outDir)/SKILL.md", encoding: .utf8)
        #expect(skill.contains("name: my-skill"))
        #expect(skill.contains("version: 2.3.0"))

        // a bad custom name is rejected loudly
        let (badOut, badCode) = try runTool(["skill-generate", pkg, "--output-dir", outDir, "--name", "Bad_Name"])
        #expect(badCode != 0)
        #expect(badOut.contains("invalid --name"))
    }

    @Test("skill-generate --include-internal captures internal declarations")
    func includeInternal() throws {
        let pkg = try makeFixture()
        let base = URL(fileURLWithPath: pkg).deletingLastPathComponent().path
        let outDir = "\(base)/out-internal"
        let (output, code) = try runTool(["skill-generate", pkg, "--output-dir", outDir, "--include-internal"])
        #expect(code == 0, "exit 0: \(output)")
        let json = parsedJSON(output)
        // 6 public + hidden() + topLevelHelper() + the manifest's `let package`
        #expect(json["symbols"] as? Int == 9)
        let digest = try String(contentsOfFile: "\(outDir)/references/api.md", encoding: .utf8)
        #expect(digest.contains("topLevelHelper"))
        #expect(digest.contains("hidden()"))
    }

    // MARK: - install

    @Test("skill-generate --install lands in the hermes skills dir")
    func installLands() throws {
        let pkg = try makeFixture()
        let base = URL(fileURLWithPath: pkg).deletingLastPathComponent().path
        let skillsDir = "\(base)/skills"
        let env = ["HERMES_SKILLS_DIR": skillsDir]
        let (output, code) = try runTool(
            ["skill-generate", pkg, "--output-dir", "\(base)/out", "--install"],
            env: env
        )
        #expect(code == 0, "exit 0: \(output)")
        let json = parsedJSON(output)
        #expect(json["installedTo"] as? String == "\(skillsDir)/swift/skillfixture-api")
        #expect(FileManager.default.fileExists(atPath: "\(skillsDir)/swift/skillfixture-api/SKILL.md"))
        #expect(FileManager.default.fileExists(atPath: "\(skillsDir)/swift/skillfixture-api/references/api.md"))

        // --category routes into the requested category
        let (output2, code2) = try runTool(
            ["skill-generate", pkg, "--output-dir", "\(base)/out", "--install", "--category", "software-development"],
            env: env
        )
        #expect(code2 == 0, "exit 0: \(output2)")
        #expect(FileManager.default.fileExists(atPath: "\(skillsDir)/software-development/skillfixture-api/SKILL.md"))
    }

    // MARK: - determinism & contract guards

    @Test("skill-generate is byte-deterministic across runs")
    func deterministic() throws {
        let pkg = try makeFixture()
        let base = URL(fileURLWithPath: pkg).deletingLastPathComponent().path
        let a = "\(base)/out-a"
        let b = "\(base)/out-b"
        let (o1, c1) = try runTool(["skill-generate", pkg, "--output-dir", a])
        let (o2, c2) = try runTool(["skill-generate", pkg, "--output-dir", b])
        #expect(c1 == 0 && c2 == 0, "\(o1) \(o2)")
        for file in ["SKILL.md", "references/api.md", "references/articles/usage.md", "references/articles/Widget.md"] {
            let x = try String(contentsOfFile: "\(a)/\(file)", encoding: .utf8)
            let y = try String(contentsOfFile: "\(b)/\(file)", encoding: .utf8)
            #expect(x == y, "byte mismatch in \(file)")
        }
    }

    @Test("skill-generate rejects the stdin path")
    func rejectsStdin() throws {
        let (output, code) = try runTool(["skill-generate", "-"])
        #expect(code != 0)
        #expect(output.contains("stdin"))
    }

    @Test("skill-generate --schema prints the summary schema")
    func schema() throws {
        let (output, code) = try runTool(["skill-generate", "--schema"])
        #expect(code == 0)
        #expect(output.contains("skillName"))
        #expect(output.contains("undocumented"))
        #expect(output.contains("kinds"))
    }
}
