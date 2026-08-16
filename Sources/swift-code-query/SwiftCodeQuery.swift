import ArgumentParser

/// a toolset for querying, inspecting, and formatting Swift source code,
/// optimized for agentic consumption.
@main
struct SwiftCodeQuery: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swift-code-query",
        abstract: "Query, inspect, search, and index Swift source code.",
        version: "0.1.0",
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
        ],
        defaultSubcommand: FindCommand.self
    )
}
