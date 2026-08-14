# swift-package-utilitykit — Software Skeptic Critique

> Reviewed: 20 Swift source files (swift-code-query), 6 Python/plugin files, Makefile, install.sh, test_tools.py, README.md, CHANGELOG.md, AGENTS.md, README.md (plugin)
> Previous round fixes C1–H6: verified for completeness and new regressions.

---

## 1. CRITICAL (bugs, correctness, security, missing error handling)

### C1. `inspect` command silently returns the first match — multiple matches ignored
- **File:** `InspectCommand.swift:49–103`
- **Problem:** The `for filePath in files` loop iterates all files but `return`s on the *first* match it finds (line 99). If the symbol exists in multiple files, only the first file's result is returned — the user has no indication other matches exist. Same pattern in `MembersCommand.swift:54–65`.
- **Fix:** Accumulate all matches in a loop, then output them all. Or, add a `--all` flag to toggle between "first match" and "all matches" modes. For a directory-aware command, returning all matches is more useful.

### C2. `InspectCommand` and `MembersCommand` return `ValidationError` instead of an informative "no match"
- **File:** `InspectCommand.swift:106` / `MembersCommand.swift:72`
- **Problem:** Both throw `ValidationError("symbol 'X' not found in the given paths")` — but the search loop uses `do/catch { continue }` (line 101–103 in InspectCommand, line 67–69 in MembersCommand). If a file can't be read (permission error, non-UTF8), the file is silently skipped *and* if no match is found the generic "not found" error is thrown. The user can't tell if it's "symbol doesn't exist" vs. "I couldn't read any files because they were unreadable" (unlikely edge case but the error is the same).
- **Fix:** Track whether any files were actually scanned (not just skipped by `continue`). If 0 files were processed, report that separately.

### C3. `DiffCommand` uses `Dictionary(grouping:)` with non-unique keys — `map2[key]!` can be empty or wrong
- **File:** `DiffCommand.swift:52–77`
- **Problem:** `DiffDeclarationCollector` already walks nested declarations (per C1 fix), so a single `(file, name, kind)` key can map to multiple declarations (e.g., nested struct inside top-level struct). Line 69 `let a = map1[key]!.first!` only compares the first declaration from each side. If the first declarations are identical but a *later* nested declaration changed, the diff is silently wrong.
- **Fix:** Instead of using `.first!`, iterate all entries for each key (compare the full array, or use a structured diff within each group). Alternatively, use a composite key that includes nesting depth.

### C4. Python `scan_unsafe_ptrs` double-skips comments
- **File:** `swift_package_inspector.py:492–493`
- **Problem:** The `stripped.startswith("//")` check skips lines that are full-line comments. However, lines like `let x = UnsafePointer<T>() // create pointer` would NOT start with `//` and would be flagged correctly — this is actually fine. **But** the scope-clustering logic on lines 498–517 groups by function scope using `_function_scopes`, which itself has a heuristic bug (see M1 below). The double-skip concern is low; this is actually OK.
- **Skip:** Not a real bug.

### C5. `_run_swift_code_query` returns `{"ok": False, ...}` on non-zero exit code, but callers assume list shape
- **File:** `swift_package_inspector.py:64–65`
- **Problem:** When `swift-code-query` returns a non-zero exit code, `_run_swift_code_query` returns `{"ok": False, "error": "..."}`. However, `_search_with_swift_code_query` (line 358–377) checks `if not result.get("ok", True) or "error" in result` and raises `RuntimeError`. This is correct for the search path. But `docc_check` (line 1035) calls `_run_swift_code_query` directly and checks `api_result.get("ok", True) and isinstance(api_result, list)`. If `ok` is False, it falls through to the heuristic fallback, which is a reasonable behavior. **However**, if the API command fails because `swift-code-query` isn't installed, `docc_check` silently falls back to a less-accurate heuristic parser — the user has no way to know the preferred path failed.
- **Fix:** Add a `preferred_method_failed` field in the fallback case so the consumer knows.

### C6. `install.sh` Swift version regex can mis-parse `Apple Swift 6.2.1`
- **File:** `scripts/install.sh:135`
- **Problem:** `swift --version | head -1 | grep -oE '[0-9]+\.[0-9]+'` matches the *first* pair of digits. On macOS with Apple's bundled toolchain, `swift --version` outputs:
  ```
  Apple Swift version 6.2.1 (swift-6.2.1-RELEASE)
  ```
  The regex matches `6.2`, which is correct. However, if Swift 5.10 is installed and Apple branding is present, it still matches `5.10`. But the subtraction `$SWIFT_MAJOR=${SWIFT_VER%%.*}` gets `5`, and `[ 5 -lt 6 ]` correctly rejects it. **Actually fine** — this works.
