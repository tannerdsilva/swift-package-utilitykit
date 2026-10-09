import SwiftSlash
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// the outcome of a subprocess that ran to completion.
public struct SubprocessOutcome: Sendable {
    /// the child's exit status. a child killed by a signal reports `128 + signal`,
    /// following the shell convention.
    public let exitCode: Int32
    /// everything the child wrote to stdout.
    public let stdout: String
    /// everything the child wrote to stderr.
    public let stderr: String

    /// true when the child exited with status 0.
    public var succeeded: Bool { exitCode == 0 }

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// a subprocess that did not run to completion.
public enum SubprocessError: Error, Equatable, CustomStringConvertible {
    /// the child exceeded the caller's timeout. it has been signalled and reaped,
    /// so nothing is left running when this is thrown.
    case timedOut

    public var description: String { "subprocess timed out" }
}

/// runs a child process and captures its output.
///
/// this is the package's only spawn path: swift-slash owns the launch, the
/// concurrent stdout/stderr drain, and the reap. no call site here touches
/// pipes, file handles, or dispatch, and a child can never be left running —
/// the timeout and task-cancellation paths both signal the child's process
/// group and reap it before returning.
public enum Subprocess {

    /// runs `executable` to completion and returns its captured output.
    ///
    /// - Parameters:
    ///   - executable: absolute path to the executable to run.
    ///   - arguments: the arguments to pass to it.
    ///   - workingDirectory: the child's working directory; the current one when nil.
    ///   - environment: the child's complete environment; the current process's
    ///     when nil. this is passed whole, not merged.
    ///   - stdin: a payload written to the child's stdin, which is then closed so
    ///     the child observes end-of-file. when nil the child's stdin is
    ///     `/dev/null`, so a child that reads stdin sees end-of-file immediately
    ///     instead of blocking on a stream nobody will write.
    ///   - timeout: when given, the child is signalled and reaped after this
    ///     duration and ``SubprocessError/timedOut`` is thrown.
    ///   - cancellationSignal: the signal sent to the child's process group when
    ///     the calling task is cancelled or the timeout elapses. the default is
    ///     swift-slash's ``SwiftSlash/ChildProcess/defaultCancellationSignal``.
    /// - Throws: ``SubprocessError/timedOut`` on timeout, `CancellationError` when
    ///   the calling task is cancelled, or a launch/reap error from swift-slash.
    public static func capture(
        _ executable: String,
        _ arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        stdin: String? = nil,
        timeout: Duration? = nil,
        cancellationSignal: Int32 = ChildProcess.defaultCancellationSignal
    ) async throws -> SubprocessOutcome {
        let command = Command(
            absolutePath: Path(executable),
            arguments: arguments,
            environment: environment ?? CurrentEnvironment.environmentVariables(),
            workingDirectory: workingDirectory.map { Path($0) } ?? CurrentEnvironment.workingDirectory()
        )
        let process = ChildProcess(command, dataChannels: channels(readingStdin: stdin != nil))

        // the drains must be in flight before `run()` launches the child: they
        // observe the streams that run()'s io loops fill.
        async let out = drain(process.stdout)
        async let err = drain(process.stderr)

        if let stdin {
            // the payload is pre-loaded before launch: `yield` does not wait to
            // be flushed, and the loop that flushes stdin to the child only
            // starts inside `run()`, so awaiting a write here would never
            // return. closing the channel is what gives the child end-of-file
            // once the payload has been written.
            try? process.stdin.yield(Array(stdin.utf8))
            process.stdin.closeDataChannel()
        }

        let exit: ChildProcess.Exit
        do {
            exit = try await run(process, timeout: timeout, cancellationSignal: cancellationSignal)
        } catch {
            // the child has already been signalled and reaped inside `run`; the
            // drains observe the end of their streams once run's io loops wind
            // down, so they are awaited here rather than abandoned.
            _ = await out
            _ = await err
            throw error
        }
        return SubprocessOutcome(
            exitCode: exitCode(of: exit),
            stdout: String(decoding: await out, as: UTF8.self),
            stderr: String(decoding: await err, as: UTF8.self)
        )
    }

    // MARK: - internals

    /// stdout and stderr run with the line parser disabled (`separator: []`), so
    /// each delivery is exactly the bytes the child wrote — no separator is
    /// consumed and no trailing partial line is ambiguous. stdin is a pipe only
    /// when the caller has a payload for it, and `/dev/null` otherwise.
    private static func channels(readingStdin: Bool) -> [Int32: DataChannel] {
        [
            STDOUT_FILENO: .write(.toParentProcess(stream: .init(), separator: [])),
            STDERR_FILENO: .write(.toParentProcess(stream: .init(), separator: [])),
            STDIN_FILENO: readingStdin ? .read(.fromParentProcess(stream: .init())) : .read(.fromNull),
        ]
    }

    /// collects the child's output verbatim.
    /// swift-slash delivers `[[UInt8]]` per read — one or more slices per delivery.
    private static func drain(_ stream: DataChannel.ChildWrite.ParentRead) async -> [UInt8] {
        var bytes: [UInt8] = []
        for await chunk in stream {
            for slice in chunk {
                bytes.append(contentsOf: slice)
            }
        }
        return bytes
    }

    /// the child's status as a shell-style exit code.
    private static func exitCode(of exit: ChildProcess.Exit) -> Int32 {
        switch exit {
        case .code(let code): return code
        case .signal(let signal): return 128 + signal
        }
    }

    /// runs the child, optionally racing it against a timeout.
    private static func run(
        _ process: ChildProcess,
        timeout: Duration?,
        cancellationSignal: Int32
    ) async throws -> ChildProcess.Exit {
        guard let timeout else {
            return try await process.run(cancellationSignal: cancellationSignal)
        }

        /// which side of the race produced a result.
        enum Race: Sendable {
            case child(ChildProcess.Exit)
            case timeout
        }

        let outcome = try await withThrowingTaskGroup(of: Race.self) { group in
            group.addTask {
                .child(try await process.run(cancellationSignal: cancellationSignal))
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return .timeout
            }
            // whichever side finishes first, the other is cancelled: on timeout
            // this cancels the run, which signals the child's process group and
            // reaps it; on child completion it retires the sleep.
            defer { group.cancelAll() }
            return try await group.next() ?? .timeout
        }

        switch outcome {
        case .child(let exit): return exit
        case .timeout: throw SubprocessError.timedOut
        }
    }
}