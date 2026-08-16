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
    var file: String

    @Option(name: .customLong("type"), help: "Type name to add the member to.")
    var typeName: String

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

    mutating func run() throws {
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
            let bodyContent = body ?? ""
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

        let resolved = NSString(string: file).standardizingPath
        let source = try String(contentsOfFile: resolved, encoding: .utf8)
        let tree = Parser.parse(source: source)

        // Find the type's member block
        let finder = TypeMemberFinder(targetName: typeName)
        finder.walk(tree)

        guard let memberBlock = finder.foundMemberBlock else {
            let result = EditResult(file: resolved, modified: false, diff: nil, verified: true, warning: "no type '\(typeName)' found")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(result)
            print(String(data: data, encoding: .utf8)!)
            return
        }

        // Find the closing brace position
        let blockEndOffset = memberBlock.rightBrace.position.utf8Offset
        let blockEndIdx = source.index(source.startIndex, offsetBy: blockEndOffset)

        // Find the indentation of existing members
        let lines = source.components(separatedBy: "\n")
        let blockStartLine = source[..<blockEndIdx].components(separatedBy: "\n").count - 1
        let indent = blockStartLine > 0 ? FileEditor.detectIndent(lines[blockStartLine - 1]) : "    "

        // Insert before the closing brace
        var modified = source
        let indentedMember = memberDecl.components(separatedBy: "\n").map { indent + $0 }.joined(separator: "\n")

        // Check if there are existing members
        let membersBeforeClose = lines[..<blockStartLine].filter { $0.trimmingCharacters(in: .whitespaces).isEmpty == false }
        let prefix = membersBeforeClose.count > 1 ? "\n" : "\n\n"
        modified.insert(contentsOf: "\(prefix)\(indentedMember)\n", at: blockEndIdx)

        let original = source
        var warning: String? = nil
        var verified = true
        if verify {
            let verifyTree = Parser.parse(source: modified)
            let diags = ParseDiagnosticsGenerator.diagnostics(for: verifyTree)
            let errors = diags.filter { $0.diagMessage.severity == .error }
            if !errors.isEmpty {
                verified = false
                warning = "edit introduced \(errors.count) syntax error(s); use --force to write anyway"
            }
        }

        let diff: String? = (showDiff || dryRun) ? FileEditor.makeDiff(original: original, modified: modified) : nil

        if dryRun {
            let result = EditResult(file: resolved, modified: true, diff: diff, verified: verified, warning: warning)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(result)
            print(String(data: data, encoding: .utf8)!)
            return
        }

        if backup {
            try FileManager.default.copyItem(atPath: resolved, toPath: resolved + ".bak")
        }

        let target = outputPath.isEmpty ? resolved : outputPath
        try modified.write(toFile: target, atomically: true, encoding: .utf8)

        let result = EditResult(file: resolved, modified: true, diff: diff, verified: verified, warning: warning)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        print(String(data: data, encoding: .utf8)!)
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
