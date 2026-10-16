import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParser
import SubprocessCore

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

// MARK: - line ranges

/// parse a 1-based inclusive line range like `10-20`.
///
/// the one range parser behind `edit wrap --lines` and `read --lines` — a
/// second spelling would be a second contract. callers clamp to the file;
/// this rejects only shapes that are not a range at all.
public func parseLineRange(_ raw: String) throws -> (start: Int, end: Int) {
    let parts = raw.split(separator: "-")
    guard parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]) else {
        throw ValidationError("invalid line range '\(raw)'; use format '10-20'")
    }
    return (start, end)
}

/// the file's lines, under the one line model the surface numbers.
///
/// a trailing newline terminates the last line; it does not open an empty one,
/// and an empty file has zero lines. `read` numbers these lines, and an edit
/// that takes line numbers must count them the same way — otherwise a caller
/// that reads line 12 and edits line 12 edits a different line. `read`'s
/// numbering and this split used to be the same code in two places; keeping one
/// function is what stops the two from drifting apart again.
public func sourceLines(_ content: String) -> [String] {
    if content.isEmpty { return [] }
    if content.hasSuffix("\n") {
        return content.dropLast().components(separatedBy: "\n")
    }
    return content.components(separatedBy: "\n")
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

// MARK: - error rendering

/// the message an arbitrary thrown error actually carries.
///
/// `localizedDescription` is the wrong reader for this codebase's errors:
/// `ArgumentParser.ValidationError` — which every edit command throws — is
/// `CustomStringConvertible` but NOT `LocalizedError`, so bridging it to
/// NSError discards the authored sentence and yields the useless
/// "The operation couldn't be completed. (ArgumentParser.ValidationError
/// error 1.)". Reading the conformances directly keeps what the command wrote.
public func readableError(_ error: any Error) -> String {
    if let localized = error as? any LocalizedError, let description = localized.errorDescription {
        return description
    }
    // `String(describing:)` already prefers a `CustomStringConvertible`
    // conformance when the error has one — which ArgumentParser's
    // ValidationError does — and falls back to reflection when it does not.
    // (A conditional cast to `any CustomStringConvertible` is emitted as
    // always-succeeding, so it cannot be the step that decides.)
    return String(describing: error)
}

// MARK: - package helpers

/// resolve a possibly-relative path against the cwd and require it to exist —
/// the package-inspector contract (`_resolve_target`), so "no results" stays
/// distinct from "invalid invocation" for every aggregate command.
public func resolveExistingPath(_ path: String) throws -> String {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
        throw ValidationError("path not found: \(path)")
    }
    return url.path
}

/// the `Package.swift` for a target path — the path itself when it is a
/// directory, else the containing directory's package.  mirrors the
/// package-inspector contract, so a path may name either the package or any
/// file inside it.
public func packageFileURL(for path: String) -> URL {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
    if exists && isDir.boolValue {
        return url.appendingPathComponent("Package.swift")
    }
    return url.deletingLastPathComponent().appendingPathComponent("Package.swift")
}

/// run `swift package <args>` inside `directory` and decode the JSON it prints.
///
/// throws with a message suitable for an `{ok: false, error: …}` payload when
/// the toolchain is missing, the command times out, it exits non-zero, or its
/// output is not JSON — the caller never has to invent a reason.
public func runSwiftPackageJSON(
    _ args: [String],
    in directory: String,
    timeoutSeconds: Int = 120
) async throws -> Any {
    let outcome: SubprocessOutcome
    do {
        outcome = try await Subprocess.capture(
            "/usr/bin/env",
            ["swift", "package"] + args,
            workingDirectory: directory,
            timeout: .seconds(timeoutSeconds)
        )
    } catch SubprocessError.timedOut {
        throw UsageError("swift package \(args.joined(separator: " ")) timed out after \(timeoutSeconds)s")
    } catch {
        throw UsageError("swift package \(args.joined(separator: " ")) failed to launch: \(error)")
    }
    guard outcome.exitCode == 0 else {
        let message = outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        throw UsageError(message.isEmpty ? "swift package \(args.first ?? "") exited \(outcome.exitCode)" : message)
    }
    do {
        return try JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8))
    } catch {
        throw UsageError("failed to parse swift package \(args.first ?? "") output: \(error)")
    }
}
