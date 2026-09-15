#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import Foundation
import ArgumentParser

/// install the package's binaries and Hermes plugin onto the host.
///
/// port of the former `scripts/install.sh`: checks prerequisites, builds the
/// requested configuration, installs `swift-package-tool` and
/// `normalizer-tool` into the install dir (with sudo escalation when the dir
/// isn't writable), installs the Hermes plugin as a copy or symlink, wires
/// the install dir into the harness PATH, and verifies the result.
struct InstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Build and install the binaries and Hermes plugin."
    )

    @Flag(name: .customLong("debug"), help: "Install debug binaries instead of release.")
    var debug = false

    @Flag(name: .customLong("no-build"), help: "Skip the swift build step (use prebuilt binaries).")
    var noBuild = false

    @Flag(name: .customLong("no-plugin"), help: "Skip installing the Hermes plugin.")
    var noPlugin = false

    @Flag(name: .customLong("symlink"), help: "Install the plugin as a symlink into the plugins dir.")
    var symlinkMode = false

    @Flag(name: .customLong("copy"), help: "Install the plugin as a copy into the plugins dir (default).")
    var copyMode = false

    @Flag(name: .customLong("no-path-update"), help: "Skip wiring the install dir into the harness PATH.")
    var noPathUpdate = false

    @Flag(name: .customLong("no-interactive"), help: "Never prompt; fail on missing choices instead.")
    var noInteractive = false

    @Option(name: .customLong("prefix"), help: "Parent directory for binaries (default: ~/.local).")
    var prefix: String?

    @Option(name: .customLong("bin-dir"), help: "Exact binary install dir (overrides --prefix/bin).")
    var binDir: String?

    @Option(name: .customLong("hermes-plugins"), help: "Hermes plugins directory (default: ~/.hermes/plugins).")
    var hermesPluginsDir: String?

    mutating func run() throws {
        let env = ProcessInfo.processInfo.environment
        let home = PathWirer.homeDir()

        // ---- resolve configuration -------------------------------------------------

        let installDir: String
        if let explicit = binDir ?? env["BIN_DIR"], !explicit.isEmpty {
            installDir = explicit
        } else {
            let pfx = prefix ?? env["PREFIX"] ?? "\(home)/.local"
            installDir = "\(pfx)/bin"
        }

        let pluginsDir = hermesPluginsDir ?? env["HERMES_PLUGINS_DIR"] ?? env["HERMES_PLUGINS"] ?? "\(home)/.hermes/plugins"
        let pluginName = "swift-package-utilitykit"
        let pluginSrc = "\(repoDir())/hermes-plugin"
        let pluginDst = "\(pluginsDir)/\(pluginName)"

        let pathUpdate = !noPathUpdate && env["PATH_UPDATE"] != "0"

        // plugin mode: explicit flag > env > interactive prompt > copy default
        var interactive = !noInteractive && isInteractive() && env["NO_INTERACTIVE"] != "1"
        var pluginMode = "copy"
        if symlinkMode { pluginMode = "symlink" }
        if copyMode { pluginMode = "copy" }
        if let envMode = env["PLUGIN_MODE"], !envMode.isEmpty {
            pluginMode = envMode
        }
        if interactive && !symlinkMode && !copyMode && env["PLUGIN_MODE"] == nil {
            // interactive default is symlink (matches the former installer)
            print("  Install plugin as [s]ymlink or [c]opy? [S/c] ", terminator: "")
            if let choice = readLine()?.lowercased() {
                pluginMode = choice == "c" ? "copy" : "symlink"
            } else {
                pluginMode = "symlink"
            }
            interactive = false
        }
        guard pluginMode == "symlink" || pluginMode == "copy" else {
            throw ValidationError("PLUGIN_MODE must be symlink or copy (got '\(pluginMode)').")
        }

        if noPlugin {
            pluginMode = "skip"
        }

        // ---- prerequisites ---------------------------------------------------------

        InstPrinter.info("Installing swift-package-utilitykit...")
        InstPrinter.info("Checking prerequisites...")

        guard let swiftVersion = runCapture("/usr/bin/env", ["swift", "--version"]) else {
            throw ValidationError("Swift toolchain not found. Install Swift 6.0+ from https://swift.org/download/")
        }
        let versionLine = swiftVersion.split(separator: "\n").first.map(String.init) ?? ""
        InstPrinter.ok("\(versionLine)")

        let hermesFound = runCapture("/usr/bin/env", ["sh", "-lc", "command -v hermes"]) != nil
        if hermesFound {
            InstPrinter.ok("Hermes Agent found")
        } else {
            InstPrinter.warn("Hermes Agent not found in PATH. Install from https://hermes-agent.nousresearch.com/docs")
            InstPrinter.warn("Plugin will be installed but won't be active until Hermes is available.")
        }

        // ---- build -----------------------------------------------------------------

        let config = debug ? "debug" : "release"
        if noBuild {
            InstPrinter.info("Using prebuilt \(config) binaries (--no-build)...")
            // verify the prebuilt binaries actually exist — a stale or missing
            // build must be a hard error, never a silent no-op install
            for bin in ["swift-package-tool", "normalizer-tool"] {
                let src = "\(repoDir())/.build/\(config)/\(bin)"
                guard FileManager.default.fileExists(atPath: src) else {
                    throw ValidationError("prebuilt binary not found at \(src) — run `swift build -c \(config)` first, or drop --no-build")
                }
            }
        } else {
            InstPrinter.info("Building \(config) binaries...")
            let (buildStatus, buildLog) = runBuildCaptured(config, repo: repoDir())
            print(buildLog)
            guard buildStatus == 0 else {
                throw ValidationError("swift build -c \(config) failed; install aborted")
            }
            InstPrinter.ok("Build complete")
        }

        // ---- install binaries -------------------------------------------------------

        InstPrinter.info("Installing binaries to \(installDir)...")
        if let sudo = needSudo(for: installDir) {
            InstPrinter.info("using sudo for \(installDir) (not writable by current user)")
        }
        if interactive {
            print("  Install binaries to \(installDir)? [Y/n] ", terminator: "")
            if let answer = readLine()?.lowercased(), answer != "y", answer != "yes", !answer.isEmpty {
                InstPrinter.info("Cancelled.")
                return
            }
        }
        var mkdirCmd = [String]()
        if let s = needSudo(for: installDir) { mkdirCmd.append(s) }
        mkdirCmd += ["mkdir", "-p", installDir]
        if runProcess("/usr/bin/env", mkdirCmd) != 0 {
            throw ValidationError("failed to create install dir \(installDir)")
        }

        let buildDir = "\(repoDir())/.build/\(config)"
        for bin in ["swift-package-tool", "normalizer-tool"] {
            var icmd = [String]()
            if let s = needSudo(for: installDir) { icmd.append(s) }
            icmd += ["install", "\(buildDir)/\(bin)", "\(installDir)/\(bin)"]
            if runProcess("/usr/bin/env", icmd) != 0 {
                throw ValidationError("failed to install \(bin) (\(buildDir)/\(bin) -> \(installDir)/\(bin))")
            }
            InstPrinter.ok("  \(installDir)/\(bin)")
        }

        // ---- install plugin ---------------------------------------------------------

        if pluginMode != "skip" {
            InstPrinter.info("Installing Hermes plugin...")
            try FileManager.default.createDirectory(atPath: pluginsDir, withIntermediateDirectories: true)

            // remove previous installation (symlink or dir)
            if FileManager.default.fileExists(atPath: pluginDst) || isSymlink(pluginDst) {
                try? FileManager.default.removeItem(atPath: pluginDst)
                InstPrinter.ok("  Removed previous plugin at \(pluginDst)")
            }

            if pluginMode == "symlink" {
                try? FileManager.default.createSymbolicLink(atPath: pluginDst, withDestinationPath: pluginSrc)
                InstPrinter.ok("  Plugin symlinked: \(pluginDst) -> \(pluginSrc)")
            } else {
                try? FileManager.default.copyItem(atPath: pluginSrc, toPath: pluginDst)
                InstPrinter.ok("  Plugin copied: \(pluginSrc) -> \(pluginDst)")
            }
        } else {
            InstPrinter.info("Skipping Hermes plugin (--no-plugin)...")
        }

        // ---- wire install dir into harness PATH --------------------------------------

        if pathUpdate {
            InstPrinter.info("Wiring \(installDir) into the harness PATH...")
            if PathWirer.isOnLivePATH(installDir) {
                PathWirer.printInfo("  already on PATH: \(installDir)")
            } else {
                try? PathWirer.add(installDir)
            }
        } else {
            InstPrinter.warn("PATH wiring skipped (PATH_UPDATE=0). Add \(installDir) to your shell PATH manually.")
        }

        // ---- verify -----------------------------------------------------------------

        InstPrinter.info("Verifying installation...")
        var envExtra = ProcessInfo.processInfo.environment
        envExtra["PATH"] = "\(installDir):\(envExtra["PATH"] ?? "")"
        if let ver = runCapture("\(installDir)/swift-package-tool", ["--version"], env: envExtra) {
            InstPrinter.ok("  swift-package-tool \(ver.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else {
            InstPrinter.warn("  swift-package-tool not found in PATH. Add \(installDir) to your PATH.")
        }

        if pluginMode != "skip", hermesFound {
            // bound the hermes call — the CLI can be slow to start when a
            // server is already running, and install should never hang on it.
            if let pluginList = runCapture("/usr/bin/env", ["hermes", "plugins", "list"], timeout: 15),
               pluginList.contains(pluginName) {
                InstPrinter.ok("  Hermes plugin registered")
            } else {
                InstPrinter.warn("  Plugin installed but not yet registered. Run: hermes plugins list")
            }
        }

        print("")
        print("\u{001B}[32m✓ Installation complete!\u{001B}[0m")
        print("")
        print("  Binaries:  \(installDir)/{swift-package-tool,normalizer-tool}")
        if pluginMode != "skip" {
            print("  Plugin:    \(pluginDst) (\(pluginMode))")
        } else {
            print("  Plugin:    (skipped — --no-plugin)")
        }
        print("")
        print("  Next steps:")
        print("    1. Restart Hermes or start a new shell so the wired PATH takes effect")
        print("    2. Restart Hermes or run:  hermes plugins list")
        print("    3. Verify tools:           swift-package-tool --version")
    }

    /// the package repo root: walk up from cwd until a directory with a
    /// Package.swift + hermes-plugin is found (an agent may run install from
    /// anywhere, not just the repo root).  falls back to cwd; downstream
    /// existence checks then fail loudly instead of silently copying nothing.
    func repoDir() -> String {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<8 {
            let hasManifest = fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path)
            let hasPlugin = fm.fileExists(atPath: dir.appendingPathComponent("hermes-plugin").path)
            if hasManifest && hasPlugin {
                return dir.path
            }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return fm.currentDirectoryPath
    }
}

