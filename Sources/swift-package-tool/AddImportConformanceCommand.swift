import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParserDiagnostics
import SwiftParser

/// add an import statement to a Swift source file.
/// inserts alphabetically among existing imports and skips if already present.
struct AddImportCommand: ParsableCommand, EditCommand {
    static let configuration = CommandConfiguration(
        commandName: "add-import",
        abstract: "Add an import statement to a file."
    )

    @Argument(help: "File to edit.")
    var file: String

    @Option(name: .customLong("module"), help: "Module name to import.")
    var module: String

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
        let result = try FileEditor.edit(
            file: file, dryRun: dryRun, backup: backup, verify: verify, showDiff: showDiff, outputPath: outputPath
        ) { source in
            let lines = source.components(separatedBy: "\n")
            let importLine = "import \(module)"

            // Skip if already present
            if lines.contains(where: { $0 == importLine || $0.hasPrefix(importLine + " ") }) {
                return ""
            }

            // Find existing imports
            let importLines = lines.enumerated().filter { $0.element.hasPrefix("import ") }

            if importLines.isEmpty {
                // No imports — insert after any comment/copyright header
                var insertIdx = 0
                for (i, line) in lines.enumerated() {
                    if line.hasPrefix("//") || line.isEmpty {
                        insertIdx = i + 1
                    } else {
                        break
                    }
                }
                var newLines = lines
                newLines.insert("", at: insertIdx)
                newLines.insert(importLine, at: insertIdx)
                source = newLines.joined(separator: "\n")
                return ""
            }

            // Insert alphabetically
            var insertIdx = lines.count
            for (i, line) in importLines {
                let existing = line.trimmingCharacters(in: .whitespaces)
                if existing > importLine {
                    insertIdx = i
                    break
                }
                insertIdx = i + 1
            }

            var newLines = lines
            newLines.insert(importLine, at: insertIdx)
            source = newLines.joined(separator: "\n")
            return ""
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        print(String(data: data, encoding: .utf8)!)
    }
}

/// add a protocol conformance to a type's inheritance clause.
/// AST-aware — finds the type declaration and appends to its inheritance clause.
struct AddConformanceCommand: ParsableCommand, EditCommand {
    static let configuration = CommandConfiguration(
        commandName: "add-conformance",
        abstract: "Add a protocol conformance to a type."
    )

    @Argument(help: "File to edit.")
    var file: String

    @Option(name: .customLong("type"), help: "Type name to add conformance to.")
    var typeName: String

    @Option(name: .customLong("protocol"), help: "Protocol name to conform to.")
    var protocolName: String

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
        let resolved = NSString(string: file).standardizingPath
        let source = try String(contentsOfFile: resolved, encoding: .utf8)
        let tree = Parser.parse(source: source)

        // Find the type declaration
        let finder = TypeInheritanceFinder(targetName: typeName)
        finder.walk(tree)

        guard let info = finder.foundType else {
            let result = EditResult(file: resolved, modified: false, diff: nil, verified: true, warning: "no type '\(typeName)' found")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(result)
            print(String(data: data, encoding: .utf8)!)
            return
        }

        // Check if already conforms
        if info.conformances.contains(where: { $0.name == protocolName }) {
            let result = EditResult(file: resolved, modified: false, diff: nil, verified: true, warning: "'\(typeName)' already conforms to '\(protocolName)'")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(result)
            print(String(data: data, encoding: .utf8)!)
            return
        }

        // Find the insertion point — after the last existing conformance or after ':'
        var modified = source
        let insertOffset: Int

        if let lastConformance = info.conformances.last {
            // Find the position of the last conformance name
            let searchStart = modified.index(modified.startIndex, offsetBy: lastConformance.offset)
            if let range = modified[searchStart...].range(of: lastConformance.name) {
                insertOffset = modified.distance(from: modified.startIndex, to: range.upperBound)
            } else {
                insertOffset = info.colonOffset + 2
            }
        } else {
            insertOffset = info.colonOffset + 2
        }

        let insertIdx = modified.index(modified.startIndex, offsetBy: insertOffset)
        let needsComma = !info.conformances.isEmpty
        modified.insert(contentsOf: "\(needsComma ? ", " : "")\(protocolName)", at: insertIdx)

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

/// Information about a type's inheritance clause.
struct TypeInheritanceInfo {
    let name: String
    let colonOffset: Int
    let conformances: [(name: String, offset: Int)]
}

/// Find a type declaration and its inheritance clause.
class TypeInheritanceFinder: SyntaxVisitor {
    let targetName: String
    var foundType: TypeInheritanceInfo?

    init(targetName: String) {
        self.targetName = targetName
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.name.text == targetName else { return .visitChildren }
        extract(from: node.inheritanceClause, node: DeclSyntax(node))
        return .skipChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.name.text == targetName else { return .visitChildren }
        extract(from: node.inheritanceClause, node: DeclSyntax(node))
        return .skipChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.name.text == targetName else { return .visitChildren }
        extract(from: node.inheritanceClause, node: DeclSyntax(node))
        return .skipChildren
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.name.text == targetName else { return .visitChildren }
        extract(from: node.inheritanceClause, node: DeclSyntax(node))
        return .skipChildren
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        // For extensions, check the extended type name
        let extName = node.extendedType.description.trimmingCharacters(in: .whitespaces)
        guard extName == targetName else { return .visitChildren }
        extract(from: node.inheritanceClause, node: DeclSyntax(node))
        return .skipChildren
    }

    private func extract(from clause: InheritanceClauseSyntax?, node: DeclSyntax) {
        guard let clause = clause else {
            // No inheritance clause — find where to insert ':'
            let nameEnd = node.position.utf8Offset + node.description.count
            // This is approximate; for simplicity we note no clause exists
            return
        }

        let colonOffset = clause.colon.position.utf8Offset
        var conformances: [(String, Int)] = []
        for element in clause.inheritedTypes {
            let name = element.type.description.trimmingCharacters(in: .whitespaces)
            let offset = element.position.utf8Offset
            conformances.append((name, offset))
        }

        foundType = TypeInheritanceInfo(
            name: targetName,
            colonOffset: colonOffset,
            conformances: conformances
        )
    }
}
