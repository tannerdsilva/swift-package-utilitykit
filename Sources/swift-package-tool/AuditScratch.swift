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

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// the audit-scratch contract, shared by `build --isolated`, `clean --audit`
/// and the inspector.
///
/// an isolated run compiles into a fresh, empty dir under
/// `<pkg>/.build/swift-package-audit/run-*` that the run removes when it
/// finishes.  consequences, all deliberate:
///
/// - the verdict always reflects the **current source** (no incremental state
///   that could be corrupt or out of alignment),
/// - the tool keeps **no persistent build state**, and
/// - the package's real `.build` products are **never touched**.
///
/// only a crashed run leaves residue; `clean --audit` sweeps it once it is
/// older than ``staleRunAgeSeconds`` (a live concurrent audit never sits idle
/// that long).
enum AuditScratch {
    /// run dirs older than this are abandoned and swept by `clean --audit`.
    static let staleRunAgeSeconds: TimeInterval = 3600

    /// `<pkg>/.build/swift-package-audit`
    static func root(packageDir: String) -> String {
        (packageDir as NSString).appendingPathComponent(".build/swift-package-audit")
    }

    /// create a fresh, empty run dir under the audit root.  the caller owns it
    /// and must remove it when the run finishes.
    static func create(packageDir: String) throws -> String {
        let auditRoot = root(packageDir: packageDir)
        try FileManager.default.createDirectory(
            atPath: auditRoot, withIntermediateDirectories: true
        )
        let fm = FileManager.default
        for _ in 0..<16 {
            let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased()
            let candidate = (auditRoot as NSString).appendingPathComponent("run-" + suffix)
            do {
                try fm.createDirectory(
                    atPath: candidate, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                return candidate
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch {
                throw UsageError("cannot create audit scratch under \(auditRoot): \(error)")
            }
        }
        throw UsageError("cannot create a unique audit scratch under \(auditRoot)")
    }

    /// remove a finished run's scratch, then the audit root and `.build` **if
    /// they are empty** — a live run's scratch or a real build product is
    /// never deleted (rmdir semantics, not recursive removal).
    static func remove(runDirectory: String, packageDir: String) {
        try? FileManager.default.removeItem(atPath: runDirectory)
        removeEmptyDirectory(root(packageDir: packageDir))
        removeEmptyDirectory((packageDir as NSString).appendingPathComponent(".build"))
    }

    /// sweep run dirs older than ``staleRunAgeSeconds`` under the audit root,
    /// then the audit root itself if it is now empty.  returns the number of
    /// run dirs removed.
    static func sweepStaleRuns(packageDir: String) -> Int {
        let auditRoot = root(packageDir: packageDir)
        let fm = FileManager.default
        var removed = 0
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: auditRoot, isDirectory: &isDir), isDir.boolValue {
            let entries = (try? fm.contentsOfDirectory(atPath: auditRoot)) ?? []
            let now = Date()
            for entry in entries {
                let full = (auditRoot as NSString).appendingPathComponent(entry)
                var entryIsDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &entryIsDir), entryIsDir.boolValue else { continue }
                guard let attributes = try? fm.attributesOfItem(atPath: full),
                      let modified = attributes[.modificationDate] as? Date else { continue }
                if now.timeIntervalSince(modified) > staleRunAgeSeconds {
                    try? fm.removeItem(atPath: full)
                    removed += 1
                }
            }
            removeEmptyDirectory(auditRoot)
        }
        return removed
    }

    /// remove an empty directory (never recursive); a non-empty directory is
    /// left exactly as it is.  `removeItem` would be wrong here — it deletes a
    /// live concurrent run's scratch and real build products along with it.
    private static func removeEmptyDirectory(_ path: String) {
        _ = rmdir(path)
    }
}