/// human-facing installer output (matches the former bash printer).
enum InstPrinter {
    static func info(_ s: String) { print("\u{001B}[36m==>\u{001B}[0m \(s)") }
    static func ok(_ s: String) { print("\u{001B}[32m  OK\u{001B}[0m  \(s)") }
    static func warn(_ s: String) { print("\u{001B}[33m  WARN\u{001B}[0m \(s)") }
}

/// true if the nearest existing ancestor of `dir` is not writable by the
/// current user (mirrors the bash walk-up escalation).
func needSudo(for dir: String) -> String? {
    var ancestor = dir
    while ancestor != "/" && !FileManager.default.fileExists(atPath: ancestor) {
        ancestor = (ancestor as NSString).deletingLastPathComponent
    }
    if ancestor.isEmpty { ancestor = "/" }
    guard FileManager.default.isWritableFile(atPath: ancestor) else {
        InstPrinter.info("using sudo for \(dir) (not writable by current user)")
        return "sudo"
    }
    return nil
}

/// is `path` a symlink?
func isSymlink(_ path: String) -> Bool {
    (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
}

/// run a command to completion; true when exit code is 0.
func runProcess(_ executable: String, _ args: [String], cwd: String? = nil, env: [String: String]? = nil) -> Int32? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    if let env { process.environment = env }
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    } catch {
        return nil
    }
}

