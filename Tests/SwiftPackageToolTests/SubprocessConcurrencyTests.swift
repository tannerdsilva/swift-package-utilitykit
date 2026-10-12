import Foundation
import Testing
import SubprocessCore

extension SwiftPackageToolTestsRoot {

    /// pins the contract that lets ``Subprocess/capture`` carry no spawn gate of
    /// its own: swift-slash serializes every launch internally (its `launch` runs
    /// on the `SwiftSlashGlobalSerialization` global actor, which admits one child
    /// at a time) and dispatches each child's io through one shared event trigger
    /// onto async tasks. a concurrent `capture` is therefore just another launch
    /// queued behind that actor — safe, not a race.
    ///
    /// the `.timeLimit` is not decoration: if a future change makes overlapping
    /// launches wedge, this fails in a minute instead of hanging the run.
    @Suite("subprocess concurrency", .timeLimit(.minutes(1)))
    struct SubprocessConcurrencyTests {

        @Test("eight overlapping captures each return their own output")
        func overlappingCapturesDoNotDeadlock() async throws {
            let outputs = try await withThrowingTaskGroup(of: String.self) { group in
                for n in 1...8 {
                    group.addTask {
                        try await Subprocess.capture(
                            "/bin/sh", ["-c", "printf tag-\(n)"]
                        ).stdout
                    }
                }
                var seen: [String] = []
                for try await out in group { seen.append(out) }
                return seen
            }
            #expect(outputs.count == 8)
            #expect(Set(outputs) == Set((1...8).map { "tag-\($0)" }))
        }
    }
}