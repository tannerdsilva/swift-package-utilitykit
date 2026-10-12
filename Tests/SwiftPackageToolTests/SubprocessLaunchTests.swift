import Foundation
import Testing
import SubprocessCore

extension SwiftPackageToolTestsRoot {

    /// ``Subprocess/capture`` must fail a bad path by THROWING, not by hanging.
    ///
    /// this is the regression net for the pre-flight check: handing a
    /// non-executable path to the launch machinery leaves `run()` awaiting a
    /// child that was never created, and it never returns. the `.timeLimit` is
    /// the safety net — a reintroduced hang fails here in a minute instead of
    /// stalling the whole run with no output.
    @Suite("subprocess launch recovery", .timeLimit(.minutes(1)))
    struct SubprocessLaunchTests {

        @Test("a missing executable throws instead of hanging")
        func missingExecutableThrows() async throws {
            let error = await #expect(throws: SubprocessError.self) {
                _ = try await Subprocess.capture("/nonexistent/binary", ["--help"])
            }
            #expect(error == .notExecutable("/nonexistent/binary"), "\(String(describing: error))")
        }

        @Test("a failed launch does not wedge later spawns")
        func failedLaunchDoesNotWedgeLaterSpawns() async throws {
            await #expect(throws: SubprocessError.self) {
                _ = try await Subprocess.capture("/nonexistent/binary", ["--help"])
            }
            let outcome = try await Subprocess.capture("/bin/echo", ["ok"])
            #expect(outcome.stdout == "ok\n", "\(outcome.stdout)")
        }
    }
}