import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParserDiagnostics
import SwiftParser

/// add a member (property, method, or enum case) to a type declaration.
///
/// AST-aware — finds the type's member block and inserts at the end.
struct AddMemberCommand: ParsableCommand, EditCommand {
    static let configuration = CommandConfiguration(
        commandName: "add-member",
        abstract: "Add a property, method, or enum case to a type."
    )

    @Argument(help: "File to edit.")
    var file: String?

    @Option(name: .customLong("type"), help: "Type name to add the member to.")
    var typeName: String? = nil

    @Option(name: .customLong("property"), help: "Property declaration (e.g. 'var x: Int').")
    var property: String?

    @Option(name: .customLong("method"), help: "Method signature (e.g. 'func foo()').")
    var method: String?

    @Option(name: .customLong("body"), help: "Method body (used with --method).")
    var body: String?

    @Option(name: .customLong("case"), help: "Enum case name.")
    var caseName: String?

    @Option(name: .customLong("associated"), help: "Associated value types for enum case (comma-separated).")
    var associated: String?

    @Option(name: .customLong("default"), help: "Default value for a property.")
    var defaultValue: String?

    @Option(name: .customLong("access"), help: "Access modifier (public, private, internal).")
    var access: String?

    @Flag(name: .long, help: "Show diff without modifying.")
    var dryRun = false

    @Flag(name: .long, help: "Save original as .bak before editing.")
    var backup = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Re-parse to verify syntactic validity.")
    var verify = true

    @Flag(name: .long, help: "Show unified diff of changes.")
    var showDiff = false

    @Option(name: .customLong("output"), help: "Write to a different file instead of in-place.")
    var outputPath: String = ""

    @Flag(name: .long, help: "Write even if verification fails.")
    var force = false

    @Flag(name: .customLong("literal-content"), help: "Take content arguments literally: skip the \\n and \\\\ escape expansion.")
    var literalContent = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    @Option(name: .long, help: "Output format: json, compact, short, csv, jsonl.")
    var outputFormat: OutputFormat?

    mutating func run() throws {
        if printSchemaIfRequested() { return }
        guard let file else {
            throw ValidationError("Missing expected argument '<file>'")
        }
        guard let typeName else {
            throw ValidationError("Missing expected argument '--type <type>'")
        }
        let modes = [property != nil, method != nil, caseName != nil].filter { $0 }.count
        guard modes == 1 else {
            throw ValidationError("specify exactly one of --property, --method, or --case")
        }

        // Build the member declaration string
        let memberDecl: String
        if let prop = property {
            let accessMod = access.map { "\($0) " } ?? ""
            let defaultVal = defaultValue.map { " = \($0)" } ?? ""
            memberDecl = "\(accessMod)\(prop)\(defaultVal)"
        } else if let meth = method {
            let accessMod = access.map { "\($0) " } ?? ""
            let bodyContent = FileEditor.content(body ?? "", literal: literalContent)
            if bodyContent.isEmpty {
                memberDecl = "\(accessMod)\(meth)"
            } else {
                let indentedBody = bodyContent.components(separatedBy: "\n").map { "    \($0)" }.joined(separator: "\n")
                memberDecl = "\(accessMod)\(meth) {\n\(indentedBody)\n}"
            }
        } else if let cn = caseName {
            let accessMod = access.map { "\($0) " } ?? ""
            if let assoc = associated {
                let types = assoc.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
                memberDecl = "\(accessMod)case \(cn)(\(types))"
            } else {
                memberDecl = "\(accessMod)case \(cn)"
            }
        } else {
            throw ValidationError("specify --property, --method, or --case")
        }

        let result = try FileEditor.edit(
            file: file, dryRun: dryRun, backup: backup, verify: verify, showDiff: showDiff, outputPath: outputPath, force: force
        ) { source in
            insertMember(memberDecl, intoType: typeName, in: &source)
        }

        try emitEditResult(result)
    }
}

/// Find a type's member block by name.
class TypeMemberFinder: SyntaxVisitor {
    let targetName: String
    var foundMemberBlock: MemberBlockSyntax?

    init(targetName: String) {
        self.targetName = targetName
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == targetName { foundMemberBlock = node.memberBlock; return .skipChildren }
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == targetName { foundMemberBlock = node.memberBlock; return .skipChildren }
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == targetName { foundMemberBlock = node.memberBlock; return .skipChildren }
        return .visitChildren
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == targetName { foundMemberBlock = node.memberBlock; return .skipChildren }
        return .visitChildren
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let extName = node.extendedType.description.trimmingCharacters(in: .whitespaces)
        if extName == targetName { foundMemberBlock = node.memberBlock; return .skipChildren }
        return .visitChildren
    }
}
