import PackagePlugin
import Foundation

@main
struct NormalizeSyntaxPlugin: CommandPlugin {

    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let parsed = try ArgumentParser.parse(arguments)
        if parsed.showHelp {
            ArgumentParser.printUsage()
            return
        }

        let sourceFiles = collectSourceFiles(in: context.package)
        guard !sourceFiles.isEmpty else {
            Diagnostics.warning("No source files found to normalize.")
            return
        }

        // locate the helper tool that does the actual normalization. keeping the
        // logic in a library the tool imports lets us unit-test it (plugins
        // cannot depend on libraries directly), while the plugin stays thin glue.
        let tool = try context.tool(named: "normalizer-tool")
        let toolURL = tool.url

        // build the tool's argument list: every source file plus the options.
        var toolArgs: [String] = []
        if parsed.dryRun { toolArgs.append("--dry-run") }
        switch parsed.lineEnding {
        case .crlf: toolArgs.append("--crlf")
        case .lf: break
        }
        if !parsed.stripTrailingWhitespace { toolArgs.append("--keep-trailing-whitespace") }
        if !parsed.ensureFinalNewline { toolArgs.append("--no-final-newline") }
        if parsed.collapseBlankLines { toolArgs.append("--collapse-blank-lines") }
        if parsed.minify { toolArgs.append("--minify") }
        switch parsed.indentation {
        case .preserve: toolArgs.append("--preserve-indentation")
        case .tabsToSpaces(let n):
            toolArgs.append("--tabs-to-spaces")
            toolArgs.append(String(n))
        case .spacesToTabs(let n):
            toolArgs.append("--spaces-to-tabs")
            toolArgs.append(String(n))
        }
        for file in sourceFiles {
            toolArgs.append("--file")
            toolArgs.append(file.url.path)
        }

        // run the tool and stream its output through to the user.
        let process = Process()
        process.executableURL = toolURL
        process.arguments = toolArgs
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            Diagnostics.error("normalizer-tool exited with status \(process.terminationStatus).")
        }
    }

    // MARK: - source file discovery

    private func collectSourceFiles(in package: Package) -> [File] {
        let allowedExtensions: Set<String> = [
            "swift", "m", "mm", "c", "h", "cc", "cpp", "cxx", "s", "S", "metal",
        ]
        var seen = Set<String>()
        var files: [File] = []

        for target in package.targets {
            guard let module = target as? SourceModuleTarget else { continue }
            for file in module.sourceFiles {
                let ext = file.url.pathExtension.lowercased()
                guard allowedExtensions.contains(ext) else { continue }
                let key = file.url.standardizedFileURL.path
                if seen.insert(key).inserted {
                    files.append(file)
                }
            }
        }
        return files
    }
}