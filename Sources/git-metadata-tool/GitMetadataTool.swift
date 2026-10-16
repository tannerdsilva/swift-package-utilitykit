import ArgumentParser
import Foundation
import GitMetadataCore

/// collects git provenance for a checkout and renders it as Swift constants.
///
/// the `GitMetadataPlugin` build tool plugin runs this during a build; it is
/// also usable by hand (`--print`) when a binary reports surprising
/// provenance, and `--output` writes only when the rendered text changed.
@main
struct GitMetadataTool: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "git-metadata-tool",
        abstract: "Collect git provenance and render it as Swift constants.",
        version: "3.2.0"
    )

    @Option(name: .long, help: "Repository or work-tree directory to inspect (default: current directory).")
    var repo: String = "."

    @Option(name: .long, help: "Write the rendered Swift source here; the file is only replaced when its content changes.")
    var output: String?

    @Flag(name: .customLong("print"), help: "Print the collected fields as text instead of generating source.")
    var printFields = false

    func run() async throws {
        let metadata = await GitMetadataProbe.collect(at: repo)

        if printFields {
            print(GitMetadataRenderer.text(metadata), terminator: "")
            return
        }

        guard let output, !output.isEmpty else {
            throw ValidationError("specify --output <file> to generate, or --print to inspect")
        }
        try GitMetadataRenderer.writeIfChanged(GitMetadataRenderer.swiftSource(for: metadata), to: output)
    }
}