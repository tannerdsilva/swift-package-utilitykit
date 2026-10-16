//===----------------------------------------------------------------------===//
//
// swift-package-utilitykit
//
// Copyright (c) 2024 and the swift-package-utilitykit project authors
// Licensed under the MIT License
//
// See LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

import ArgumentParser

/// `swift-package-tool edit` — the in-place Swift source-editing verbs.
///
/// the family is a group so the root help stays a map (one `edit` entry
/// instead of eleven bare verbs) and the edit vocabulary gets its own help
/// page. every verb shares one contract: the result is re-parsed and the write
/// is withheld when it would not parse (unless `--force` is set), and
/// `--dry-run` previews the change — diff included — without touching the
/// file. a selector that matched nothing, or a write withheld by verification,
/// is a real failure: the EditResult payload prints and the process exits 1.
///
/// the verbs map one-for-one onto the agent surface's `pkg_edit_*` tools, so
/// the two vocabularies stay the same words for the same jobs.
struct EditGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Edit Swift source files in place (replace, rename, insert, ...).",
        discussion: """
        each verb prints a single EditResult JSON (file, modified, verified, \
        warning, status, diff) and `edit <verb> --schema` prints its result \
        schema. `edit batch` applies a JSON plan of many operations in one \
        pass. a verb that matched nothing, or whose result would not parse, \
        exits 1 after printing the payload — never a silent success.
        """,
        subcommands: [
            ReplaceCommand.self,
            ReplaceRangeCommand.self,
            RenameCommand.self,
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
        ]
    )

    func run() throws {
        // `edit` with no verb is a help request, not an error: print the
        // group's help page (exit 0) exactly as `--help` would.
        throw CleanExit.helpRequest(Self.self)
    }
}