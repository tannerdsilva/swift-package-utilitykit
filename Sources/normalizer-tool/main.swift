import Foundation
import NormalizerCore

/// command-line entry point invoked by the NormalizeSyntax plugin.
///
/// the plugin discovers source files and passes them here as arguments, along
/// with normalization options, so all core logic stays in the unit-tested
/// `NormalizerCore` library rather than in plugin code (which SPM cannot
/// unit-test directly).
///
/// argument protocol (parsed leniently):
///   --file <path>            a source file to normalize (repeatable).
///   --lf | --crlf            line ending target (default: lf).
///   --keep-trailing-whitespace
///   --no-final-newline
///   --collapse-blank-lines
///   --tabs-to-spaces <n>
///   --spaces-to-tabs <n>
///   --preserve-indentation
///   --dry-run                report without writing.
///
/// exit status 0 on success. prints one line per changed file:
///   "changed <path>" or "unchanged <path>".
struct NormalizerTool {

	let version = "0.1.0"

	var options = NormalizationOptions.standard
	var dryRun = false
	var files: [String] = []
	var showVersion = false

	mutating func parse(_ args: [String]) throws {
		var i = 0
		while i < args.count {
			let a = args[i]
			switch a {
			case "--version", "-v":
				showVersion = true
			case "--file":
				i += 1
				guard i < args.count else { throw UsageError("--file requires a path") }
				files.append(args[i])
			case "--lf": options.lineEnding = .lf
			case "--crlf": options.lineEnding = .crlf
			case "--keep-trailing-whitespace": options.stripTrailingWhitespace = false
			case "--no-final-newline": options.ensureFinalNewline = false
			case "--collapse-blank-lines": options.collapseBlankLines = true
			case "--preserve-indentation": options.indentation = .preserve
			case "--minify": options = .minified
			case "--dry-run": dryRun = true
			case "--tabs-to-spaces":
				i += 1
				guard i < args.count, let n = Int(args[i]), n >= 1 else {
					throw UsageError("--tabs-to-spaces requires a positive integer")
				}
				options.indentation = .tabsToSpaces(n)
			case "--spaces-to-tabs":
				i += 1
				guard i < args.count, let n = Int(args[i]), n >= 1 else {
					throw UsageError("--spaces-to-tabs requires a positive integer")
				}
				options.indentation = .spacesToTabs(n)
			default:
				throw UsageError("Unknown argument: \(a)")
			}
			i += 1
		}
	}

	func run() throws {
		if showVersion {
			print("normalizer-tool \(version)")
			return
		}
		var failures = 0
		var changed = 0
		for path in files {
			let url = URL(fileURLWithPath: path)
			do {
				let original = try String(contentsOf: url, encoding: .utf8)
				let normalized = Normalizer.normalize(original, options: options)
				if normalized != original {
					changed += 1
					if !dryRun {
						try normalized.write(to: url, atomically: true, encoding: .utf8)
					}
					print("changed \(path)")
				} else {
					print("unchanged \(path)")
				}
			} catch {
				failures += 1
				FileHandle.standardError.write(Data("error \(path): \(error.localizedDescription)\n".utf8))
			}
		}
		print("summary \(changed) changed, \(failures) failed, of \(files.count) files")
	}
}

struct UsageError: Error, CustomStringConvertible {
	let message: String
	init(_ message: String) { self.message = message }
	var description: String { message }
}

var tool = NormalizerTool()
do {
	try tool.parse(Array(CommandLine.arguments.dropFirst()))
	try tool.run()
} catch {
	FileHandle.standardError.write(Data("fatal: \(error.localizedDescription)\n".utf8))
	exit(1)
}
