# Changelog

## 1.0.0 (2026-09-15)

### Fixed (release-blockers from the pre-1.0 audit)
- **Silent fall-through when a subcommand name is misspelled is gone.** An
  unknown first token was routed to the default `find` subcommand (a typo'd
  `indexx` returned `[]` with exit 0 — indistinguishable from a successful
  empty query). `find` is no longer the implicit default; an unknown token is
  now a hard `Unknown subcommand` error (exit 64), and top-level unknown
  options show the root usage, not `find`'s.
- **Non-UTF-8 files are no longer silently dropped from scans.** A `.swift`
  file that cannot be decoded as UTF-8 (legacy latin-1 / UTF-16 / binary) is
  now reported to stderr (`warning: skipped non-utf8/unreadable file`) instead
  of vanishing from `query`/`index`/`api`/`search`/`force-unwraps` and friends
  with exit 0. Applied across every scan command.
- **`validate` now signals pass/fail on its exit code.** Syntax errors found →
  exit 1 (warnings alone stay 0); the JSON diagnostics are still printed first.
- **`install` can no longer report success when nothing was copied or built.**
  - `runProcess` failures (mkdir / binary `install`) are now checked by exit
    status, not whether the process launched — a failed copy is a hard error.
  - `--no-build` verifies the prebuilt binaries actually exist before copying.
  - a failed `swift build` aborts the install instead of printing
    "Build complete".
  - `repoDir()` walks up from cwd to find the repo root, so `install` from any
    directory behaves correctly (previously it returned cwd unless the path
    contained `/.build/`).
  - build logs are drained through a temp file (deadlock-free).
- **Inconsistent "no results" signalling unified.** Scanning a path with no
  Swift files (or filtered to zero by `--exclude`) now returns an empty result
  with exit 0; a *nonexistent* path stays exit 64 (`path not found`).

### Added
- `--schema` now exists on every analysis subcommand plus all edit commands,
  `clean`, `batch`, `format`, and `tree`.
- `--output-format` added to `clean` (json/compact/csv/short), `format`
  (json/compact per-file `FormatResult`), all edit commands (json/compact/
  short/csv/jsonl), `batch`, and `tree` (json/compact structured tree).
- `--limit` on `force-unwraps`, `docc-check`, `tree`, `references`.
- `index` output shape fixed: emits the project object (not a wrapping list),
  `--output-format jsonl` emits one object per file, and the unstable
  `generated` timestamp is now opt-in via `--include-timestamp` (runs are
  byte-stable by default for caching/dedup).
- `query` and `search` now support stdin via `-` (matching `find`/`inspect`/
  `format`/`diff`).
- `batch` gained `--schema` and reports malformed plans as readable
  `invalid batch plan: ...` validation errors instead of a Swift
  `DecodingError` dump.
- DocC build works: `swift-docc-plugin` is now a package dependency, so
  `swift package --disable-sandbox generate-documentation` succeeds.

### Changed
- Version is now `1.0.0` everywhere: `swift-package-tool --version`,
  `normalizer-tool --version`, `hermes-plugin/plugin.yaml`, and pyproject.toml.
- A bare `query` with no declaration-kind flags prints a stderr note that it is
  querying functions only (pass `--all` for every kind).
- `query --json` / `--text` are documented legacy aliases: `--json` is a
  no-op (JSON is already the default) and `--text` maps to `--output-format
  short`; an explicit `--output-format` wins so the flags never silently
  contradict each other.
- `find --exact` help text clarifies the `--case-sensitive` interaction.
- README / api-reference / DocC catalog now document the actual 35
  subcommands and per-command `--schema` / `--output-format` support.
- `hermes-plugin` dead code removed (`_parse_build_diagnostics` + its 3
  regexes had zero call sites).
- `install --force` removed (declared but never read on install).
- Orphaned `Examples` target removed from `Package.swift` (nothing depended
  on it).

### Fixes carried forward from the post-0.8.0 development line
- Install/remove/path-wiring are now native `swift-package-tool` subcommands
  (`install`, `uninstall`, `path-wire`) — the former shell scripts in
  `scripts/` are gone. The Makefile targets are thin flag-mapped delegates
  that build the binary and invoke it with `--no-build` (single source of
  install logic: Swift).
- Install dir is wired into the harness PATH automatically and idempotently
  (`PATH_UPDATE=1`, opt out with `PATH_UPDATE=0` or `--no-path-update`);
  `path-wire` writes a marker-guarded export into the shell init files, and is
  backward-compatible with blocks written by the old `path-wire.sh`.
- Hermes verification during `install` is bounded by a 15s timeout so a slow
  `hermes plugins list` can never hang the installer.
