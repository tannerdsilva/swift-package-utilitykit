import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParser

// NOTE: SyntaxUtils.swift has been split into:
//   OutputFormat.swift  — OutputFormat enum, formatOutput, writeOutput
//   Declarations.swift  — DeclarationInfo, SymbolDetail, SymbolFinder
//   Visitors.swift      — Syntax visitors (FunctionNameCollector, etc.)
//   Helpers.swift       — collectSwiftFiles, lineColumn, UsageError
//
// This file retains the trivia helpers and declaration kind helpers
// that are used by multiple commands.

// MARK: - trivia helpers

/// extract doc-comment lines from leading trivia.
public func extractDocComment(from trivia: Trivia) -> String {
    let pieces = trivia.compactMap { piece -> String? in
        switch piece {
        case .docLineComment(let text):
            return text
        case .docBlockComment(let text):
            return text
        default:
            return nil
        }
    }
    return pieces.joined(separator: "\n")
}

/// extract regular (non-doc) comments from leading trivia.
public func extractComments(from trivia: Trivia) -> String {
    let pieces = trivia.compactMap { piece -> String? in
        switch piece {
        case .lineComment(let text):
            return text
        case .blockComment(let text):
            return text
        default:
            return nil
        }
    }
    return pieces.joined(separator: "\n")
}

// MARK: - declaration kind helpers

public func kindString(for node: some DeclSyntaxProtocol) -> String {
    switch node {
    case is FunctionDeclSyntax:      return "function"
    case is StructDeclSyntax:        return "struct"
    case is ClassDeclSyntax:         return "class"
    case is EnumDeclSyntax:          return "enum"
    case is ProtocolDeclSyntax:      return "protocol"
    case is VariableDeclSyntax:      return "variable"
    case is TypeAliasDeclSyntax:     return "typealias"
    case is AssociatedTypeDeclSyntax:     return "associatedtype"
    case is ExtensionDeclSyntax:     return "extension"
    case is InitializerDeclSyntax:   return "initializer"
    case is DeinitializerDeclSyntax: return "deinitializer"
    case is SubscriptDeclSyntax:     return "subscript"
    case is OperatorDeclSyntax:      return "operator"
    case is PrecedenceGroupDeclSyntax: return "precedencegroup"
    case is MacroDeclSyntax:         return "macro"
    case is MacroExpansionDeclSyntax:return "macro_expansion"
    case is ImportDeclSyntax:        return "import"
    default:                         return "declaration"
    }
}

/// extract the name token from a declaration node, if it has one.
public func declarationName(from node: some DeclSyntaxProtocol) -> String? {
    switch node {
    case let f as FunctionDeclSyntax:      return f.name.text
    case let s as StructDeclSyntax:        return s.name.text
    case let c as ClassDeclSyntax:         return c.name.text
    case let e as EnumDeclSyntax:          return e.name.text
    case let p as ProtocolDeclSyntax:      return p.name.text
    case let t as TypeAliasDeclSyntax:     return t.name.text
    case let a as AssociatedTypeDeclSyntax:return a.name.text
    case let ext as ExtensionDeclSyntax:   return "extension \(ext.extendedType.description.trimmingCharacters(in: CharacterSet.whitespaces))"
    case let initDecl as InitializerDeclSyntax:
        return "init\(initDecl.optionalMark?.text ?? "")"
    case let deinitDecl as DeinitializerDeclSyntax:
        return "deinit"
    case let sub as SubscriptDeclSyntax:   return "subscript"
    case let op as OperatorDeclSyntax:     return op.name.text
    case let pg as PrecedenceGroupDeclSyntax: return pg.name.text
    case let m as MacroDeclSyntax:         return m.name.text
    case let i as ImportDeclSyntax:        return i.path.description.trimmingCharacters(in: CharacterSet.whitespaces)
    case let v as VariableDeclSyntax:
        // return the first binding name
        if let binding = v.bindings.first, let pattern = binding.pattern.as(IdentifierPatternSyntax.self) {
            return pattern.identifier.text
        }
        return nil
    default:
        return nil
    }
}

