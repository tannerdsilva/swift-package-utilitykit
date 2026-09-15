import ArgumentParser

/// a toolset for querying, inspecting, and formatting Swift source code,
/// optimized for agentic consumption.
@main
struct SwiftCodeQuery: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swift-package-tool",
        abstract: "Query, inspect, search, and index Swift source code.",
        version: "1.0.0",
        subcommands: [
            FindCommand.self,
            QueryCommand.self,
            InspectCommand.self,
            FormatCommand.self,
            SearchCommand.self,
            ReferencesCommand.self,
            DependenciesCommand.self,
            IndexCommand.self,
            ApiCommand.self,
            ConformancesCommand.self,
            CallgraphCommand.self,
            MembersCommand.self,
            ComplexityCommand.self,
            DiffCommand.self,
            ForceUnwrapsCommand.self,
            BuildCommand.self,
            TreeCommand.self,
            ValidateCommand.self,
            MacroExpandCommand.self,
            DoccCheckCommand.self,
            CleanCommand.self,
            ReplaceCommand.self,
            InsertCommand.self,
            DeleteCommand.self,
            PrependCommand.self,
            AppendCommand.self,
            AddImportCommand.self,
            AddConformanceCommand.self,
            AddMemberCommand.self,
            WrapCommand.self,
            SortCommand.self,
            BatchCommand.self,
            InstallCommand.self,
            UninstallCommand.self,
            PathWireCommand.self,
        ]
        // no defaultSubcommand: an unknown first token must be a hard error,
        // not a silent fall-through to `find` (a typo'd subcommand must not
        // look like a successful empty query).
    )
}
