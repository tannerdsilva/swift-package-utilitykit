import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParser

// MARK: - output formatting

public enum OutputFormat: String, ExpressibleByArgument, Codable, Sendable {
    case json
    case compact
    case csv
    case short
    case jsonl

    public init?(argument: String) {
        self.init(rawValue: argument)
    }
}

/// format a collection of encodable items for agent consumption.
public func formatOutput<T: Encodable & Sendable>(
    _ items: [T],
    format: OutputFormat,
    header: [String]? = nil
) throws -> String {
    switch format {
    case .json:
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(items)
        return String(data: data, encoding: .utf8) ?? "[]"

    case .compact:
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(items)
        return String(data: data, encoding: .utf8) ?? "[]"

    case .csv:
        guard !items.isEmpty else { return header?.joined(separator: ",") ?? "" }
        // use mirror to extract key-value pairs for the first item as header
        var lines: [String] = []
        if let h = header {
            lines.append(h.map { escapeCsvField($0) }.joined(separator: ","))
        }
        for item in items {
            let mirror = Mirror(reflecting: item)
            let values = mirror.children.map { _, value -> String in
                escapeCsvField("\(value)")
            }
            lines.append(values.joined(separator: ","))
        }
        return lines.joined(separator: "\n")

    case .short:
        return items.map { "\($0)" }.joined(separator: "\n")

    case .jsonl:
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let lines = try items.map { item -> String in
            let data = try enc.encode(item)
            return String(data: data, encoding: .utf8) ?? "{}"
        }
        return lines.joined(separator: "\n")
    }
}

private func escapeCsvField(_ field: String) -> String {
    if field.contains(",") || field.contains("\"") || field.contains("\n") {
        let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
    return field
}

// MARK: - search