- Audit builds keep no persistent state and never create a new top-level
  directory in the consumer's project. `pkg_build` and `pkg_test` run `swift
  build`/`swift test` in a fresh ephemeral scratch dir under the package's own
  `.build` (`<pkg>/.build/swift-package-audit/run-*`) that each call deletes
  when it finishes — every audit is a clean-room build of the current source
  (no incremental reuse), the real `.build` products are untouched. `pkg_clean`
  sweeps `run-*` scratch dirs abandoned by crashed runs (older than 1h, so
  live concurrent audits are kept) plus legacy pre-ephemeral `.build-audit`
  residue.
- **Hermes plugin crash cluster** (`hermes-plugin/swift_package_inspector.py`):
  `_run_swift_code_query` now returns a single unambiguous contract
  (`{"ok": True, "data": ...}` / `{"ok": False, "error": ...}`) instead of
  verbatim JSON, so array-emitting subcommands (`search`, `api`,
  `force-unwraps`, `build`, `test`) can no longer make the `.get()` call
  sites crash with `'list' object has no attribute 'get'`.
- **Double binary path bug**: binary path is no longer prepended twice, so
  `pkg_build`/`pkg_test` no longer fail with `Unknown option '--timeout'`.
- **`lineContent` field mismatch**: the tool emits `lineContent` (camelCase)
  but scanners read `line_content` — both keys are now set from the real field.
- **`list_targets` correctness**: paths and sources from `swift package
  describe` are now anchored to the package dir; per-file symbol counts come
  from an AST-accurate `swift-package-tool query`; `path_kind` restored.
- **`list_dependencies`**: root package node is no longer listed as a
  dependency of itself.
- **`scan_force_unwraps` coalescing**: a line carrying both `try!` and a
  trailing `!` now reports one finding with worst severity/primary.
- **`test()` contract**: `tests_total`/`tests_failed`/`no_tests` parsed from
  the raw log (XCTest and Swift Testing formats); test build isolated in a
  scratch dir under the package's `.build` via `--extra-args=`.
- **Schema envelope double-wrap** (`hermes-plugin/__init__.py`): tool schemas
  are declared in the bare function form the Hermes registry expects, so
  `tool_describe`/`tool_search` expose description/parameters (regression
  test `test_tool_schema_shape`).
- Regression test suite
  (`Tests/NormalizerCoreTests/RegressionTests.swift`) covering `delete
  --symbol`, `--force` verification gating, minify token separation, LCS diff
  minimality, `short`-format reflection dumps, bare-invocation path defaults,
  and the install/uninstall lifecycle.
- Flexible plugin binary path fallback: `SWIFT_CODE_QUERY_PATH` env override >
  `PATH` lookup > `~/.local/bin/swift-package-tool` default.
- `swift-package-tool install` flags: `--debug`, `--no-build`, `--no-plugin`,
  `--symlink`/`--copy`, `--no-path-update`, `--no-interactive`, `--prefix`,
  `--bin-dir`, `--hermes-plugins`.
- `swift-package-tool uninstall` and `swift-package-tool path-wire` subcommands.
- `PLUGIN_MODE` env var honored (validated to `symlink` or `copy`; unset in
  noninteractive mode defaults to `copy`); `HERMES_PLUGINS` accepted as an
  alias for `HERMES_PLUGINS_DIR`.
- `install` no longer spuriously requires `sudo` when the install dir is
  missing but creatable; `uninstall` deduplicates overlapping install dirs.
- `test_tools.py` fixtures updated for modern SwiftPM (declared default source
  dirs, offline local-path dependency test, `function` kind expectations).

## 0.8.0 (2026-08-19)

### Added
- `batch` subcommand — execute multiple edit operations from one JSON plan
  file (`--fail-fast`, dry-run, diff, verify-gate).
- `SwiftPackageToolTests` — black-box integration suite for the editing
  commands and batch plans.
- `Package.swift`: dependency on `swift-argument-parser` declared explicitly.

### Fixed
- Editing commands (`insert`, `replace`, `prepend`/`append`, `add-import`)
  robustness fixes; multiline content handling in `FileEditor`; integration
  test count updates.

## 0.7.0 (2026-08-16)

### Changed
- Refactored 4 editing commands to use `SyntaxRewriter` instead of string-offset manipulation:
  - `add-conformance`: `AddConformanceRewriter` modifies inheritance clause via AST
  - `replace --symbol`: `SymbolRenameRewriter` renames identifiers via token visit
  - `delete --symbol`: `DeclarationDeleteRewriter` removes declarations via `visitAny`
  - `sort`: `MemberSortRewriter` reorders members via member block manipulation
- All string-offset manipulation replaced with AST-level transformations.
  Trivia preservation handled automatically by `SyntaxRewriter`.

## 0.6.0 (2026-08-16)

### Added
- Editing suite: 9 new commands for safe, AST-aware code transformation
  - `replace` — find-and-replace text or rename a symbol (AST-aware)
  - `insert` — insert code at a precise location (--after, --before, --at-line)
  - `delete` — remove code by line range, symbol, or pattern
  - `prepend` / `append` — add code at file boundaries (--after-imports)
  - `add-import` — add an import statement (alphabetical insertion)
  - `add-conformance` — add a protocol conformance to a type (AST-aware)
  - `add-member` — add a property, method, or enum case to a type (AST-aware)
  - `wrap` — wrap selected lines in do-catch, if-let, guard-let, or do
  - `sort` — sort members of a type by name or kind (AST-aware)
- Shared editing infrastructure (FileEditor.swift) with common safety flags:
  --dry-run, --backup, --verify, --show-diff, --force
- 9 integration tests (1 per editing command)
- Total: 30 subcommands, 123 tests

## 0.5.0 (2026-08-15)

### Added
- `clean` subcommand — delete build artifacts without touching dependencies.
  Runs `swift package clean` under the hood. Dependency cache is preserved.
- `--purge-all` / `--destroy-dependencies` flag — ⚠️ **destructive**: deletes
  ALL cached dependencies. Every dependency is removed from `.build/checkouts/`
  and must be re-fetched from scratch on the next build. Named explicitly to
  prevent accidental use.

## 0.4.0 (2026-08-15)

### Added
- `docc-check` subcommand — validate docc documentation comments by checking
  that symbol references point to declarations that actually exist in the
  project. Catches stale or misspelled symbol paths.

### Fixed
- `Makefile install-plugin` target — inlined `plugin_symlink`/`plugin_copy`
  commands instead of using multi-line `define` blocks inside a shell
  `if/then/else/fi` block. The define blocks contained embedded newlines
  that broke shell syntax when expanded inside a single-line command.

## 0.3.0 (2026-08-15)

### Added
- `validate` subcommand — shallow syntax check using SwiftParser diagnostics.
  Catches missing braces, invalid tokens, and malformed declarations without
  running the full compiler. Supports `--warnings` to include warnings.
- `macro-expand` subcommand — find and report macro expansion sites
  (`#externalMacro`, `#Predicate`, `#stringify`, etc.) with locations, names,
  and arguments. Full expansion requires compiler plugin support.