/// run `swift build -c <config>` and capture the full log via a temp file
/// (draining pipes concurrently is deadlock-prone when output is large).
/// returns (exit status, trimmed log).  a failed build surfaces as non-zero —
/// the installer must never report "build complete" when the build failed.
func runBuildCaptured(_ config: String, repo: String) -> (Int32, String) {
    let fm = FileManager.default
    let logURL = fm.temporaryDirectory
        .appendingPathComponent("swift-package-tool-build-\(UUID().uuidString).log")
    defer { try? fm.removeItem(at: logURL) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["swift", "build", "-c", config]
    process.currentDirectoryURL = URL(fileURLWithPath: repo)
    let out = FileHandle(forWritingAtPath: logURL.path) ?? FileHandle.nullDevice
    process.standardOutput = out
    process.standardError = out

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return (1, "failed to launch swift build: \(error)")
    }
    try? out.close()

    let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    let trimmed = log.split(separator: "\n").suffix(5).joined(separator: "\n")
    return (process.terminationStatus, trimmed)
}

/// run a command and return its merged stdout/stderr as a string.
/// optional `timeout` bounds the wait — a timed-out child returns nil so a
/// slow external tool (e.g. the hermes CLI) can never hang the installer.
func runCapture(_ executable: String, _ args: [String], cwd: String? = nil, env: [String: String]? = nil, timeout: TimeInterval? = nil) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    if let env { process.environment = env }
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do {
        try process.run()
        if let timeout {
            // wait with an explicit bound; kill + report failure on expiry
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                usleep(50_000)
            }
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
                return nil
            }
        }
        process.waitUntilExit()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus == 0 {
            return String(data: outData, encoding: .utf8) ?? ""
        }
        let merged = (String(data: outData, encoding: .utf8) ?? "") + (String(data: errData, encoding: .utf8) ?? "")
        return merged
    } catch {
        return nil
    }
}
