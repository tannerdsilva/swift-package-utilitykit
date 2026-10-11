# Changelog

## 2.0.2

### Fixed

- **edit commands no longer exit 0 when the edit did not apply.** a `replace`
  whose `--old` matches nothing, an `insert` anchor that is absent, a `delete`
  range / symbol / pattern that selects nothing, a `wrap` range beyond the
  file, an `add-member` / `add-conformance` / `sort` target that does not
  exist, and a `replace --symbol` rename with no references all printed a
  `warning` and exited 0 — the failure was visible only to a consumer parsing
  stdout. every "did not apply" outcome now exits 1 **after** the payload is
  printed (the same print-then-throw shape `validate`, `clean` and `build`
  use), so a caller that only reads `$?` cannot mistake a silent no-op for a
  successful edit. `--dry-run` mirrors the real run's exit code.
- **a write withheld by `--verify` now exits 1** unless `--force` applies it.
- **`batch` exits 1 when any operation missed or failed**, and `--fail-fast`
  now stops on a selector miss (it previously keyed on verification alone, so
  misses slipped past it).
- **`sort` no longer reports `modified: true` when its output is
  byte-identical** — an already-sorted type reports `alreadyCurrent` and the
  file is left untouched.

### Changed

- (BREAKING) **`EditResult` gains a machine-readable `status` field** —
  `applied` | `alreadyCurrent` | `missed` | `blocked` | `failed` — carried in
  the JSON payload and the `--schema` output, and mirrored by the process
  exit code for the failure cases. benign idempotent no-ops (`already
  imported`, `already conforms`, nothing to sort, identity replacement) stay
  exit 0. a consumer that keyed on `exit 0` for a no-op edit must treat
  exit 1 as "the edit did not apply" — the payload still carries the
  specifics.

## 2.0.1

### Fixed
- **build-output parsing is correct across Swift 6.3.0 - 6.4.0.** the
  toolchain output format changes at 6.4.0, and three defects left
  `pkg_build`/`pkg_test` (and `build`) reporting empty diagnostics on it. ANSI
  SGR codes and OSC-8 hyperlink sequences in toolchain output were never
  stripped, so a colour-wrapped `warning:` level token failed the
  `["error","warning","note"]` allowlist and the warning was dropped; the
  6.4.0 level-prefix error layout (`error: file:line:col msg`) matched no rule,
  unlike the classic `<file>:<lin>:<col>: <level>: <msg>` form; and
  thin-space phase lines `[N / M]` failed to parse as counts. the parser now
  strips escape sequences up front, understands both layouts, and normalises
  the phase bracket (including the U+2009 thin space) before splitting, so
  `errorCount`, `warningCount` and `phases` populate on every toolchain and
  `rawLog` carries no escape bytes. the four parse functions were extracted
  into the new `BuildOutputParsing` library target with golden fixtures for
  both eras — the whole 6.3.x classic path is preserved (it must not regress),
  and the 6.4.0 summary headline `error: emit-module command failed ...` is a
  build summary, not a file diagnostic, and is never counted.

