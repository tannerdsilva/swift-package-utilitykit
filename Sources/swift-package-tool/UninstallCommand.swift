#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import Foundation
import ArgumentParser

/// remove the binaries, Hermes plugin, and PATH wiring installed by
/// `swift-package-tool install`.
///
/// port of the former `scripts/install.sh --remove`. dependencies are never
/// touched — clean/deep-clean is the `swift-package-tool clean` command's job.
struct UninstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove installed binaries, plugin, and PATH wiring."
    )

    @Flag(name: .customLong("force"), help: "Skip removal confirmation.")
    var force = false

    @Flag(name: .customLong("no-interactive"), help: "Never prompt; remove without confirmation.")
    var noInteractive = false

    @Flag(name: .customLong("no-path-update"), help: "Skip removing the harness PATH wiring.")
    var noPathUpdate = false

    @Option(name: .customLong("prefix"), help: "Parent directory for binaries (default: ~/.local).")
    var prefix: String?

    @Option(name: .customLong("bin-dir"), help: "Exact binary install dir (overrides --prefix/bin).")
    var binDir: String?

    @Option(name: .customLong("hermes-plugins"), help: "Hermes plugins directory (default: ~/.hermes/plugins).")
    var hermesPluginsDir: String?

    mutating func run() throws {
        let env = ProcessInfo.processInfo.environment
        let home = PathWirer.homeDir()

        let installDir: String
        if let explicit = binDir ?? env["BIN_DIR"], !explicit.isEmpty {
            installDir = explicit
        } else {
            let pfx = prefix ?? env["PREFIX"] ?? "\(home)/.local"
            installDir = "\(pfx)/bin"
        }

        let pluginsDir = hermesPluginsDir ?? env["HERMES_PLUGINS_DIR"] ?? env["HERMES_PLUGINS"] ?? "\(home)/.hermes/plugins"
        let pluginName = "swift-package-utilitykit"
        let pluginDst = "\(pluginsDir)/\(pluginName)"

        InstPrinter.info("Removing swift-package-utilitykit...")

        // ---- find installed artifacts ----------------------------------------------

        var foundBins: [String] = []
        var seen = Set<String>()
        var removeDirs: [String] = []
        if let explicitDir = binDir ?? env["BIN_DIR"], !explicitDir.isEmpty {
            removeDirs.append(explicitDir)
        }
        removeDirs += [installDir, "\(home)/.local/bin", "/usr/local/bin"]

        for dir in removeDirs {
            for bin in ["swift-package-tool", "normalizer-tool"] {
                let candidate = "\(dir)/\(bin)"
                if FileManager.default.fileExists(atPath: candidate), !seen.contains(candidate) {
                    seen.insert(candidate)
                    foundBins.append(candidate)
                }
            }
        }

        var foundPlugin = false
        if FileManager.default.fileExists(atPath: pluginDst) || isSymlink(pluginDst) {
            foundPlugin = true
        }

        if foundBins.isEmpty && !foundPlugin {
            InstPrinter.info("Nothing to remove.")
            return
        }

        InstPrinter.info("Found: binaries(\(foundBins.isEmpty ? "none" : foundBins.joined(separator: " "))) plugin(\(foundPlugin ? pluginName : "none"))")

        if !force && !noInteractive && isInteractive() && ProcessInfo.processInfo.environment["NO_INTERACTIVE"] != "1" {
            print("  Remove all? [y/N] ", terminator: "")
            guard let answer = readLine()?.lowercased(),
                  answer == "y" || answer == "yes" else {
                InstPrinter.info("Cancelled.")
                return
            }
        }

        // ---- remove binaries ---------------------------------------------------------

        for binPath in foundBins {
            let dir = (binPath as NSString).deletingLastPathComponent
            var cmd = [String]()
            if !FileManager.default.isWritableFile(atPath: dir) {
                cmd.append("sudo")
            }
            cmd += ["rm", "-f", binPath]
            if runProcess("/usr/bin/env", cmd) != nil {
                InstPrinter.ok("Removed \(binPath)")
            } else {
                InstPrinter.warn("Failed to remove \(binPath)")
            }
        }

        // ---- remove plugin -------------------------------------------------------------

        if foundPlugin {
            if runProcess("/bin/rm", ["-rf", pluginDst]) != nil {
                InstPrinter.ok("Removed \(pluginDst)")
            } else {
                InstPrinter.warn("Failed to remove \(pluginDst)")
            }
        }

        // ---- remove PATH wiring ----------------------------------------------------------

        if !noPathUpdate && env["PATH_UPDATE"] != "0" {
            InstPrinter.info("Removing harness PATH wiring...")
            PathWirer.remove(onlyDir: nil)
        }

        InstPrinter.info("Removal complete.")
    }
}

/// true when stdin is a terminal and no noninteractive mode was requested.
func isInteractive() -> Bool {
    // there is no cross-platform `isatty` in Foundation; a missing stdin pipe
    // (agent harness) reads as EOF, which the prompt below treats as cancel.
    isatty(0) != 0
}
