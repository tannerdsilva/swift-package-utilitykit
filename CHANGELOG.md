# Changelog

## Unreleased

### Changed
- Install/remove/path-wiring are now native `swift-package-tool` subcommands
  (`install`, `uninstall`, `path-wire`) — the former shell scripts in
  `scripts/` are gone. The Makefile's `install`, `install-release`,
  `install-plugin`, `remove`, and `path-wire` targets are thin flag-mapped
  delegates that build the binary and invoke it with `--no-build` (single
  source of install logic: Swift).
- Install dir is wired into the harness PATH automatically and idempotently
  (`PATH_UPDATE=1`, opt out with `PATH_UPDATE=0` or `--no-path-update`).
  `swift-package-tool path-wire` writes a marker-guarded export into
  `~/.profile` and any existing `~/.bash_profile` / `~/.bashrc` / `~/.zshrc`,
  and is backward-compatible with blocks written by the old `path-wire.sh`.
- Hermes verification during `install` is bounded by a 15s timeout so a slow
  `hermes plugins list` can never hang the installer.

### Added
- `swift-package-tool install` flags: `--debug`, `--no-build`, `--no-plugin`,
  `--symlink`/`--copy`, `--force`, `--no-path-update`, `--no-interactive`,
  `--prefix`, `--bin-dir`, `--hermes-plugins`.
- `swift-package-tool uninstall` and `swift-package-tool path-wire` subcommands.
- `PLUGIN_MODE` env var honored (validated to `symlink` or `copy`; unset in
  noninteractive mode defaults to `copy`).
- `HERMES_PLUGINS` accepted as an alias for `HERMES_PLUGINS_DIR`.

### Fixed
- `install` no longer spuriously requires `sudo` when the install dir is
  missing but creatable (e.g. a fresh machine without `~/.local`).
- `uninstall` deduplicates overlapping install dirs (default
  `INSTALL_DIR == $HOME/.local/bin`), so each binary is reported once.

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