### Changed
- **a failed `pkg_build` / `pkg_test` / `pkg_validate` now reports through the
  MCP `isError` flag instead of returning a normal result with the failure
  buried in the payload. this is a BREAKING change for any consumer that
  previously read a failed build/test/validate out of the payload alone — the
  verdict now lives on `isError`, not only in the result. the structured
  payload still round-trips (over the plugin dialect it sits after the
  framework's `Error: ` prefix), and `pkg_build` keeps `succeeded:false`, so
  the verdict is present twice and cannot be missed.**
- **tool descriptions now carry cost and failure semantics.** every `pkg_*`
  tool states whether it is read-only and answers in seconds;
  `pkg_build`/`pkg_test` are called out as real cold compiles that are much
  slower, and the three failure-gated tools say they report through `isError`.
  no runtime behaviour changes.

### Removed
- the orphaned `Sources/Examples/` directory — its target was removed from the
  manifest in 1.0.0, but the directory itself lingered as dead weight — and the
  retired shim's leftover `hermes-plugin/__pycache__`.

## 2.0.0

### Added
- **`SubprocessCore` — one spawn path, built on `SwiftSlash` 5.0.2.** every
  subprocess in the package (the CLI's `build`/`clean`/`install`/`uninstall`/
  plugin-tool runner, the git probe, and the test harnesses) goes through
  `Subprocess.capture`, which owns the launch, the concurrent stdout/stderr
  drain, the stdin payload, the optional timeout, and the reap. 5.0.2 carries
  the fix for an argv-marshalling defect that truncated non-ascii arguments (and
  `argv[0]`) to their character count in bytes; it is tagged locally, so this is
  a path pin until it is pushed (`from: "5.0.2"` then replaces it), alongside the
  path-pinned `swift-mcp` sibling.
- **the package-inspector tools, ported into the CLI.** five subcommands join
  the surface, and the analysis that lived in a Python shim now lives in the
  Swift binary: `scan` (unified security/code-quality findings — unsafe
  pointers, force unwraps, process safety, secrets — with reachability-aware
  severity and scope clustering), `targets` (resolved paths, file/line counts,
  symbol heatmaps), `package-dependencies` (requirement kinds and pins),
  `doc-coverage` (DocC catalog inventory + `///` coverage and the uncovered
  list) and `inspector` (one-call orientation: targets, dependencies, findings,
  build/test verdicts, doc coverage, README intent, git state, one-line
  summary). parity against the Python reference was verified payload-for-payload
  on real trees and fixtures.
- **the audit scratch contract: `build --isolated` and `clean --audit`.** an
  isolated run builds/tests in a fresh `run-*` dir under
  `<pkg>/.build/swift-package-audit` that is removed when the run finishes,
  with rmdir-only parent cleanup, so a live run's scratch — or a real build
  product — is never deleted. `clean --audit` sweeps only stale run dirs
  (older than an hour) and legacy `.build-audit` residue; it never runs
  `swift package clean`. measured: the package's real `.build` fingerprint is
  byte-identical before and after an isolated build and test run.
- **`plugin`: the agent tool protocol over stdin/stdout** — built on
  [swift-mcp](https://github.com/tannerdsilva/swift-mcp)'s one-shot stdin tool
  facade. `swift-package-tool plugin` reads `{"tool": "<name>", "args": {...}}`
  on stdin and writes `{"result": "<string>"}` on stdout, so a harness drives
  the binary directly with no interpreter shim. The eleven `pkg_*` tools
  (`pkg_inspector`, `pkg_scan`, `pkg_list_targets`, `pkg_list_dependencies`,
  `pkg_build`, `pkg_test`, `pkg_clean`, `pkg_docc_check`, `pkg_api`,
  `pkg_force_unwraps`, `pkg_validate`) are `@MCPCommand` declarations — the
  JSON Schema, typed argument handling, and the envelope come from the
  framework; only the tool→subcommand mapping lives here. Tools still
  re-invoke this same binary, so the CLI stays the contract, and stdout is
  preferred as the result, so structured payloads — including non-zero
  verdicts like `validate`'s — pass through verbatim. `pkg_build`/`pkg_test`
  run isolated and `pkg_clean` sweeps audit scratch, so an agent cannot
  destroy a consumer's build products through this surface.
- **the same binary speaks MCP.** a full MCP session (`initialize` →
  `tools/list` → `tools/call`) is served on the same streams, so a harness
  with a native MCP client (Hermes Agent: `hermes mcp add utilitykit
  --command <abs path> --args plugin`) registers it as a plain stdio server
  and gets the identical tool set with no plugin files at all.
- **harness adapter: the generated manifest.** `swift-package-tool install
  --plugins-dir ~/.arc/plugins` (env `PLUGINS_DIR`; `make install-plugin`)
  writes the manifest generated by the installed binary
  (`plugin --mcp-manifest arc`) into the harness plugins dir, so it addresses
  the installed path and can never drift from the tools. it is now the only
  adapter; see Changed for the flags that went with the retired one.
- **Dependency: `swift-mcp`** (path pin `../swift-mcp` while co-developing;
  replaced by a URL/version pin once tagged). Minimum platform moves to
  macOS 15.

### Fixed
- **`install` + `build` on Swift 6.4 toolchains.** `swift test` now holds the
  package's build lock for the entire test invocation, so the install-lifecycle
  integration test's nested `swift build` deadlocked behind the parent until
  `build`'s 600s timeout fired. the timed-out build was then reported as
  success (exit 0), and `install --no-build` failed on binaries that were never
  built. fixed three ways:
  - `install` gained `--build-dir` (env `BUILD_DIR`) to point at prebuilt
    binaries in a scratch build outside the repo's `.build`.
  - the integration test now builds `normalizer-tool` into a disjoint scratch
    workspace that escapes the parent's build lock.
  - `build` now exits non-zero when the build failed or timed out; the
    structured JSON on stdout still carries the specifics.
  the full suite drops from a ~600s red run to a ~26s green run.
- **`normalizer-tool` is now a declared package product.** it was installed by
  `install`/the Makefile as a shipped binary but never declared in
  `Package.swift`, so `swift build -c release` never produced it and every
  install path failed on a clean tree ("prebuilt binary not found at
  .build/release/normalizer-tool"). declined as a product, it builds with the
  default build like `swift-package-tool`.
- **`install`'s repo-root probe no longer keys off an adapter directory.** it
  looked for `hermes-plugin/` to identify the repo; a rename or a second
  adapter would have silently degraded it to cwd and skipped the plugin
  install. the markers are now `Package.swift` + `Sources/swift-package-tool`.
  adapter plugin copy/symlink failures are now hard errors instead of being
  swallowed by `try?` — a failed plugin install can never report success.
- **audit fixes: source corruption, traps, and silent no-ops.**
  - minification no longer changes code or string values: the hide-comments
    pass rewrites only lines that open a comment (a `"Sources/*.swift"` glob
    line keeps its declaration, multi-line block-comment interiors are now
    hidden), and `format --minify` emits multi-line string literals verbatim,
    so relative indentation, trailing spaces, and blank lines inside a literal
    survive the round trip.
  - byte offsets are no longer used as character indices: `add-member` and
    `force-unwraps` no longer trap with "String index is out of bounds" — or
    silently insert into the next declaration — on files with non-ASCII text.
  - declared locations are the declaration's own: `query`, `find`, `members`,
    `inspect`, `api`, `conformances`, `callgraph`, `complexity`, `diff`,
    `macro-expand`, `force-unwraps`, and `skill-generate` report `line` and
    `column` after leading trivia (a function behind a doc comment is no longer
    reported at the previous token's line), columns count characters, and
    `docc-check` points at the offending reference, not at the declaration the
    comment is attached to.
  - edit-path robustness: `add-conformance` and `sort` find nested types;
    `--backup` replaces a stale `.bak` instead of failing the edit; an anchor
    or range that selects nothing reports why through `warning` instead of
    returning a silent no-op, and a malformed `--lines` range is a usage error.
  - CLI contract: `format` emits every `--output-format` (csv, short, and jsonl
    were silently ignored); `clean` exits non-zero when `swift package clean`
    fails; `normalizer-tool` exits non-zero when a file cannot be normalized.

### Added
- **`skill-generate` — wrap a package's documented API in an agent skill.** new
  subcommand that folds the public surface (source doc comments, via the same
  collector `api` uses) plus the `.docc` catalog articles into a `SKILL.md`
  tree any harness can load, with the full digest in `references/api.md` and
  articles in `references/articles/`. honors the portable agent-skill
  contract (description ≤60 chars, semver `version`, `platforms`, byte-0 `---`
  frontmatter); `--install` copies the tree into `<skills-dir>/<category>/<name>`,
  where `--skills-dir` (env `SKILLS_DIR`) is required — no harness layout is
  assumed; output is deterministic — no timestamps, identical inputs produce
  byte-identical trees. `undocumented` in the summary is data, not failure:
  it doubles as a docc-coverage signal.
- **`GitMetadataPlugin` — a build tool plugin that records git provenance.**
  the `swift-package-tool` target attaches it, so `--version` reports the
  commit a binary was built from as semver build metadata (`1.0.0+f8aedbd`,
  plus `.dirty` when the working tree had local changes). the probe, renderer,
  and write-if-changed rule live in the new `GitMetadataCore` library
  (unit-tested); the plugin is a thin adapter over the new `git-metadata-tool`
  executable, which is also usable by hand (`git-metadata-tool --print
  --repo .`) and is published as a plugin product for other packages to attach
  to any target. a tarball checkout or a machine without git is not an error:
  the generated `GitProvenance.swift` carries `nil` fields and the version
  falls back to the plain semver number.

### Changed
- **the subprocess layer is Swift-native: no Grand Central Dispatch, no
  `Foundation.Process`.** `build`'s timeout was a `DispatchGroup.wait` with a
  `@unchecked Sendable` box fed by two `DispatchQueue.global()` readers; it now
  races the child against a `Task.sleep` in a task group. on timeout the child's
  process group is signalled and reaped before the command reports, so a
  timed-out build can no longer leave a compiler running, and the timeout path
  reports the same structured payload as before. every `Process` site — the
  git probe (`GitMetadataProbe.collect` is now `async`), the plugin-tool runner
  (its temp-file dance is gone; the drain is concurrent), the installer
  helpers, and all six test harnesses (155 test functions became `async`) —
  moved to `SubprocessCore`. output is captured byte-exactly by running
  swift-slash's streams with the line parser disabled (`separator: []`), since
  its line framing consumes the separator. spawn-heavy suites are `.serialized`
  (the documented house rule for subprocess-heavy suites). the two plugin
  targets cannot link a library from another package (SwiftPM: `plugin 'X'
  cannot depend on 'Y' of type 'library'`), so `NormalizeSyntaxPlugin` spawns
  via `posix_spawn` from its synchronous entry point — a blocking wait on a
  plugin thread, never on a concurrency thread.
- **the CLI is now harness-agnostic end to end.** `install`/`uninstall` take
  `--plugins-dir` (env `PLUGINS_DIR`) and `skill-generate` takes
  `--skills-dir` (env `SKILLS_DIR`); the adapter plugin step runs only when a
  directory is given, so the binaries assume, name, and probe no harness. the
  generated `SKILL.md` no longer carries a `metadata.hermes` block or a
  harness-specific `--author` default, and its consult instructions name no
  harness tool. the `Hermes Agent` prerequisite probe and the
  `hermes plugins list` post-install verification were removed from the
  binary — a harness verifies its own plugin registry. harness conventions
  now live at the edges: the Makefile (`PLUGINS_DIR`), adapter directories,
  and docs.
- **`install` now has one adapter instead of two.** the manifest generated by
  the installed binary is the only thing `--plugins-dir` writes; the adapter
  kind selector, the repo-directory (`hermes`) adapter, and the
  copy/symlink/interactive plugin-mode machinery are gone. the Makefile's
  `PLUGINS_DIR` default moves from `~/.hermes/plugins` to `~/.arc/plugins`
  (the manifest harness); native MCP clients need no files at all.

### Removed
- `install --no-plugin` (an absent `--plugins-dir` is the skip), the
  `--hermes-plugins` / `--hermes-skills` flags, and the
  `HERMES_PLUGINS` / `HERMES_PLUGINS_DIR` / `HERMES_SKILLS_DIR` environment
  variables.
- **`hermes-plugin/`** — the Python shim (8 tools) is retired: its analysis
  lives in the CLI (`scan`/`targets`/`package-dependencies`/`doc-coverage`/
  `inspector`), its tool surface in `plugin` (11 tools), and Hermes reaches
  both through its native MCP client. the shim's assertions were ported to
  `Tests/SwiftPackageToolTests/InspectorPortTests.swift`, so the coverage
  survives the interpreter.

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
