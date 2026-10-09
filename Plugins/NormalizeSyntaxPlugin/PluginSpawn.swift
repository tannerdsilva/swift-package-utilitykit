import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// runs the helper tool behind a command plugin.
///
/// this exists instead of the package's shared spawn path because SwiftPM
/// refuses to let a plugin target link a library from another package
/// (`plugin 'X' cannot depend on 'Y' of type 'library'` — verified), so
/// `SwiftSlash` is not reachable from here. `posix_spawn` is what is left, and
/// it is also what the production harnesses and this package's own plugin tests
/// use.
///
/// the child inherits this process's stdio, so the tool's output streams
/// straight through to whoever ran the plugin, and inherits its environment, so
/// the tool resolves paths the same way the plugin does.
enum PluginSpawn {

    /// runs `executable` to completion and returns its exit status.
    ///
    /// `128 + signal` is returned when the child was killed by a signal, matching
    /// the convention used by the rest of the package.
    ///
    /// the wait is blocking, which is correct here: this is called from the
    /// plugin's synchronous entry point, not from a Swift concurrency context, so
    /// no cooperative thread is held. the child is the only work in flight.
    static func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { for case let pointer? in argv { free(pointer) } }

        var envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment
            .map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer { for case let pointer? in envp { free(pointer) } }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, nil, nil, argv, envp)
        guard spawned == 0 else {
            throw PluginSpawnError.launch(code: spawned)
        }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            guard errno == EINTR else {
                throw PluginSpawnError.wait(code: errno)
            }
        }
        return (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
    }
}

/// a failure to launch or reap the helper tool.
enum PluginSpawnError: Error, CustomStringConvertible {
    case launch(code: Int32)
    case wait(code: Int32)

    var description: String {
        switch self {
        case .launch(let code):
            return "posix_spawn failed: \(String(cString: strerror(code)))"
        case .wait(let code):
            return "waitpid failed: \(String(cString: strerror(code)))"
        }
    }
}