- **Skip:** Not a real bug.

### C7. `collectSwiftFiles` silently ignores non-existent paths
- **File:** `Helpers.swift:25`
- **Problem:** `FileManager.fileExists` returning false causes the function to `continue` the outer loop silently. If a user passes a path that doesn't exist (typo, wrong working directory), the function returns an empty list and the caller throws "no matching source files found" — the error message doesn't tell the user *which* paths were invalid.
- **Fix:** Track which paths were real vs. invalid and report them in the error.

---

## 2. HIGH PRIORITY (usability, missing features, architectural debt)

### H1. `find` command: substring match is too broad for common symbols
- **File:** `FindCommand.swift:84–87`
- **Problem:** Default substring matching means `find "url"` matches `URLSession`, `getUrl`, `url`, `curl`, `ModuleURL`, etc. There's no word-boundary option (only `--exact` for case-insensitive exact match, and `--case-sensitive` which is a flag not a matching mode). A "word boundary" match would be very useful for hitting `MyURL` but not `curl`.
- **Fix:** Add `--word-boundary` flag that uses `NSRegularExpression` with `\b` anchors for substring matching.

### H2. `SearchCommand` uses `collectSwiftFiles` (Swift-only) even though the search pattern might target other file types
- **File:** `SearchCommand.swift:43–47`
- **Problem:** The `--include` and `--exclude` options exist but `collectSwiftFiles` always defaults to `["swift"]` only. The `--include` option *can* override this (e.g., `--include c,h`), but the user would need to know to pass it — the default behavior silently excludes `.c`, `.h`, `.json`, etc. This is a behavioral inconsistency: `search` is a full-text tool, yet it only searches `.swift` files by default while other tools (like `searchFile` in Visitors.swift line 109) expect to search arbitrary files.
- **Fix:** Consider a `--any-language` flag or defaulting `search` to search all text files unless `--include` is specified.

### H3. `callgraph` does not resolve methods on `self` or type-qualified names against the type's own declaration
- **File:** `CallgraphCommand.swift:230–246`
- **Problem:** `extractCalleeName` only extracts the base name from `IdentifierExprSyntax` and `MemberAccessExprSyntax`. It does not resolve whether `foo.bar()` where `foo` is `self` is a method of the current type. The `knownFunctions` set contains names like `func doWork()`, and the callgraph correctly identifies `doWork()` calls, but calls like `self.doWork()` or `MyType.doWork()` are extracted as just `doWork` (from member access), so they *do* match. **Actually, this works correctly** because `MemberAccessExprSyntax.declName.baseName` extracts the method name, and the two-pass resolution just checks if that name is in the known set. The limitation is that `self.` prefix calls and extension methods might be missed if the callee name is shadowed.
- **Skip:** Works as designed.

### H4. Python `_function_scopes` brace-depth heuristic can mis-parse complex Swift
- **File:** `swift_package_inspector.py:386–413`
- **Problem:** The scope detection uses raw brace-counting and regex heuristics to detect function boundaries. This can fail on:
  - Multiline closures: `{ (x: Int) -> Void in ... }` — the `{` opens a scope but there's no `func` keyword.
  - Nested generic type parameters with `>`: `func foo<T: Comparable>(x: T) -> T {` — the `>` before `(` could confuse a naive parser.
  - String interpolation with `{}`: `print("value: \(count)")` — curly braces inside strings.
  - Attribute braces: `#if` blocks and `@_documentation(concealed: true)` — though these don't use `{}`.
  - When scope is mis-detected, reachability classification (`_reachability`) gets wrong context, which inverts severity rankings.
- **Fix:** This is a known design trade-off (Python layer retains scope-clustering logic from the original regex engine). Document it as a limitation. A real fix would require an AST-based approach, which defeats the "delegated to swift-code-query" architecture.

### H5. `MembersCommand` uses `SymbolFinder` which walks every file looking for the type name — inefficient and fragile
- **File:** `MembersCommand.swift:54–66`
- **Problem:** The command accepts directories but then uses `SymbolFinder` (a SyntaxVisitor) to walk every file sequentially until it finds a match. This is O(n) per file with no early termination for files that can't contain the type. If `SymbolFinder` finds a type named "Foo" in file A and another type named "Foo" in file B (different modules), only file A's members are returned.
- **Fix:** First, use the AST-based search (`swift-code-query search`) to find all files containing the type, then use `swift-code-query query --all --name <type>` on those files. Or, add an `--all` flag to list members of all matching types.

