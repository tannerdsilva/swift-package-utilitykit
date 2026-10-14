import ArgumentParser

/// a toolset for querying, inspecting, auditing, building, and editing Swift
/// source code and packages, optimized for agentic consumption.
@main
struct SwiftCodeQuery: AsyncParsableCommand {

    /// the semantic package version. protocol metadata (the MCP manifest) stays
    /// plain semver; `--version` additionally reports build provenance through
    /// `AppVersion.display`, so the two can never disagree about the number.
    static let packageVersion = AppVersion.semantic

    static let configuration = CommandConfiguration(
        commandName: "swift-package-tool",
        abstract: "Inspect, audit, build, edit, and document Swift packages and source files.",
        version: AppVersion.display,
        subcommands: [
            // find + search: questions about the source
            FindCommand.self,
            QueryCommand.self,
            SearchCommand.self,
            ReadCommand.self,
            InspectCommand.self,
            ReferencesCommand.self,
            DependenciesCommand.self,
            MembersCommand.self,
            TreeCommand.self,
            CallgraphCommand.self,
            ConformancesCommand.self,
            ComplexityCommand.self,
            IndexCommand.self,
            DiffCommand.self,
            FormatCommand.self,
            MacroExpandCommand.self,
            // the package: audit, build, document
            InspectorCommand.self,
            TargetsCommand.self,
            PackageDependenciesCommand.self,
            ScanCommand.self,
            DocCoverageCommand.self,
            DoccCheckCommand.self,
            ApiCommand.self,
            ForceUnwrapsCommand.self,
            ValidateCommand.self,
            BuildCommand.self,
            TestCommand.self,
            CleanCommand.self,
            // edit: in-place source edits (one help page, one vocabulary)
            EditGroup.self,
            // harness + install
            InstallCommand.self,
            UninstallCommand.self,
            PathWireCommand.self,
            SkillGenerateCommand.self,
            PluginCommand.self,
        ]
        // no defaultSubcommand: an unknown first token must be a hard error,
        // not a silent fall-through to `find` (a typo'd subcommand must not
        // look like a successful empty query).
    )
}