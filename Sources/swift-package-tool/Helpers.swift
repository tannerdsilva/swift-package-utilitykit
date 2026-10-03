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

// MARK: - source reading

/// read a swift source file as utf-8, warning to stderr when the file cannot
/// be decoded (legacy latin-1 / utf-16 / binary files).  returns nil so a
/// caller can skip the file — a skipped file is always surfaced, never a
/// silent drop from a scan.
public func readSwiftSource(_ path: String) -> String? {
    do {
        return try String(contentsOfFile: path, encoding: .utf8)
    } catch {
        FileHandle.standardError.write(Data(
            "swift-package-tool: warning: skipped non-utf8/unreadable file: \(path)\n".utf8
        ))
        return nil
    }
}

/// throw for an input path that does not exist, so "no results" (rc=0 empty
/// output) stays distinct from "invalid invocation" (rc=64).  `-` (stdin) is
/// exempt.
public func validateInputPathsExist(_ paths: [String]) throws {
    let filePaths = paths.filter { !isStdinPath($0) && !$0.isEmpty }
    for path in filePaths {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            throw ValidationError("path not found: \(path)")
        }
    }
}

// MARK: - location helpers

/// convert a utf-8 byte offset (the unit swift-syntax positions use) into a
/// 1-based line and column. the column counts characters, not bytes, so it
/// matches what an editor (or an agent reading the line) counts.
public func lineColumn(at offset: Int, in source: String) -> (line: Int, column: Int) {
    let clamped = min(max(offset, 0), source.utf8.count)
    var line = 1
    var column = 1
    var cursor = 0
    for character in source {
        if cursor >= clamped { break }
        if character == "\n" {
            line += 1
            column = 1
        } else {
            column += 1
        }
        cursor += character.utf8.count
    }
    return (line, column)
}

/// convert a utf-8 byte offset (the unit swift-syntax positions use) into a
/// `String.Index`. offsets past the end clamp to `endIndex`; an offset that
/// splits a multi-byte character rounds down to the nearest boundary.
///
/// character-based `index(_:offsetBy:)` must never be used with a byte offset:
/// it misplaces the edit — or traps with "String index is out of bounds" — as
/// soon as the text contains a multi-byte character.
func utf8Index(_ offset: Int, in source: String) -> String.Index {
    let clamped = min(max(offset, 0), source.utf8.count)
    var idx = source.utf8.index(source.utf8.startIndex, offsetBy: clamped)
    while idx > source.startIndex, idx.samePosition(in: source) == nil {
        idx = source.utf8.index(before: idx)
    }
    return idx
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