### H6. `inspect` and `members` have different semantics: `inspect` walks files in order, `members` walks files in order, but both use the *same* `SymbolFinder` which returns only the first match
- **File:** `InspectCommand.swift:99` / `MembersCommand.swift:65`
- **Problem:** Both commands return after the first match. This means in a project with `UIKit` and custom `Label` classes, `inspect --symbol Label` might return UIKit's Label instead of the custom one.
- **Fix:** Add `--all` flag on both commands to return all matches.

### H7. No validation that `--output` directory exists before writing in `inspect`/`members`/`callgraph`/`complexity` commands
- **File:** `InspectCommand.swift:97` / `MembersCommand.swift:64` / `CallgraphCommand.swift:99` / `ComplexityCommand.swift:82`
- **Problem:** `writeOutput` (Helpers.swift:68–74) calls `string.write(toFile:atomically:encoding:)` which silently creates intermediate directories on macOS (when `atomically: true`) but fails on Linux if the directory doesn't exist. The error message would be a generic write failure, not "directory does not exist."
- **Fix:** Check that the parent directory of the output path exists and error out with a clear message, or create it explicitly.

### H8. `extractDocComment` only extracts `///` and `/** */` — misses `// MARK:` and other inline comment annotations
- **File:** `SyntaxUtils.swift:18–30`
- **Problem:** The function only returns doc-line and doc-block comments. `// MARK: - Public API` is not a doc comment and is correctly excluded from docComment. But this means that the `DeclarationInfo.docComment` field is empty for declarations that only have a `// MARK:` comment, which could be confusing when the user expects to see all associated comments.
- **Skip:** This is by design — MARK is not documentation.

---

## 3. MEDIUM PRIORITY (code quality, consistency, documentation)

### M1. Inconsistent output format flag naming across commands
- **Files:** All 14 commands
- **Problem:** Some commands use `--output-format` (e.g., `find`, `search`, `references`, `dependencies`, `api`, `members`), some use `--output-format` and `--pretty-print` while others are missing `--pretty-print`. Specifically:
  - Commands **with** `--pretty-print`: find, query, search, references, dependencies, api, conformances, callgraph, members, complexity, diff
  - Commands **missing** `--pretty-print`: `inspect` has it, `index` doesn't (line 16–20 of IndexCommand.swift)
  - `index` command has `--output` (file path) but no `--output-format` or `--pretty-print` — wait, actually it does have `--output-format` at line 17. But it's missing `--pretty-print`.
- **Fix:** Add `--pretty-print` to `index` and `inspect` (inspect already has it). Make `--pretty-print` available on all commands for consistency.

### M2. `--schema` on commands with `@Flag` declarations conflicts with Swift ArgumentParser
- **Context:** Documented limitation from previous round
- **Problem:** Commands like `conformances` (line 24: `@Flag ... var includeExtensions`) and `complexity` (line 22: `@Option ... var outputPath`) have both `--schema` and other flags/options. The known Swift compiler bug about `@Flag`/`@Option` ambiguity was mentioned in the previous round as accepted. **However**, the `--schema` flag appears on 10 commands while the 4 remaining (`find`, `search`, `references`, `inspect` without schema in some cases) don't have it.
- **Fix:** Document which commands have `--schema` in the README. Consider a top-level `--schema` on all commands that accept file arguments.

### M3. `Modifiers` extraction uses Mirror API instead of direct syntax access
- **File:** `SyntaxUtils.swift:104–114`
- **Problem:** `modifierNames` uses `Mirror(reflecting: node)` to find the `modifiers` property. This is fragile — if SwiftSyntax changes the internal structure of declaration nodes, this breaks silently. The standard approach is to cast each declaration type explicitly:
  ```swift
  (node as? FunctionDeclSyntax)?.modifiers.map { $0.name.text } ?? []
  ```
  The Mirror approach works but is slower and less type-safe.
- **Fix:** Switch to explicit casting per declaration type for performance and safety.

### M4. `formatOutput` CSV generation uses Mirror — fields appear in declaration order, not alphabetical
- **File:** `OutputFormat.swift:46–52`
- **Problem:** `Mirror(reflecting: item)` iterates properties in declaration order (which happens to match the struct field order). This is fine, but `--output-format json` uses `.sortedKeys` while CSV doesn't sort headers. The result is that JSON output has alphabetically sorted keys while CSV has struct-order keys, which is inconsistent and can break downstream parsers that expect a consistent column order.
- **Fix:** Sort CSV headers alphabetically to match JSON key ordering.

