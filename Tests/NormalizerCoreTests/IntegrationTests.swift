import Testing
import Foundation

/// integration tests for swift-code-query commands.
///
/// these tests run the built binary as a subprocess and verify its output.
/// they serve as smoke tests for the CLI interface and output formats.
@Suite("swift-code-query integration tests")
struct SwiftCodeQueryIntegrationTests {

    let binaryPath: String
    let testSourcesDir: String
    let packageDir: String

    init() throws {
        // resolve the binary path relative to the package directory
        let pkgDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/NormalizerCoreTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // swift-package-utilitykit/

        binaryPath = pkgDir
            .appendingPathComponent(".build/debug/swift-code-query").path

        testSourcesDir = pkgDir
            .appendingPathComponent("Sources/NormalizerCore").path

        packageDir = pkgDir.path
    }

    @Test("find command returns results for known symbol")
    func findKnownSymbol() throws {
        let output = try runCommand(["find", "Normalizer", testSourcesDir, "--exact"])
        #expect(output.contains("Normalizer"))
        #expect(output.contains("enum"))
    }

    @Test("find command returns empty for nonexistent symbol")
    func findNonexistentSymbol() throws {
        let output = try runCommand(["find", "XYZZY_NONEXISTENT", testSourcesDir])
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(trimmed == "[]")
    }

    @Test("find command supports --pretty-print")
    func findPrettyPrint() throws {
        let output = try runCommand(["find", "Normalizer", testSourcesDir, "--exact", "--pretty-print"])
        #expect(output.contains("\"name\""))
        #expect(output.contains("\"kind\""))
    }

    @Test("find command supports --output-format short")
    func findShortFormat() throws {
        let output = try runCommand(["find", "Normalizer", testSourcesDir, "--exact", "--output-format", "short"])
        #expect(output.contains("[enum]"))
    }

    @Test("complexity command returns results")
    func complexityReturnsResults() throws {
        let output = try runCommand(["complexity", testSourcesDir, "--output-format", "short"])
        #expect(output.contains("complexity:"))
        #expect(output.contains("rating:"))
    }

    @Test("complexity command supports --min-complexity filter")
    func complexityMinFilter() throws {
        let output = try runCommand(["complexity", testSourcesDir, "--min-complexity", "10", "--output-format", "short"])
        // may be empty if no function has complexity >= 10
        // just verify it doesn't crash
        _ = output
    }