### Fixed
- `ComplexityCollector` now uses a stack instead of single `currentName`/
  `currentScore` variables. Nested function complexity no longer bleeds into
  the outer function's score.
- `DiffDeclarationCollector` now handles 7 previously missing declaration
  types: `InitializerDeclSyntax`, `DeinitializerDeclSyntax`,
  `SubscriptDeclSyntax`, `ExtensionDeclSyntax`, `MacroDeclSyntax`,
  `OperatorDeclSyntax`, and `PrecedenceGroupDeclSyntax`.

## 0.2.0 (2026-08-15)

### Added
- `tree` subcommand — hierarchical symbol tree formatted as indented Swift-like
  declarations with `{ }` braces around container types. Omits imports and local
  variables inside function bodies. Token-efficient for agent consumption.

### Fixed
- `modifierNames()` now uses direct property access instead of `Mirror` API,
  which was silently returning empty arrays for all declarations. This fixes
  access-modifier display in `find`, `query`, `inspect`, `members`, `tree`,
  and all other commands that report modifiers.

## 0.1.0 (2026-08-13)

### Added
- Initial release of `swift-package-utilitykit`
- `swift-package-tool` binary with 14 subcommands:
  - `find` — find symbol by name across all declaration kinds (default subcommand)
  - `query` — list declarations with kind/signature filters
  - `inspect` — detailed symbol information
  - `format` — format or minify Swift source files
  - `search` — full-text search with regex and context
  - `references` — AST-based symbol reference finder
  - `dependencies` — import listing per file
  - `index` — comprehensive project index
  - `api` — public API surface extraction
  - `conformances` — protocol conformance & inheritance chains
  - `callgraph` — call edges between functions
  - `members` — list direct members of a type
  - `complexity` — cyclomatic complexity per function
  - `diff` — semantic declaration diff between two files
- `NormalizeSyntaxPlugin` — SPM command plugin for syntax normalization
- `hermes-plugin/` — Hermes Agent plugin with 8 package-inspection tools
- Makefile with interactive/noninteractive install, symlink/copy plugin choice, unified removal
- `scripts/install.sh` — single-command install script
- Compact JSON output by default (token-efficient for LLMs), `--pretty-print` for human-readable
- JSONL output format (one JSON object per line)
- `--schema` flag on all commands without required arguments
- Swift-only file defaults (no more `.c/.h/.cpp/.metal`)
- Integration tests (31 total: 17 unit + 14 integration)

### Changed
- Refactored from `swift-syntax-normalizer` to `swift-package-utilitykit` (umbrella name)
- Converted from XCTest to Swift Testing framework
- Default indentation changed to tabs (`.spacesToTabs(4)`)
- All source comments lowercased (preserving backticked identifiers, string literals, CLI flags, acronyms)
- Python plugin refactored from 1775-line analysis engine to 1354-line orchestration layer
- Split `SyntaxUtils.swift` monolith (784 lines) into 5 focused files
- `collectSwiftFiles` defaults to Swift-only extensions

### Fixed
- Diff command now walks nested declarations (not just top-level)
- Diff key uses `"file:name:kind"` triples to prevent cross-file collisions
- `members` and `inspect` commands accept directories (not just single files)
- Callgraph uses two-pass resolution (order-independent) and distinguishes init overloads
- Complexity collector now counts inline (no double AST walk)
- Python plugin surfaces errors instead of silently returning empty results
- `--schema` flag added to `query`, `dependencies`, `index` commands
- Help text for `inspect` and `index` includes `jsonl` output format
