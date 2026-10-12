import SwiftSyntax
import SwiftParser

/// A token's trivia with the trailing run of horizontal whitespace removed.
///
/// Inserting an inheritance clause puts `:` immediately against a type name,
/// and the name's own trailing space would otherwise leave
/// `struct S : Sendable`. Only the whitespace the punctuation would collide
/// with is removed — an interior space, a comment or a newline in that trivia
/// is load-bearing (comments are never deleted) and stays exactly where it was,
/// so `struct S /* note */ {` stays `struct S /* note */: Sendable {`.
func withoutTrailingHorizontalWhitespace(_ trivia: Trivia) -> Trivia {
    var pieces = Array(trivia)
    while let last = pieces.last {
        switch last {
        case .spaces, .tabs: pieces.removeLast()
        default: return Trivia(pieces: pieces)
        }
    }
    return Trivia(pieces: pieces)
}

/// AST-aware edit transforms shared by a standalone edit command and the
/// matching operation in a `batch` plan.
///
/// `batch` used to carry its own line-based re-implementations of `delete
/// --symbol` and `add-member`; they diverged from the commands they shadowed
/// (the batch delete removed every line MENTIONING the symbol rather than the
/// declaration), so both now call the one implementation here. Each function
/// takes the source in place and returns the reason nothing changed, matching
/// the ``FileEditor/edit(file:dryRun:backup:verify:showDiff:outputPath:force:transform:)``
/// transform contract.

/// Remove a named declaration (and the doc comment attached to it).
///
/// The declaration is dropped at the item-list level so its leading trivia —
/// the `///` block above it — goes with it.
func removeDeclaration(named name: String, in source: inout String) -> FileEditor.NoChange? {
    let rewriter = DeclarationDeleteRewriter(targetName: name)
    let modified = rewriter.rewrite(Parser.parse(source: source)).description
    guard rewriter.didDelete else { return FileEditor.noDeclarationNamed(name) }
    source = modified
    return nil
}

/// Insert `declaration` before a type's closing brace, indented to match the
/// members already in its body.
///
/// The insertion point comes from the syntax tree's own brace token, so a
/// brace inside a string literal or a nested type cannot deflect it.
func insertMember(
    _ declaration: String,
    intoType typeName: String,
    in source: inout String
) -> FileEditor.NoChange? {
    let finder = TypeMemberFinder(targetName: typeName)
    finder.walk(Parser.parse(source: source))

    guard let memberBlock = finder.foundMemberBlock else {
        return FileEditor.noTypeNamed(typeName)
    }

    // syntax positions are utf-8 byte offsets; character-based indexing would
    // misplace the insert — or trap — on any file with multi-byte characters.
    let blockEndOffset = memberBlock.rightBrace.positionAfterSkippingLeadingTrivia.utf8Offset
    let blockEndIdx = utf8Index(blockEndOffset, in: source)

    // the member inherits the indentation of the line above the closing brace
    let lines = source.components(separatedBy: "\n")
    let blockStartLine = source[..<blockEndIdx].components(separatedBy: "\n").count - 1
    let indent = blockStartLine > 0 ? FileEditor.detectIndent(lines[blockStartLine - 1]) : "    "
    let indentedMember = declaration
        .components(separatedBy: "\n")
        .map { indent + $0 }
        .joined(separator: "\n")

    // a body that already has members gets a single blank line of separation;
    // an empty body gets two (the declaration starts on a fresh block)
    let membersBeforeClose = lines[..<blockStartLine].filter {
        !$0.trimmingCharacters(in: .whitespaces).isEmpty
    }
    let prefix = membersBeforeClose.count > 1 ? "\n" : "\n\n"

    var modified = source
    modified.insert(contentsOf: "\(prefix)\(indentedMember)\n", at: blockEndIdx)
    source = modified
    return nil
}