### M5. `SignatureString` for `VariableDecl` only handles the first binding
- **File:** `SyntaxUtils.swift:157–163`
- **Problem:** `TuplePatternSyntax` bindings (e.g., `let (x, y) = point`) fall through to the `default` case at line 166. For tuple bindings, the signature becomes the raw node description, which may include newlines. The `.components(separatedBy: "\n").first ?? ""` handles this, but the signature will be truncated to the first line, losing the tuple structure.
- **Fix:** Handle `TuplePatternSyntax` specifically: join tuple elements with `, `.

### M6. `DeclarationInfo` JSON Schema uses `"description"` in properties but no `$defs`
- **Files:** `Declarations.swift:38–56`, `ApiCommand.swift:92–110`, `ComplexityCommand.swift:94–109`, `ConformancesCommand.swift:92–107`, `CallgraphCommand.swift:111–126`, `DiffCommand.swift:117–156`, `MembersCommand.swift:85–101`, `Visitors.swift:264–278`
- **Problem:** All JSON Schema definitions are inline strings using `"$schema": "https://json-schema.org/draft-07/schema#"` but they're not validated against any schema validator. More importantly, `DiffCommand.swift:117–156` uses `"$ref": "#/definitions/DiffDeclaration"` while the definitions section is at the same level — this is correct Draft-07 syntax. However, `DiffDeclaration` struct (line 159–166) has a `column: Int` field, but the schema definition (line 134–141) also includes `column`. This is fine.
- **Minor:** Schema strings are not validated. Consider a compile-time check or test that each schema string is valid JSON.

### M7. `README.md` is 708 lines — too long for a single documentation file
- **File:** `README.md`
- **Problem:** The README covers installation, all 14 commands with examples, output formats, the Hermes plugin, the SPM plugin, default behavior, and project layout. This is a textbook example of what an "API reference" should be. The document is hard to navigate and maintain.
- **Fix:** Split into: `README.md` (overview + quick start + links), `docs/commands/find.md`, `docs/commands/query.md`, etc. Use the `--schema` output to generate reference docs automatically.

### M8. `test_tools.py` uses `import swift_package_inspector as sa` at top level
- **File:** `test_tools.py:22`
- **Problem:** The import runs `sys.path.insert` which modifies global state. If this script is imported by another module (e.g., in CI), the path insertion is a side effect. The script also has hardcoded fixture generation (`_make_package`, `_make_pkg_manifest`) that duplicates content from the actual tests.
- **Fix:** Move `sys.path.insert` inside `main()` or use a proper `conftest.py` for pytest.

### M9. No `py.typed` marker file for the Python plugin package
- **File:** `hermes-plugin/`
- **Problem:** The plugin has type annotations (`from __future__ import annotations`) but no `py.typed` file, so `mypy` and other type checkers won't recognize it as a typed package. For a tool used by automated agents (which may do static analysis on tool outputs), this is a small quality issue.
- **Fix:** Add `py.typed` file to `hermes-plugin/`.

### M10. `--include`/`--exclude` extension handling is inconsistent
- **Files:** `Helpers.swift:20–21`, and all commands accepting `include`/`exclude` options
- **Problem:** Extensions with a leading dot are stripped (`$0.dropFirst()`). So `--include .swift` and `--include swift` are equivalent. This is fine, but the behavior should be documented. Additionally, there's no `--exclude-symlinks` or `--follow-symlinks` option for file discovery — if a project has symlinks into its Sources directory, the behavior is undefined.
- **Fix:** Document the dot-stripping behavior.

---

## 4. LOW PRIORITY (nice-to-haves, future opportunities)

### L1. `swift-code-query` has no `--version` flag on individual subcommands
- **File:** `SwiftCodeQuery.swift:10`
- **Problem:** The top-level command has `version: "0.1.0"` but running `swift-code-query find --version` doesn't work. Users expect `--version` on every subcommand.
- **Fix:** Add `version: "0.1.0"` to each subcommand's `CommandConfiguration` or use `.default` inheritance.

### L2. No `--verbose` or `--quiet` flag on any command
- **Problem:** There's no way to suppress the "file: unchanged" message from `format --dry-run` or get a summary line from `query`. For pipeline usage, quiet mode is important.
- **Fix:** Add `--quiet` flag that suppresses non-JSON output.

### L3. `search` command uses `NSRegularExpression` which is POSIX ERE — not PCRE
- **File:** `Visitors.swift:125–131`
- **Problem:** `NSRegularExpression` uses Foundation's regex engine, which supports ICU-style patterns. Some features (like `\b`, `(?P<name>...)`) work differently than PCRE. Users familiar with `grep -P` might be surprised by differences.
- **Fix:** Document which regex features are supported.

