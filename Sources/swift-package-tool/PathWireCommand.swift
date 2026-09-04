import Foundation
import ArgumentParser

/// manage persistent harness-PATH wiring: write idempotent, marker-guarded
/// `export PATH` lines into the shell init files the harness sources.
///
/// port of the former `scripts/path-wire.sh`, kept byte-compatible with
/// existing marker blocks so an old install can be removed or re-wired.
struct PathWireCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "path-wire",
        abstract: "Wire an install directory into the harness PATH (idempotent, marker-guarded)."
    )

    @Argument(help: "Directory to add to the harness PATH.")
    var dir: String = ""

    @Flag(name: .customLong("remove"), help: "Strip every swift-package-utilitykit PATH block.")
    var remove = false

    @Option(name: .customLong("remove-dir"), help: "With --remove, strip only blocks exporting this directory.")
    var removeDir: String?

    mutating func run() throws {
        // env no-op (callers that manage PATH themselves)
        if ProcessInfo.processInfo.environment["PATH_WIRE_SKIP"] == "1" {
            return
        }

        if remove {
            PathWirer.remove(onlyDir: removeDir)
        } else {
            guard !dir.isEmpty else {
                throw ValidationError("missing <dir> argument")
            }
            if PathWirer.isOnLivePATH(dir) {
                PathWirer.printInfo("  already on PATH: \(dir)")
                return
            }
            try PathWirer.add(dir)
        }
    }
}

/// core path-wiring engine, shared by `path-wire`, `install`, and `uninstall`.
enum PathWirer {
    /// head marker prefix. the parenthetical "manager" note may vary between
    /// versions, so recognition/stripping anchors on this prefix only.
    static let headPrefix = "# >>> swift-package-utilitykit >>>"
    static let tailLine = "# <<< swift-package-utilitykit <<<"
    static let writerNote = "PATH (managed by swift-package-tool path-wire, do not edit)"

    // MARK: - io

    static func printInfo(_ s: String) { print("\u{001B}[36m  ==>\u{001B}[0m \(s)") }
    static func printOK(_ s: String) { print("\u{001B}[32m  OK\u{001B}[0m  \(s)") }
    static func printWarn(_ s: String) { print("\u{001B}[33m  WARN\u{001B}[0m \(s)") }

    /// home directory, robust to unset HOME.
    static func homeDir() -> String {
        ProcessInfo.processInfo.environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// files a bash login shell / harness snapshot reads, in source order.
    /// `~/.profile` is always included (created when missing); the rest only
    /// when they already exist on disk.
    static func candidates() -> [String] {
        let home = homeDir()
        var files = ["\(home)/.profile"]
        for name in [".bash_profile", ".bashrc", ".zshrc"] {
            let path = "\(home)/\(name)"
            if FileManager.default.fileExists(atPath: path) {
                files.append(path)
            }
        }
        return files
    }

    /// is `dir` already present on the live PATH?
    static func isOnLivePATH(_ dir: String) -> Bool {
        let live = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return live.split(separator: ":").contains { $0 == dir }
    }

    /// `$HOME`-relative form of a dir when possible (keeps wiring portable).
    static func exportDirValue(_ dir: String) -> String {
        let home = homeDir()
        if dir.hasPrefix(home + "/") {
            return "$HOME/\(dir.dropFirst(home.count + 1))"
        }
        return dir
    }

    /// does the file already carry our marker block, or export `dir`?
    static func alreadyWired(_ file: String, dir: String) -> Bool {
        guard let content = try? String(contentsOfFile: file, encoding: .utf8) else { return false }
        if content.contains(headPrefix) { return true }
        if content.contains(dir) { return true }
        let portable = exportDirValue(dir)
        if content.contains(portable) { return true }
        return false
    }

    // MARK: - add

    static func add(_ dir: String) throws {
        let value = exportDirValue(dir)
        var changed = false

        for file in candidates() {
            if !FileManager.default.fileExists(atPath: file) {
                if !FileManager.default.createFile(atPath: file, contents: nil) {
                    printWarn("cannot create \(file) — skipping")
                    continue
                }
            }
            if alreadyWired(file, dir: dir) {
                continue
            }
            guard let handle = FileHandle(forWritingAtPath: file) else {
                printWarn("not writable: \(file) — skipping")
                continue
            }
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            let block = "\n\(headPrefix) \(writerNote)\nexport PATH=\"\(value):$PATH\"\n\(tailLine)\n"
            handle.write(Data(block.utf8))
            printOK("  \(file)")
            changed = true
        }

        if changed {
            print("")
            printOK("PATH wired. New harness sessions (and login shells) will find the tools.")
            print("    A restart of the harness — or a new session — picks this up automatically.")
        } else {
            printInfo("  nothing to change (dir already exported or file set empty)")
        }
    }

    // MARK: - remove

    /// strip marker blocks (optionally only those exporting `onlyDir`),
    /// preserving everything else in each file.
    static func remove(onlyDir: String?) {
        var found = false

        for file in candidates() {
            guard FileManager.default.fileExists(atPath: file) else { continue }
            guard let original = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            guard original.contains(headPrefix) else { continue }

            if let dir = onlyDir, !original.contains(dir) {
                continue
            }

            var lines = original.components(separatedBy: "\n")
            var inBlock = false
            var output: [String] = []
            for line in lines {
                if !inBlock, line.hasPrefix(PathWirer.headPrefix) {
                    inBlock = true
                    found = true
                    continue
                }
                if inBlock, line == PathWirer.tailLine {
                    inBlock = false
                    continue
                }
                if inBlock {
                    continue
                }
                output.append(line)
            }
            let rewritten = output.joined(separator: "\n")
            if rewritten != original {
                do {
                    var outputLines = output
                    // drop up to one leading blank line left where the block was
                    if outputLines.first == "" { outputLines.removeFirst() }
                    if outputLines.last == "" { outputLines.removeLast() }
                    try outputLines.joined(separator: "\n").write(toFile: file, atomically: true, encoding: .utf8)
                    printOK("  stripped PATH block from \(file)")
                } catch {
                    printWarn("failed to edit \(file) — leaving untouched")
                }
            }
        }

        if found {
            print("")
            printInfo("PATH wiring removed.")
        } else {
            printInfo("no swift-package-utilitykit PATH wiring found.")
        }
    }
}