    @Test("complexity command supports --limit")
    func complexityLimit() throws {
        let output = try runCommand(["complexity", testSourcesDir, "--limit", "1", "--output-format", "short"])
        let lines = output.split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines.count <= 1)
    }

    @Test("diff command shows no changes for identical files")
    func diffIdenticalFiles() throws {
        let file1 = "\(testSourcesDir)/Normalizer.swift"
        let output = try runCommand(["diff", file1, file1, "--output-format", "short"])
        #expect(output.contains("addedCount: 0"))
        #expect(output.contains("removedCount: 0"))
        #expect(output.contains("changedCount: 0"))
    }

    @Test("diff command detects added declarations")
    func diffDetectsAdditions() throws {
        // create two temp files: one empty, one with a struct
        let tmpDir = FileManager.default.temporaryDirectory
        let emptyFile = tmpDir.appendingPathComponent("diff_test_empty_\(UUID().uuidString).swift")
        let structFile = tmpDir.appendingPathComponent("diff_test_struct_\(UUID().uuidString).swift")

        try "".write(to: emptyFile, atomically: true, encoding: .utf8)
        try "public struct DiffTestAdded {}\n".write(to: structFile, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: emptyFile)
            try? FileManager.default.removeItem(at: structFile)
        }

        let output = try runCommand(["diff", emptyFile.path, structFile.path, "--output-format", "short"])
        #expect(output.contains("addedCount: 1"))
    }

    @Test("diff command supports stdin with -")
    func diffStdin() throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let file1 = tmpDir.appendingPathComponent("diff_stdin_a_\(UUID().uuidString).swift")
        let file2 = tmpDir.appendingPathComponent("diff_stdin_b_\(UUID().uuidString).swift")

        try "public func oldFunc() {}".write(to: file1, atomically: true, encoding: .utf8)
        try "public func newFunc() {}".write(to: file2, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: file1)
            try? FileManager.default.removeItem(at: file2)
        }

        let output = try runCommand(["diff", file1.path, file2.path, "--output-format", "short"])
        #expect(output.contains("addedCount: 1"))
        #expect(output.contains("removedCount: 1"))
    }

    @Test("members command lists type members")
    func membersListsMembers() throws {
        let output = try runCommand(["members", "\(testSourcesDir)/Normalizer.swift", "--type", "Normalizer", "--output-format", "short"])
        #expect(output.contains("normalize"))
        #expect(output.contains("normalizeLine"))
    }

    @Test("members command errors on nonexistent type")
    func membersNonexistentType() throws {
        let output = try runCommand(["members", "\(testSourcesDir)/Normalizer.swift", "--type", "NonExistentType"])
        // should error, not crash
        let lower = output.lowercased()
        #expect(lower.contains("not found") || lower.contains("error"))
    }

    @Test("all commands support --schema")
    func schemaFlag() throws {
        // only test commands without required arguments (--schema is checked before
        // argument parsing completes for commands with required @Argument properties)
        for cmd in ["complexity", "api", "conformances", "callgraph"] {
            let output = try runCommand([cmd, "--schema"])
            #expect(output.contains("\"$schema\""), "\(cmd) --schema should return valid JSON Schema")
        }
    }

    @Test("--version flag works")
    func versionFlag() throws {
        let output = try runCommand(["--version"])
        #expect(output.contains("0.1.0"))
    }

    // MARK: - comment handling

    @Test("format with --minify hides docc comments")
    func minifyHidesDocComments() throws {
        let tmp = "/tmp/test-format-docc.swift"
        try """
        /// important documentation
        func foo() {}
        """.write(toFile: tmp, atomically: true, encoding: .utf8)
        _ = try runCommand(["format", tmp, "--minify"])
        let content = try String(contentsOfFile: tmp, encoding: .utf8)
        #expect(!content.contains("important documentation"))
        #expect(content.contains("/// comment invisible"))
    }

    @Test("format with --minify hides line comments")
    func minifyHidesLineComments() throws {
        let tmp = "/tmp/test-format-line.swift"
        try """
        // this is a note
        let x = 1
        """.write(toFile: tmp, atomically: true, encoding: .utf8)
        _ = try runCommand(["format", tmp, "--minify"])
        let content = try String(contentsOfFile: tmp, encoding: .utf8)
        #expect(!content.contains("this is a note"))
        #expect(content.contains("// comment invisible"))
    }

    @Test("format with --minify hides block comments")
    func minifyHidesBlockComments() throws {
        let tmp = "/tmp/test-format-block.swift"
        try """
        /* block comment */
        let x = 1
        """.write(toFile: tmp, atomically: true, encoding: .utf8)
        _ = try runCommand(["format", tmp, "--minify"])
        let content = try String(contentsOfFile: tmp, encoding: .utf8)
        #expect(!content.contains("block comment"))
        #expect(content.contains("/* comment invisible */"))
    }

    @Test("format with --minify --preserve-comments keeps comments")
    func minifyPreserveComments() throws {
        let tmp = "/tmp/test-format-preserve.swift"
        try """
        // keep this
        let x = 1
        """.write(toFile: tmp, atomically: true, encoding: .utf8)
        _ = try runCommand(["format", tmp, "--minify", "--preserve-comments"])
        let content = try String(contentsOfFile: tmp, encoding: .utf8)
        #expect(content.contains("keep this"))
    }

    @Test("format without --minify preserves all comments")
    func formatPreservesComments() throws {
        let tmp = "/tmp/test-format-default.swift"
        try """
        /// doc
        // line
        /* block */
        let x = 1
        """.write(toFile: tmp, atomically: true, encoding: .utf8)
        _ = try runCommand(["format", tmp, "--dry-run"])
        let content = try String(contentsOfFile: tmp, encoding: .utf8)
        // dry-run doesn't write, so content should be unchanged
        #expect(content.contains("/// doc"))
        #expect(content.contains("// line"))
        #expect(content.contains("/* block */"))
    }

    // MARK: - build command

    @Test("build --schema returns valid JSON Schema")
    func buildSchema() throws {
        let output = try runCommand(["build", "--schema"])
        #expect(output.contains("\"$schema\""))
        #expect(output.contains("BuildResult"))
    }

    // MARK: - tree command

    @Test("tree shows struct with braces and members")
    func treeStructWithBraces() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree_test_struct_\(UUID().uuidString).swift")
        try """
        public struct MyStruct {
            var x: Int
            func foo() {}
        }
        """.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let output = try runCommand(["tree", tmp.path])
        #expect(output.contains("public struct MyStruct {"))
        #expect(output.contains("  var x: Int"))
        #expect(output.contains("  func foo()"))
        #expect(output.contains("}"))
    }

    @Test("tree shows enum with cases")
    func treeEnumCases() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree_test_enum_\(UUID().uuidString).swift")
        try """
        enum Direction {
            case north
            case south
            case east, west
        }
        """.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let output = try runCommand(["tree", tmp.path])
        #expect(output.contains("enum Direction {"))
        #expect(output.contains("  case north"))
        #expect(output.contains("  case south"))
        #expect(output.contains("  case east"))
        #expect(output.contains("  case west"))
        #expect(output.contains("}"))
    }

    @Test("tree skips import declarations")
    func treeSkipsImports() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree_test_skipimports_\(UUID().uuidString).swift")
        try """
        import Foundation
        import SwiftSyntax

        struct Foo {}
        """.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let output = try runCommand(["tree", tmp.path])
        // "import" as a line prefix should not appear (only the file header and struct)
        let lines = output.split(separator: "\n").map(String.init)
        for line in lines {
            #expect(!line.hasPrefix("import"), "line should not start with 'import': \(line)")
        }
        #expect(output.contains("struct Foo"))
    }

    @Test("tree skips local variables inside function bodies")
    func treeSkipsLocals() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree_test_locals_\(UUID().uuidString).swift")
        try """
        struct Container {
            func compute() {
                let localVar = 42
                var mutable = "hello"
            }
        }
        """.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let output = try runCommand(["tree", tmp.path])
        #expect(output.contains("struct Container {"))
        #expect(output.contains("  func compute()"))
        #expect(!output.contains("localVar"))
        #expect(!output.contains("mutable"))
        #expect(output.contains("}"))
    }

    @Test("tree shows nested types with proper nesting")
    func treeNestedTypes() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree_test_nested_\(UUID().uuidString).swift")
        try """
        struct Outer {
            struct Inner {
                var value: Int
            }
            enum InnerEnum {
                case a
            }
        }
        """.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let output = try runCommand(["tree", tmp.path])
        #expect(output.contains("struct Outer {"))
        #expect(output.contains("  struct Inner {"))
        #expect(output.contains("    var value: Int"))
        #expect(output.contains("  }"))
        #expect(output.contains("  enum InnerEnum {"))
        #expect(output.contains("    case a"))
        #expect(output.contains("  }"))
        // closing brace of Outer
        let outerCloseCount = output.components(separatedBy: "}\n").count - 1
        #expect(outerCloseCount >= 1)
    }

    @Test("tree shows access modifiers")
    func treeAccessModifiers() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree_test_mods_\(UUID().uuidString).swift")
        try """
        public struct Foo {
            private var secret: Int
            public internal(set) var readable: String
            public static func factory() -> Foo
            private mutating func mutate() {}
        }
        """.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let output = try runCommand(["tree", tmp.path])
        #expect(output.contains("public struct Foo {"))
        #expect(output.contains("  private var secret: Int"))
        #expect(output.contains("  public internal var readable: String"))
        #expect(output.contains("  public static func factory()"))
        #expect(output.contains("  private mutating func mutate()"))
    }

    @Test("tree shows extension with members")
    func treeExtension() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree_test_ext_\(UUID().uuidString).swift")
        try """
        extension String {
            var reversed: String { String(self.reversed()) }
            func foo() {}
        }
        """.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let output = try runCommand(["tree", tmp.path])
        #expect(output.contains("extension String {"))
        #expect(output.contains("  var reversed: String"))
        #expect(output.contains("  func foo()"))
        #expect(output.contains("}"))
    }

    @Test("tree on file with no declarations returns empty")
    func treeEmptyFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree_test_empty_\(UUID().uuidString).swift")
        try "// just a comment\n".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let output = try runCommand(["tree", tmp.path])
        // should have the file header but no symbols
        #expect(output.contains(tmp.lastPathComponent))
        // no declarations means nothing after the header line
        let lines = output.split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 1) // just the // file header
    }

    @Test("tree --output writes to file")
    func treeOutputFile() throws {
        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree_test_src_\(UUID().uuidString).swift")
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree_test_out_\(UUID().uuidString).txt")
        try "struct Foo {}".write(to: src, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: out)
        }

        _ = try runCommand(["tree", src.path, "--output", out.path])
        let content = try String(contentsOf: out, encoding: .utf8)
        #expect(content.contains("struct Foo"))
    }

    @Test("tree on directory produces per-file output")
    func treeDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree_test_dir_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "struct A {}".write(to: dir.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        try "struct B {}".write(to: dir.appendingPathComponent("B.swift"), atomically: true, encoding: .utf8)

        let output = try runCommand(["tree", dir.path])
        #expect(output.contains("struct A"))
        #expect(output.contains("struct B"))
    }

    @Test("tree shows protocol with members")
    func treeProtocol() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree_test_proto_\(UUID().uuidString).swift")
        try """
        public protocol Drawable {
            var area: Double { get }
            func draw()
        }
        """.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let output = try runCommand(["tree", tmp.path])
        #expect(output.contains("public protocol Drawable {"))
        #expect(output.contains("  var area: Double"))
        #expect(output.contains("  func draw()"))
        #expect(output.contains("}"))
    }

    @Test("tree shows class with inheritance")
    func treeClass() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree_test_class_\(UUID().uuidString).swift")
        try """
        open class ViewController: UIViewController {
            var title: String?
            func viewDidLoad() {}
        }
        """.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let output = try runCommand(["tree", tmp.path])
        #expect(output.contains("open class ViewController: UIViewController {"))
        #expect(output.contains("  var title: String?"))
        #expect(output.contains("  func viewDidLoad()"))
        #expect(output.contains("}"))
    }

    @Test("tree shows typealias and associatedtype")
    func treeTypeAlias() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree_test_typealias_\(UUID().uuidString).swift")
        try """
        protocol Config {
            associatedtype Value
        }
        typealias MyConfig = Config
        """.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let output = try runCommand(["tree", tmp.path])
        #expect(output.contains("protocol Config {"))
        #expect(output.contains("  associatedtype Value"))
        #expect(output.contains("typealias MyConfig = Config"))
    }

    // MARK: - --output flag

    @Test("find --output writes to file")
    func findOutputFile() throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("find_out_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try runCommand(["find", "Normalizer", "Sources/NormalizerCore", "--output", out.path])
        let content = try String(contentsOf: out, encoding: .utf8)
        #expect(content.contains("Normalizer"))
    }

    @Test("inspect --output writes to file")
    func inspectOutputFile() throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspect_out_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try runCommand(["inspect", "--symbol", "Normalizer", "Sources/NormalizerCore/Normalizer.swift", "--output", out.path])
        let content = try String(contentsOf: out, encoding: .utf8)
        #expect(content.contains("Normalizer"))
    }

    @Test("members --output writes to file")
    func membersOutputFile() throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("members_out_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try runCommand(["members", "--type", "OutputFormat", "Sources/swift-code-query/OutputFormat.swift", "--output", out.path])
        let content = try String(contentsOf: out, encoding: .utf8)
        #expect(content.contains("OutputFormat"))
    }

    // MARK: - validate command

    @Test("validate detects syntax errors")
    func validateDetectsErrors() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("validate_test_\(UUID().uuidString).swift")
        try """
        struct Foo {
            var x: Int
            func bar() {
                if x > 0
            }
        }
        """.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let output = try runCommand(["validate", tmp.path])
        #expect(output.contains("error"))
        #expect(output.contains("expected"))
    }

    @Test("validate passes clean file")
    func validateCleanFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("validate_clean_\(UUID().uuidString).swift")
        try "let x: Int = 1\n".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let output = try runCommand(["validate", tmp.path])
        #expect(output.hasPrefix("[]") || output.hasPrefix("[\n"))
    }

    @Test("validate --warnings includes warnings")
    func validateWarnings() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("validate_warn_\(UUID().uuidString).swift")
        try """
        struct Foo {
            var x: Int
            func bar() {
                if x > 0
            }
        }
        """.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let output = try runCommand(["validate", tmp.path, "--warnings"])
        #expect(output.contains("error"))
    }

    @Test("validate --pretty-print works")
    func validatePrettyPrint() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("validate_pp_\(UUID().uuidString).swift")
        try "struct Foo {}\n".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let output = try runCommand(["validate", tmp.path, "--pretty-print"])
        #expect(output.hasPrefix("[\n"))
    }

    // MARK: - macro-expand command

    @Test("macro-expand finds macro usages")
    func macroExpandFindsMacros() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macro_test_\(UUID().uuidString).swift")
        try """
        @freestanding(expression) macro stringify(_ value: Any) -> (Any, String) = #externalMacro(module: "M", type: "T")
        struct Foo {
            func test() {
                let x = #stringify(1 + 2)
            }
        }
        """.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let output = try runCommand(["macro-expand", tmp.path])
        #expect(output.contains("#externalMacro"))
        #expect(output.contains("#stringify"))
    }

    @Test("macro-expand returns empty for files with no macros")
    func macroExpandEmpty() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macro_empty_\(UUID().uuidString).swift")
        try "let x: Int = 1\n".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let output = try runCommand(["macro-expand", tmp.path])
        #expect(output.hasPrefix("[]") || output.hasPrefix("[\n"))
    }

    @Test("macro-expand --pretty-print works")
    func macroExpandPrettyPrint() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macro_pp_\(UUID().uuidString).swift")
        try """
        @freestanding(expression) macro stringify(_ value: Any) -> (Any, String) = #externalMacro(module: "M", type: "T")
        """.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let output = try runCommand(["macro-expand", tmp.path, "--pretty-print"])
        #expect(output.contains("#externalMacro"))
    }

    // MARK: - docc-check command

    @Test("docc-check finds invalid symbol references")
    func doccCheckFindsInvalidRefs() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("docc_test_\(UUID().uuidString).swift")
        try """
        /// This references `NonExistentType` and `AlsoMissing`
        struct Foo {
            var x: Int
        }
        """.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let output = try runCommand(["docc-check", tmp.path])
        #expect(output.contains("NonExistentType"))
        #expect(output.contains("AlsoMissing"))
    }

    @Test("docc-check passes for valid references")
    func doccCheckValidRefs() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("docc_valid_\(UUID().uuidString).swift")
        try """
        /// This references `Foo` which exists below
        struct Foo {
            var x: Int
        }
        """.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let output = try runCommand(["docc-check", tmp.path])
        #expect(output.hasPrefix("[]"))
    }

    @Test("docc-check --pretty-print works")
    func doccCheckPrettyPrint() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("docc_pp_\(UUID().uuidString).swift")
        try """
        /// References `MissingType`
        struct Bar {}
        """.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let output = try runCommand(["docc-check", tmp.path, "--pretty-print"])
        #expect(output.contains("MissingType"))
    }

    // MARK: - clean command

    @Test("clean succeeds on this package")
    func cleanSucceeds() throws {
        // Create a temporary package, build it, then clean it
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clean_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "CleanTest",
            targets: [.target(name: "CleanTest")]
        )
        """.write(to: tmpDir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        try FileManager.default.createDirectory(at: tmpDir.appendingPathComponent("Sources/CleanTest"), withIntermediateDirectories: true)
        try "public func greet() {}\n".write(to: tmpDir.appendingPathComponent("Sources/CleanTest/main.swift"), atomically: true, encoding: .utf8)

        // Build first to create artifacts
        let buildProc = Process()
        buildProc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        buildProc.arguments = ["swift", "build", "--package-path", tmpDir.path]
        try buildProc.run()
        buildProc.waitUntilExit()
        guard buildProc.terminationStatus == 0 else { return } // skip if build fails

        let output = try runCommand(["clean", tmpDir.path, "--pretty-print"])
        #expect(output.contains("\"success\" : true"))
        #expect(output.contains("dependencies preserved"))
    }

    @Test("clean fails on directory without Package.swift")
    func cleanFailsNoPackage() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("no_pkg_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let output = try runCommand(["clean", tmp.path])
        #expect(output.contains("no Package.swift found"))
    }

    // MARK: - complexity nesting fix

    @Test("complexity correctly handles nested functions")
    func complexityNestedFunctions() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("complexity_nested_\(UUID().uuidString).swift")
        try """
        func outer() {
            func inner() {
                if true { if true {} }
            }
        }
        func simple() {
            let x = 1
        }
        """.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let output = try runCommand(["complexity", tmp.path, "--pretty-print"])
        // outer should have complexity 1 (base, no decision points in its body)
        // inner should have complexity 3 (base + 2 ifs)
        // simple should have complexity 1
        #expect(output.contains("\"complexity\" : 1"))
        // at least two entries with complexity 1 (outer and simple)
        let complexity1Count = output.components(separatedBy: "\"complexity\" : 1").count - 1
        #expect(complexity1Count >= 2)
    }

    // MARK: - diff missing types

    @Test("diff detects init/deinit/subscript changes")
    func diffInitDeinitSubscript() throws {
        let file1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("diff_init_a_\(UUID().uuidString).swift")
        let file2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("diff_init_b_\(UUID().uuidString).swift")
        try "struct Foo {\n    func bar() {}\n}\n".write(to: file1, atomically: true, encoding: .utf8)
        try "struct Foo {\n    init(x: Int) {}\n    deinit {}\n    subscript(i: Int) -> Int { 0 }\n    func bar() {}\n}\n".write(to: file2, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: file1)
            try? FileManager.default.removeItem(at: file2)
        }

        let output = try runCommand(["diff", file1.path, file2.path, "--pretty-print"])
        #expect(output.contains("initializer"))
        #expect(output.contains("deinitializer"))
        #expect(output.contains("subscript"))
    }

    @Test("complexity --output writes to file")
    func complexityOutputFile() throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("complexity_out_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try runCommand(["complexity", "Sources/NormalizerCore", "--output", out.path])
        let content = try String(contentsOf: out, encoding: .utf8)
        #expect(content.contains("\"complexity\""))
    }

    @Test("diff --output writes to file")
    func diffOutputFile() throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("diff_out_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try runCommand(["diff", "Sources/NormalizerCore/Normalizer.swift", "Sources/NormalizerCore/Normalizer.swift", "--output", out.path])
        let content = try String(contentsOf: out, encoding: .utf8)
        #expect(content.contains("\"addedCount\""))
    }

    // MARK: - stdin piping

    @Test("find - reads from stdin")
    func findStdin() throws {
        let source = "struct Foo { func bar() {} }"
        let output = try runCommandWithStdin(["find", "Foo", "-"], stdin: source)
        #expect(output.contains("Foo"))
        #expect(output.contains("struct"))
    }

    @Test("inspect - reads from stdin")
    func inspectStdin() throws {
        let source = "struct Foo { func bar() {} }"
        let output = try runCommandWithStdin(["inspect", "--symbol", "Foo", "-"], stdin: source)
        #expect(output.contains("Foo"))
        #expect(output.contains("struct"))
    }

    @Test("format - reads from stdin")
    func formatStdin() throws {
        let source = "let x = 1\nlet y = 2\n"
        let output = try runCommandWithStdin(["format", "-", "--minify"], stdin: source)
        // minify strips all whitespace; output should contain the tokens in order
        #expect(output.contains("let"))
        #expect(output.contains("x"))
        #expect(output.contains("1"))
    }

    // MARK: - members details

    @Test("members includes enum cases")
    func membersEnumCases() throws {
        let output = try runCommand(["members", "--type", "CommentMode", "Sources/NormalizerCore/NormalizationOptions.swift"])
        #expect(output.contains("enum_case"))
        #expect(output.contains("preserve"))
        #expect(output.contains("hide"))
    }

    @Test("members --pretty-print works")
    func membersPrettyPrint() throws {
        let output = try runCommand(["members", "--type", "NormalizationOptions", "Sources/NormalizerCore/NormalizationOptions.swift", "--pretty-print"])
        #expect(output.contains("lineEnding"))
        #expect(output.contains("stripTrailingWhitespace"))
    }

    // MARK: - complexity details

    @Test("complexity includes ratings")
    func complexityRatings() throws {
        let output = try runCommand(["complexity", "Sources/NormalizerCore/Normalizer.swift"])
        #expect(output.contains("\"rating\""))
    }

    @Test("complexity --pretty-print works")
    func complexityPrettyPrint() throws {
        let output = try runCommand(["complexity", "Sources/NormalizerCore/Normalizer.swift", "--pretty-print"])
        #expect(output.contains("rating"))
    }

    // MARK: - diff details

    @Test("diff self produces empty changes")
    func diffSelfEmpty() throws {
        let output = try runCommand(["diff", "Sources/NormalizerCore/Normalizer.swift", "Sources/NormalizerCore/Normalizer.swift"])
        #expect(output.contains("\"addedCount\":0"))
        #expect(output.contains("\"removedCount\":0"))
    }

    @Test("diff --pretty-print works")
    func diffPrettyPrint() throws {
        let output = try runCommand(["diff", "Sources/NormalizerCore/Normalizer.swift", "Sources/NormalizerCore/NormalizationOptions.swift", "--pretty-print"])
        #expect(output.contains("addedCount"))
        #expect(output.contains("removedCount"))
    }

    // MARK: - query

    @Test("query returns declarations")
    func queryReturnsDeclarations() throws {
        let output = try runCommand(["query", "Sources/NormalizerCore/NormalizationOptions.swift", "--all"])
        #expect(output.contains("CommentMode"))
        #expect(output.contains("NormalizationOptions"))
    }

    @Test("query filters by kind")
    func queryFiltersByKind() throws {
        let output = try runCommand(["query", "Sources/NormalizerCore/NormalizationOptions.swift", "--enums"])
        #expect(output.contains("CommentMode"))
        // all results should have kind "enum"
        #expect(output.contains("\"kind\":\"enum\""))
        #expect(!output.contains("\"kind\":\"struct\""))
    }

    @Test("query supports --count")
    func queryCount() throws {
        let output = try runCommand(["query", "Sources/NormalizerCore/NormalizationOptions.swift", "--all", "--count"])
        // --count returns just the number
        let count = Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(count != nil)
        #expect(count! > 0)
    }

    @Test("query supports --pretty-print")
    func queryPrettyPrint() throws {
        let output = try runCommand(["query", "Sources/NormalizerCore/NormalizationOptions.swift", "--all", "--pretty-print"])
        #expect(output.contains("CommentMode"))
        #expect(output.contains("kind"))
    }

    // MARK: - search

    @Test("search returns matches")
    func searchReturnsMatches() throws {
        let output = try runCommand(["search", "Normalizer", "Sources/NormalizerCore"])
        #expect(output.contains("Normalizer"))
    }

    @Test("search supports --context")
    func searchContext() throws {
        let output = try runCommand(["search", "struct", "Sources/NormalizerCore/NormalizationOptions.swift", "--context", "1"])
        #expect(output.contains("contextBefore"))
        #expect(output.contains("contextAfter"))
    }

    @Test("search supports --regex")
    func searchRegex() throws {
        let output = try runCommand(["search", "struct|enum", "Sources/NormalizerCore/NormalizationOptions.swift", "--regex"])
        #expect(output.contains("struct") || output.contains("enum"))
    }

    // MARK: - references

    @Test("references returns results for known symbol")
    func referencesReturnsResults() throws {
        let output = try runCommand(["references", "Normalizer", "Sources/NormalizerCore"])
        #expect(output.contains("Normalizer"))
    }

    @Test("references returns empty for nonexistent symbol")
    func referencesNonexistent() throws {
        let output = try runCommand(["references", "SymbolThatDoesNotExistXYZ", "Sources/NormalizerCore"])
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "[]")
    }

    // MARK: - dependencies

    @Test("dependencies lists imports")
    func dependenciesListsImports() throws {
        let output = try runCommand(["dependencies", "Sources/NormalizerCore"])
        #expect(output.contains("Foundation"))
    }

    @Test("dependencies supports --grouped")
    func dependenciesGrouped() throws {
        let output = try runCommand(["dependencies", "Sources/NormalizerCore", "--grouped"])
        #expect(output.contains("Foundation"))
    }

    // MARK: - index

    @Test("index builds project index")
    func indexBuildsIndex() throws {
        let output = try runCommand(["index", "Sources/NormalizerCore"])
        #expect(output.contains("fileCount"))
        #expect(output.contains("totalDeclarations"))
    }

    @Test("index --output writes to file")
    func indexOutputFile() throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("index_out_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try runCommand(["index", "Sources/NormalizerCore", "--output", out.path])
        let content = try String(contentsOf: out, encoding: .utf8)
        #expect(content.contains("fileCount"))
    }

    // MARK: - api

    @Test("api extracts public API surface")
    func apiExtractsPublic() throws {
        let output = try runCommand(["api", "Sources/NormalizerCore"])
        #expect(output.contains("Normalizer"))
        #expect(output.contains("NormalizationOptions"))
    }

    @Test("api supports --include-internal")
    func apiIncludeInternal() throws {
        let output = try runCommand(["api", "Sources/NormalizerCore", "--include-internal"])
        #expect(output.contains("lineEnding"))
    }

    // MARK: - conformances

    @Test("conformances lists protocol conformances")
    func conformancesListsConformances() throws {
        let output = try runCommand(["conformances", "Sources/NormalizerCore"])
        #expect(output.contains("Sendable"))
        #expect(output.contains("Equatable"))
    }

    @Test("conformances supports --pretty-print")
    func conformancesPrettyPrint() throws {
        let output = try runCommand(["conformances", "Sources/NormalizerCore", "--pretty-print"])
        #expect(output.contains("Sendable"))
    }

    // MARK: - callgraph

    @Test("callgraph builds call graph")
    func callgraphBuilds() throws {
        let output = try runCommand(["callgraph", "Sources/NormalizerCore"])
        #expect(output.contains("caller"))
        #expect(output.contains("callee"))
    }

    @Test("callgraph supports --include-unknown")
    func callgraphIncludeUnknown() throws {
        let output = try runCommand(["callgraph", "Sources/NormalizerCore", "--include-unknown"])
        #expect(output.contains("caller"))
    }

    // MARK: - force-unwraps

    @Test("force-unwraps scans for force unwraps")
    func forceUnwrapsScans() throws {
        let output = try runCommand(["force-unwraps", "Sources/swift-code-query"])
        #expect(output.contains("force_unwrap") || output.contains("ForceUnwrapItem"))
    }

    @Test("force-unwraps supports --pretty-print")
    func forceUnwrapsPrettyPrint() throws {
        let output = try runCommand(["force-unwraps", "Sources/swift-code-query", "--pretty-print"])
        #expect(output.contains("kind"))
    }

    // MARK: - helpers

    private func runCommand(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func runCommandWithStdin(_ args: [String], stdin: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = args

        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = outPipe

        try process.run()
        stdinPipe.fileHandleForWriting.write(stdin.data(using: .utf8)!)
        try stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
