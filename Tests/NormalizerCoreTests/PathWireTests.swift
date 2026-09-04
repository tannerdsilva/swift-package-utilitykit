import Testing
import Foundation

/// integration tests for the `path-wire` subcommand (former shell script
/// `scripts/path-wire.sh`). each test runs the built binary as a subprocess
/// against a sandboxed `HOME` so real shell rc files are never touched.
@Suite("swift-package-tool path-wire")
struct PathWireTests {

    let binaryPath: String

    init() throws {
        let pkgDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        binaryPath = pkgDir
            .appendingPathComponent(".build/debug/swift-package-tool").path
    }

    /// run the binary with a sandboxed HOME and return stdout.
    @discardableResult
    private func runPathWire(_ args: [String], home: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["path-wire"] + args
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func makeSandbox() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pathwire-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func read(_ file: String) -> String? {
        try? String(contentsOfFile: file, encoding: .utf8)
    }

    @Test("add writes marker-guarded export to .profile")
    func addWritesProfile() throws {
        let home = try makeSandbox()
        try runPathWire(["/opt/tools"], home: home)
        let profile = read("\(home)/.profile")
        #expect(profile?.contains("# >>> swift-package-utilitykit >>>") == true)
        #expect(profile?.contains("# <<< swift-package-utilitykit <<<") == true)
        #expect(profile?.contains("export PATH=\"/opt/tools:$PATH\"") == true)
    }

    @Test("add uses $HOME-relative export for dirs under home")
    func addUsesHomeRelative() throws {
        let home = try makeSandbox()
        try runPathWire(["\(home)/bin"], home: home)
        let profile = read("\(home)/.profile")
        #expect(profile?.contains("$HOME/bin") == true)
    }

    @Test("add is idempotent — second run adds no duplicate block")
    func addIsIdempotent() throws {
        let home = try makeSandbox()
        try runPathWire(["/opt/tools"], home: home)
        try runPathWire(["/opt/tools"], home: home)
        let profile = read("\(home)/.profile")
        let blockCount = (profile ?? "").components(separatedBy: "# >>> swift-package-utilitykit >>>").count - 1
        #expect(blockCount == 1)
    }

    @Test("add only touches .bashrc/.zshrc when they already exist")
    func addRespectsExistingFiles() throws {
        let home = try makeSandbox()
        try "export FOO=1\n".write(toFile: "\(home)/.zshrc", atomically: true, encoding: .utf8)
        try runPathWire(["/opt/tools"], home: home)
        let zshrc = read("\(home)/.zshrc")
        #expect(zshrc?.contains("swift-package-utilitykit") == true)
        #expect(zshrc?.contains("export FOO=1") == true)
        // .bashrc was never created by the tool
        #expect(FileManager.default.fileExists(atPath: "\(home)/.bashrc") == false)
    }

    @Test("remove strips the block and preserves other content")
    func removePreservesOtherContent() throws {
        let home = try makeSandbox()
        try "export KEEP=1\n".write(toFile: "\(home)/.profile", atomically: true, encoding: .utf8)
        try runPathWire(["/opt/tools"], home: home)
        try runPathWire(["--remove"], home: home)
        let profile = read("\(home)/.profile")
        #expect(profile?.contains("swift-package-utilitykit") == false)
        #expect(profile?.contains("export KEEP=1") == true)
    }

    @Test("uninstall-compatible: remove handles the legacy scripts/path-wire.sh marker")
    func removeHandlesLegacyMarker() throws {
        let home = try makeSandbox()
        // block as written by the former shell script
        let legacy = """
        \n# >>> swift-package-utilitykit >>> PATH (managed by scripts/path-wire.sh, do not edit)
        export PATH="$HOME/.local/bin:$PATH"
        # <<< swift-package-utilitykit <<<

        """
        try legacy.write(toFile: "\(home)/.profile", atomically: true, encoding: .utf8)
        try runPathWire(["--remove"], home: home)
        let profile = read("\(home)/.profile")
        #expect(profile?.contains("swift-package-utilitykit") == false)
    }

    @Test("add then remove leaves an empty .profile")
    func addThenRemoveEmpty() throws {
        let home = try makeSandbox()
        try runPathWire(["/opt/tools"], home: home)
        try runPathWire(["--remove"], home: home)
        let profile = read("\(home)/.profile")
        #expect(profile?.isEmpty == true)
    }
}