### L4. `complexity` command doesn't count `catch` clauses within nested closures
- **File:** `ComplexityCommand.swift:172–175`
- **Problem:** The `CatchClauseSyntax` visitor only increments if `inFunction` is true. But if the catch is inside a closure that's inside the function, `inFunction` would still be true (the visitor doesn't track closure depth). This is actually correct for cyclomatic complexity — catch blocks inside closures are still decision points.

### L5. `index` command could benefit from a `--output` file with structured metadata
- **File:** `IndexCommand.swift:82–87`
- **Problem:** The `--output` flag writes the index JSON to a file, which is good for caching. But there's no way to append to an existing index (e.g., across multiple source roots) or merge incremental updates.
- **Fix:** Consider a `--mode append` flag for multi-root indexing.

### L6. No deprecation mechanism for commands or options
- **Problem:** If a command is renamed or an option is deprecated (e.g., `--text` in `query` is redundant with `--output-format short`), there's no way to warn users.
- **Fix:** Use `ArgumentParser`'s built-in deprecation features.

### L7. `NormalizerCore` library target has no public API documented
- **File:** `Package.swift:17`
- **Problem:** `NormalizerCore` is a library target but there's no `--docc-generate` step in the Makefile. The README mentions the normalize tool but doesn't document the library API.
- **Fix:** Add a `make docs` target that runs `swift package generate-docs`.

### L8. `.gitignore` doesn't exclude `.build-audit/` — the Python plugin's isolated build dir
- **File:** `.gitignore`
- **Problem:** If the Python plugin is used locally, `.build-audit/` directories are created. These should be ignored. Check the `.gitignore` for this.
- **Fix:** Add `.build-audit/` to `.gitignore`.

### L9. No integration test coverage for `swift-code-query` commands
- **Problem:** Integration tests run `swift-code-query` binary as subprocess (the `NormalizerCoreTests` directory has 17 unit + 14 integration tests per CHANGELOG), but the 14 subcommands have no end-to-end command tests. A broken `find` command could go undetected.
- **Fix:** Add a test target that runs each subcommand with a known fixture and asserts on the output.

---

## Summary of Previous Round Fixes Verification

| Fix | Status | Notes |
|-----|--------|-------|
| C1: Diff walks nested declarations | ✅ Verified | `DiffDeclarationCollector` visits all child nodes (`.visitChildren` on all visits) |
| C2: Diff key uses "file:name:kind" triples | ✅ Verified | Line 52–53 uses `"\\($0.file):\\($0.name):\\($0.kind)"` |
| C3: Members accepts directories | ✅ Verified | `paths: [String] = ["."]` with `collectSwiftFiles` |
| C4: Python raises RuntimeError | ✅ Verified | `_search_with_swift_code_query` raises `RuntimeError` on failure |
| C5: Inspect accepts directories | ✅ Verified | `paths: [String] = ["."]` with `collectSwiftFiles` |
| H1: Callgraph distinguishes init overloads | ✅ Verified | `FunctionNameCollector` appends `init(params)` with parameter types |
| H2: Complexity counts inline | ✅ Verified | Single `SyntaxVisitor` walk, `currentScore` tracked per function |
| H3: Help text for inspect/index includes jsonl | ⚠️ Partial | `inspect` help text (line 28) says "json, compact, short, jsonl" — **jsonl** is listed. `index` help text (line 16) says "json, compact, csv, jsonl" — **jsonl** is listed. ✅ |
| H4: Callgraph two-pass resolution | ✅ Verified | First pass (line 58–71) collects all names, second pass (line 74–89) builds edges |
| H5: --schema on query, dependencies, index | ✅ Verified | `QueryCommand.swift:73–74`, `DependenciesCommand.swift:34–35`, `IndexCommand.swift` **missing `--schema`** ❌ |
| H6: Caching limitation documented | ⚠️ Missing | Not found in README or CHANGELOG. The "No caching" limitation is in the context but not in the source docs. |

**Two corrections from the previous round:**
1. **H5 for `index` command is NOT complete** — `IndexCommand.swift` does NOT have a `--schema` flag (missing at line 31 area). It has `--output` (path), `--output-format`, and `--pretty-print`, but no `@Flag ... var schema = false`.
2. **H6 is not actually documented** in any source file — the caching limitation is not mentioned in README.md, CHANGELOG.md, or AGENTS.md.