/// extract modifier names from a declaration via direct property access.
/// Mirror-based reflection does not work with swift-syntax's generated node
/// types, so we must cast to each concrete type explicitly.
public func modifierNames(from node: some DeclSyntaxProtocol) -> [String] {
    let modList: DeclModifierListSyntax?
    switch node {
    case let n as FunctionDeclSyntax:       modList = n.modifiers
    case let n as StructDeclSyntax:         modList = n.modifiers
    case let n as ClassDeclSyntax:          modList = n.modifiers
    case let n as EnumDeclSyntax:           modList = n.modifiers
    case let n as ProtocolDeclSyntax:       modList = n.modifiers
    case let n as ExtensionDeclSyntax:      modList = n.modifiers
    case let n as VariableDeclSyntax:       modList = n.modifiers
    case let n as InitializerDeclSyntax:    modList = n.modifiers
    case let n as DeinitializerDeclSyntax:  modList = n.modifiers
    case let n as SubscriptDeclSyntax:      modList = n.modifiers
    case let n as TypeAliasDeclSyntax:      modList = n.modifiers
    case let n as AssociatedTypeDeclSyntax: modList = n.modifiers
    case let n as OperatorDeclSyntax:      modList = nil
    case let n as PrecedenceGroupDeclSyntax:modList = nil
    case let n as MacroDeclSyntax:         modList = nil
    default:
        // fallback: try Mirror for unknown types
        let mirror = Mirror(reflecting: node)
        for child in mirror.children {
            if child.label == "modifiers", let list = child.value as? DeclModifierListSyntax {
                return list.map { $0.name.text }
            }
        }
        return []
    }
    return modList?.map { $0.name.text } ?? []
}

