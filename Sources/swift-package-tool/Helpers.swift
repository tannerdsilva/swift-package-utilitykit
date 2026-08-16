import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParser

// MARK: - file discovery

/// collect swift source files from the given paths.
/// returns absolute paths to all matching files.
public func collectSwiftFiles(
    from paths: [String],
    include: [String]? = nil,
    exclude: [String]? = nil
) -> [String] {
    let fm = FileManager.default
    var results: [String] = []

    // default: swift source files only (no c/c++/objc/metal — this is a swift tool)
    let defaultIncludes: Set<String> = ["swift"]
    let includeExts: Set<String> = include.map { Set($0.map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }) } ?? defaultIncludes
    let excludeExts: Set<String> = exclude.map { Set($0.map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }) } ?? []

    for path in paths {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
        let absPath = URL(fileURLWithPath: path).standardizedFileURL.path

        if isDir.boolValue {
            guard let enumerator = fm.enumerator(atPath: absPath) else { continue }
            for case let file as String in enumerator {
                let ext = (file as NSString).pathExtension.lowercased()
                guard includeExts.contains(ext) else { continue }
                if !excludeExts.isEmpty && excludeExts.contains(ext) { continue }
                let skipDirs: Set<String> = [".build", ".build-audit", ".git", ".swiftpm", "DerivedData"]
                let parts = file.split(separator: "/").map(String.init)
                if parts.dropLast().contains(where: { skipDirs.contains($0) }) { continue }
                results.append((absPath as NSString).appendingPathComponent(file))
            }
        } else {
            let ext = (absPath as NSString).pathExtension.lowercased()
            if includeExts.contains(ext) {
                results.append(absPath)
            }
        }
    }

    return results.sorted()
}

// MARK: - location helpers

/// convert a utf-8 offset in source text to 1-based line and column.
public func lineColumn(at offset: Int, in source: String) -> (line: Int, column: Int) {
    guard offset >= 0, offset <= source.utf8.count else { return (1, 1) }
    var line = 1
    var col = 1
    for (i, byte) in source.utf8.enumerated() {
        if i == offset { break }
        if byte == UInt8(ascii: "\n") { line += 1; col = 1 }
        else { col += 1 }
    }
    return (line, col)
}

// MARK: - output helpers

/// write a string to a file path, or print to stdout if path is empty.
public func writeOutput(_ string: String, to path: String) throws {
    if !path.isEmpty {
        try string.write(toFile: path, atomically: true, encoding: .utf8)
    } else {
        print(string)
    }
}

/// read all lines from stdin (for piping support via `-`).
public func readSourceFromStdin() -> String {
    var input: [String] = []
    while let line = readLine() {
        input.append(line)
    }
    return input.joined(separator: "\n")
}

/// true if a path string represents stdin (`-`).
public func isStdinPath(_ path: String) -> Bool {
    path == "-"
}

// MARK: - usage error

public struct UsageError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