/// build a one-line signature string for a declaration.
public func signatureString(for node: some DeclSyntaxProtocol) -> String {
    switch node {
    case let f as FunctionDeclSyntax:
        let sig = f.signature
        let returnClause = sig.returnClause.map { " -> \($0.type.description.trimmingCharacters(in: CharacterSet.whitespaces))" } ?? ""
        let params = sig.parameterClause.parameters.map { param -> String in
            let label = param.firstName.text
            let name = param.secondName?.text ?? ""
            let type = param.type.description.trimmingCharacters(in: CharacterSet.whitespaces)
            if label == name || name.isEmpty {
                return "\(label): \(type)"
            }
            return "\(label) \(name): \(type)"
        }.joined(separator: ", ")
        return "func \(f.name.text)(\(params))\(returnClause)"

    case let s as StructDeclSyntax:
        let inheritance = s.inheritanceClause.map { ": \($0.inheritedTypes.map { $0.type.description.trimmingCharacters(in: CharacterSet.whitespaces) }.joined(separator: ", "))" } ?? ""
        return "struct \(s.name.text)\(inheritance)"

    case let c as ClassDeclSyntax:
        let inheritance = c.inheritanceClause.map { ": \($0.inheritedTypes.map { $0.type.description.trimmingCharacters(in: CharacterSet.whitespaces) }.joined(separator: ", "))" } ?? ""
        return "class \(c.name.text)\(inheritance)"

    case let e as EnumDeclSyntax:
        let inheritance = e.inheritanceClause.map { ": \($0.inheritedTypes.map { $0.type.description.trimmingCharacters(in: CharacterSet.whitespaces) }.joined(separator: ", "))" } ?? ""
        return "enum \(e.name.text)\(inheritance)"

    case let p as ProtocolDeclSyntax:
        let inheritance = p.inheritanceClause.map { ": \($0.inheritedTypes.map { $0.type.description.trimmingCharacters(in: CharacterSet.whitespaces) }.joined(separator: ", "))" } ?? ""
        return "protocol \(p.name.text)\(inheritance)"

    case let t as TypeAliasDeclSyntax:
        let rhs = " = \(t.initializer.value.description.trimmingCharacters(in: CharacterSet.whitespaces))"
        return "typealias \(t.name.text)\(rhs)"

    case let a as AssociatedTypeDeclSyntax:
        let rhs = a.inheritanceClause.map { ": \($0.inheritedTypes.map { $0.type.description.trimmingCharacters(in: CharacterSet.whitespaces) }.joined(separator: ", "))" } ?? ""
        return "associatedtype \(a.name.text)\(rhs)"

    case let v as VariableDeclSyntax:
        let binding = v.bindings.first.map { b -> String in
            let pattern = b.pattern.description.trimmingCharacters(in: CharacterSet.whitespaces)
            let type = b.typeAnnotation.map { ": \($0.type.description.trimmingCharacters(in: CharacterSet.whitespaces))" } ?? ""
            return "\(v.bindingSpecifier.text) \(pattern)\(type)"
        } ?? v.description.trimmingCharacters(in: CharacterSet.whitespaces)
        return binding

    case let initDecl as InitializerDeclSyntax:
        let sig = initDecl.signature
        let params = sig.parameterClause.parameters.map { param -> String in
            let label = param.firstName.text
            let name = param.secondName?.text ?? ""
            let type = param.type.description.trimmingCharacters(in: CharacterSet.whitespaces)
            if label == name || name.isEmpty {
                return "\(label): \(type)"
            }
            return "\(label) \(name): \(type)"
        }.joined(separator: ", ")
        let optMark = initDecl.optionalMark?.text ?? ""
        return "init\(optMark)(\(params))"

    case let deinitDecl as DeinitializerDeclSyntax:
        return "deinit"

    case let sub as SubscriptDeclSyntax:
        let params = sub.parameterClause.parameters.map { param -> String in
            let label = param.firstName.text
            let name = param.secondName?.text ?? ""
            let type = param.type.description.trimmingCharacters(in: CharacterSet.whitespaces)
            if label == name || name.isEmpty {
                return "\(label): \(type)"
            }
            return "\(label) \(name): \(type)"
        }.joined(separator: ", ")
        let returnClause = sub.returnClause.type.description.trimmingCharacters(in: CharacterSet.whitespaces)
        return "subscript(\(params)) -> \(returnClause)"

    case let ext as ExtensionDeclSyntax:
        var label = "extension \(ext.extendedType.description.trimmingCharacters(in: CharacterSet.whitespaces))"
        if let whereClause = ext.genericWhereClause {
            label += " \(whereClause.description.trimmingCharacters(in: CharacterSet.whitespaces))"
        }
        return label

    case let op as OperatorDeclSyntax:
        let fixity = op.fixitySpecifier.text
        let name = op.name.text
        let prec = op.operatorPrecedenceAndTypes.map { " : \($0.precedenceGroup.text)" } ?? ""
        return "\(fixity) operator \(name)\(prec)"

    case let pg as PrecedenceGroupDeclSyntax:
        return "precedencegroup \(pg.name.text)"

    case let macro as MacroDeclSyntax:
        let sig = macro.signature
        let params = sig.parameterClause.parameters.map { param -> String in
            let label = param.firstName.text
            let name = param.secondName?.text ?? ""
            let type = param.type.description.trimmingCharacters(in: CharacterSet.whitespaces)
            if label == name || name.isEmpty {
                return "\(label): \(type)"
            }
            return "\(label) \(name): \(type)"
        }.joined(separator: ", ")
        let returnClause = sig.returnClause.map { " -> \($0.type.description.trimmingCharacters(in: CharacterSet.whitespaces))" } ?? ""
        return "macro \(macro.name.text)(\(params))\(returnClause)"

    case let macroExp as MacroExpansionDeclSyntax:
        return "#\(macroExp.macroName.text)"

    default:
        return node.description.trimmingCharacters(in: CharacterSet.whitespaces).components(separatedBy: "\n").first ?? ""
    }
}

// MARK: - source text range

/// extract the source text for a given syntax node from the original source.
public func sourceText(for node: some SyntaxProtocol, in source: String) -> String {
    // node.description gives the full source text of the node including trivia
    node.description
}
