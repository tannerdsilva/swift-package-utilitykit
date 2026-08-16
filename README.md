# swift-package-utilitykit

A growing collection of Swift package tooling — a syntax normalizer (with an SPM
command plugin), an agentic code-query tool, and a shared normalization library.
All binaries are designed to be **installed on the host or container** where an
agentic harness runs, so agents invoke them directly via PATH rather than
through `swift run`.

## delivery model

Two delivery mechanisms serve different use cases:

| mechanism | what | who uses it |
|---|---|---|
| **Standalone binaries** | `swift-code-query`, `normalizer-tool` installed in `$PREFIX/bin` | Agentic harness (Hermes, Claude Code, etc.) calling tools directly |
| **SPM command plugin** | `swift package normalize-syntax` | Interactive development, CI pipelines that already use SPM |

Both share the same `NormalizerCore` library and produce identical results.

## quick start

**Prerequisites:** Swift 6.0+ toolchain, Hermes Agent (for the plugin).

### One-command install (recommended)

```bash
git clone https://github.com/your-org/swift-package-utilitykit.git
cd swift-package-utilitykit
make install-plugin
```

This builds release binaries, installs them to `/usr/local/bin` (uses `sudo`
automatically when needed), and installs the Hermes plugin into
`~/.hermes/plugins/`.  In interactive mode (default), you'll be prompted
whether to **symlink** or **copy** the plugin.  Symlinks are lighter and
auto-update with `git pull`; copies are self-contained and survive the
source being moved.

For noninteractive installs (CI, containers), `PLUGIN_MODE` is **required**:

```bash
make install-plugin INSTALL_INTERACTIVE=0 PLUGIN_MODE=symlink   # symlink
make install-plugin INSTALL_INTERACTIVE=0 PLUGIN_MODE=copy      # copy
```

Without `PLUGIN_MODE`, noninteractive mode errors immediately:

```
ERROR: PLUGIN_MODE is required in noninteractive mode.
Set PLUGIN_MODE=symlink or PLUGIN_MODE=copy.
```

### Removal

```bash
make remove                              # interactive (prompts for confirmation)
make remove INSTALL_INTERACTIVE=0        # noninteractive (skips prompt)
make remove INSTALL_INTERACTIVE=0 FORCE=1  # skip all prompts
```

### Install script (from a local clone)

```bash
./scripts/install.sh                     # interactive install
./scripts/install.sh --symlink           # noninteractive, symlink plugin
./scripts/install.sh --copy              # noninteractive, copy plugin
./scripts/install.sh --remove            # interactive removal
./scripts/install.sh --remove --force    # noninteractive removal
```

Or with custom paths:

```bash
PREFIX=/opt/homebrew ./scripts/install.sh
```

### Manual install

```bash
make release                          # build release binaries
sudo make install-release             # install to /usr/local/bin

# plugin: symlink (auto-updates with git pull)
ln -sf "$PWD/hermes-plugin" ~/.hermes/plugins/swift-package-utilitykit

# plugin: copy (self-contained, survives source move)
cp -R "$PWD/hermes-plugin" ~/.hermes/plugins/swift-package-utilitykit

hermes plugin reload                  # reload Hermes plugins
```

### Manual removal

```bash
sudo rm -f /usr/local/bin/swift-code-query /usr/local/bin/normalizer-tool
rm -rf ~/.hermes/plugins/swift-package-utilitykit
```

### Verify

```bash
swift-code-query --version
hermes tool list | grep pkg_
```

## binaries

### `swift-code-query`

Query, inspect, search, and index Swift source code.  Designed for agent
consumption — all subcommands produce JSON by default, with multiple output
formats optimized for different model sizes.

```
swift-code-query find <symbol> [<paths>...] [--exact] [--pretty-print]
                                  [--limit <n>]
swift-code-query query <paths>... [--functions] [--structs] [--classes]
                                  [--enums] [--protocols] [--all]
                                  [--output-format json|compact|csv|short]
                                  [--pretty-print]
                                  [--count] [--sort name|kind|file|line]
                                  [--name <pattern>] [--limit <n>]
                                  [--include <exts>] [--exclude <exts>]
swift-code-query inspect <file> --symbol <name> [--pretty-print]
swift-code-query format <file>... [--minify] [--dry-run]
swift-code-query search <pattern> <paths>... [--regex] [--ignore-case]
                                  [--context <n>] [--pretty-print]
                                  [--limit <n>]
swift-code-query references <symbol> <paths>... [--pretty-print]
swift-code-query dependencies <paths>... [--grouped] [--pretty-print]
swift-code-query index <paths>... [--output <file>] [--pretty-print]
swift-code-query api <paths>... [--include-internal] [--pretty-print]
                                  [--schema]
swift-code-query conformances <paths>... [--include-extensions]
                                  [--pretty-print] [--schema]
swift-code-query callgraph <paths>... [--include-unknown] [--pretty-print]
                                  [--schema]
swift-code-query build [<target>] [--test] [--schema]
swift-code-query force-unwraps [<paths>...] [--pretty-print]
swift-code-query tree [<paths>...] [--include <exts>] [--exclude <exts>]
                                  [--output <file>]
swift-code-query validate [<paths>...] [--warnings] [--output-format <format>]
                                  [--pretty-print]
swift-code-query macro-expand [<paths>...] [--output-format <format>]
                                  [--pretty-print]
swift-code-query docc-check [<paths>...] [--output-format <format>]
                                  [--pretty-print]
```

**output formats** — every subcommand supports these, selectable with
`--output-format`.  **Default is `compact`** (single-line JSON, no whitespace)
for token efficiency.  Use `--pretty-print` for human-readable JSON.

| format | description | best for |
|---|---|---|
| `compact` | Single-line JSON, no whitespace **(default)** | Token-constrained models, agentic tools |
| `json` | Pretty-printed JSON (use `--pretty-print`) | Human review, debugging |
| `jsonl` | One JSON object per line (streaming) | Streaming agentic workflows, large results |
| `csv` | Comma-separated values | Spreadsheets, simple parsers |
| `short` | Minimal `file:line:col` text | Terminal, grep pipelines |

**query** — list declarations in one or more source files or directories:

```bash
# list all functions in compact JSON (default for agent use)
swift-code-query query Sources/ --functions

# pretty-printed JSON for human review
swift-code-query query Sources/ --functions --pretty-print

# all declaration kinds, sorted by file, limited to 20
swift-code-query query Sources/ --all --sort file --limit 20

# just the count
swift-code-query query Sources/ --all --count
```

Output is a JSON array of `DeclarationInfo` objects:

```json
{
  "name": "normalize",
  "kind": "function",
  "file": "Sources/NormalizerCore/Normalizer.swift",
  "line": 4,
  "column": 25,
  "offset": 102,
  "signature": "func normalize(_ input: String, options: NormalizationOptions) -> String",
  "docComment": "/// normalizes `input` according to `options`.",
  "modifiers": ["public", "static"]
}
```

**inspect** — get full detail on a named symbol, including its source text and
immediate children:

```bash
swift-code-query inspect Sources/Foo.swift --symbol MyStruct

# pipe source through stdin (use `-` as path)
cat Sources/Foo.swift | swift-code-query inspect --symbol MyStruct -
```

**search** — full-text search across source files with regex support:

```bash
# plain text search
swift-code-query search "DispatchQueue" Sources/

# regex with context lines
swift-code-query search "func (foo|bar)" Sources/ --regex --context 2

# case-insensitive, compact output for small models
swift-code-query search "normalize" Sources/ --ignore-case --output-format compact
```

**references** — find every usage of a symbol (declarations + calls + accesses):

```bash
swift-code-query references "normalize" Sources/NormalizerCore/
```

Output includes the role (`declaration`, `call`, `access`) and surrounding
source context for each reference.

**dependencies** — list all import statements across source files:

```bash
# flat list
swift-code-query dependencies Sources/

# grouped by file
swift-code-query dependencies Sources/ --grouped

# CSV for spreadsheet analysis
swift-code-query dependencies Sources/ --output-format csv
```

**index** — build a comprehensive project index combining all declarations,
imports, and file-level metadata in a single JSON document:

```bash
# print to stdout
swift-code-query index Sources/

# write to a file for caching
swift-code-query index Sources/ --output project-index.json

# compact for model context
swift-code-query index Sources/ --output-format compact
```

The index includes file count, total declarations, total imports, and per-file
breakdowns — ideal for giving a small model a complete picture of a codebase
in a single tool call.

## Hermes Agent plugin

The ``hermes-plugin/`` directory contains a Hermes Agent plugin (Python) that
provides 8 package-inspection tools (``pkg_build``, ``pkg_scan``,
``pkg_list_dependencies``, ``pkg_list_targets``, ``pkg_test``, ``pkg_clean``,
``pkg_docc_check``, ``pkg_inspector``).

**Architecture:** The plugin is a thin orchestration layer.  Code-analysis logic
has been moved into the ``swift-code-query`` binary:

| Tool | Engine | What changed |
|---|---|---|
| ``pkg_build`` | ``swift build`` | Unchanged (build system operation) |
| ``pkg_scan`` | ``swift-code-query search`` + Python post-processing | Regex matching delegated to the Swift binary |
| ``pkg_list_dependencies`` | ``swift package show-dependencies --format json`` | Replaced regex-based Package.swift parser |
| ``pkg_list_targets`` | ``swift package describe --type json`` | Replaced regex-based Package.swift parser |
| ``pkg_test`` | ``swift test`` | Unchanged |
| ``pkg_clean`` | ``swift package clean`` | Unchanged |
| ``pkg_docc_check`` | ``swift-code-query api`` + heuristic fallback | Doc coverage uses AST-guaranteed API output |
| ``pkg_inspector`` | Composes all above | Uses swift-code-query for analysis sub-tools |

The Python layer retains the scope-clustering, severity-ranking, and
reachability-classification logic that is specific to security-audit workflows
and would be overkill to implement in the Swift binary.  Everything else
delegates to the Swift toolchain for AST-guaranteed accuracy.

**Prerequisites:** ``swift-code-query`` must be installed in PATH (or set
``SWIFT_CODE_QUERY_PATH`` env var).  Swift 6.0+ toolchain required.

**api** — extract the public API surface of a project.  Walks all declarations,
filters by access level, and emits only the *interface* (name, kind, access,
signature, conformances).  Gives a small model the API without the
implementation — an entire codebase in ~500 tokens vs. 50K+ for raw source.

```bash
# public API surface (default: public declarations only)
swift-code-query api Sources/

# include internal declarations too
swift-code-query api Sources/ --include-internal

# pretty-print for human review
swift-code-query api Sources/ --pretty-print

# see the JSON Schema for the output type
swift-code-query api --schema
```

Output includes `access` (public/internal/package), `conformsTo` (protocol
conformances), `signature`, and `docComment` for each declaration.

**conformances** — list every type and what it conforms to (protocols,
superclasses).  Essential for agents modifying Swift code, because changing
a protocol requirement affects all conformances.

```bash
# list all conformances
swift-code-query conformances Sources/

# include extensions that add conformances
swift-code-query conformances Sources/ --include-extensions

# JSONL for streaming
swift-code-query conformances Sources/ --output-format jsonl

# see the schema
swift-code-query conformances --schema
```

Output: `{name, kind, file, line, inherits: [...], source: "declaration"|"extension"}`.

**callgraph** — build a call graph from function bodies.  For each function,
lists the functions it calls.  Gives an agent control-flow understanding
without running the code.

```bash
# build call graph (resolved calls only by default)
swift-code-query callgraph Sources/

# include calls to unknown/undeclared functions
swift-code-query callgraph Sources/ --include-unknown

# pretty-print for review
swift-code-query callgraph Sources/ --pretty-print

# see the schema
swift-code-query callgraph --schema
```

Output: `{caller, callee, file, line, column, resolved}`.  The `resolved`
field is `true` when the callee is a known function in the project.

**tree** — show a hierarchical symbol tree for Swift source files, formatted as indented Swift-like declarations. Container types (struct, class, enum, protocol, extension) get `{ }` braces around their members. Imports and local variables inside function bodies are omitted. Designed for token-efficient agent consumption.

```bash
# show symbol tree for a directory
swift-code-query tree Sources/

# show tree for a single file
swift-code-query tree Sources/NormalizerCore/Normalizer.swift

# write to file
swift-code-query tree Sources/ --output symbol-tree.txt
```

Output is indented text with Swift-like syntax:

```
// Sources/NormalizerCore/NormalizationOptions.swift
public enum CommentMode: Sendable, Equatable {
  case preserve
  case hide
}
public struct NormalizationOptions: Sendable, Equatable {
  public var lineEnding: LineEnding
  public var stripTrailingWhitespace: Bool
  public var ensureFinalNewline: Bool
  public var indentation: IndentationPolicy
  public var minify: Bool
  public var commentMode: CommentMode
  public enum LineEnding: Sendable, Equatable {
    case lf
    case crlf
    public var stringValue: String
  }
  public enum IndentationPolicy: Sendable, Equatable {
    case preserve
    case tabsToSpaces(Int)
    case spacesToTabs(Int)
  }
  public static let standard
  public static let minified
}
```

**validate** — shallow syntax check using SwiftParser's built-in diagnostics. Catches missing braces, invalid tokens, malformed declarations, and other syntax-level errors without running the full compiler. Does not perform type-checking.

```bash
# check a file for syntax errors
swift-code-query validate Sources/Foo.swift

# include warnings in addition to errors
swift-code-query validate Sources/ --warnings

# pretty-printed output
swift-code-query validate Sources/ --pretty-print
```

Output is structured JSON with file, line, column, severity, message, and fix-it count per diagnostic.

**macro-expand** — find and report macro expansion sites in Swift source files. Identifies where macros are used (`#externalMacro`, `#Predicate`, `#stringify`, etc.) and reports their locations, names, and arguments. Does NOT expand macros — that requires running the Swift compiler with the macro implementations loaded as plugins.

```bash
# find all macro usages in a project
swift-code-query macro-expand Sources/

# pretty-printed output
swift-code-query macro-expand Sources/ --pretty-print
```

Output is structured JSON with file, line, column, macro name, kind (declaration or expression), and arguments.

**docc-check** — validate docc documentation comments by checking that symbol references (backtick-enclosed names in `///` comments) point to declarations that actually exist in the project. Catches stale or misspelled symbol paths in documentation. Does not resolve qualified names, module references, or external symbols.

```bash
# check all source files for invalid docc references
swift-code-query docc-check Sources/

# pretty-printed output
swift-code-query docc-check Sources/ --pretty-print
```

Output: `{file, line, column, severity, message, referencedSymbol}`

**force-unwraps** — scan Swift source files for force-unwrap operations (`!`), classifying each occurrence as a force-unwrap (`value!`), force-try (`try!`), or force-cast (`as!`). Uses AST-based detection, not regex.

```bash
# scan a project for force unwraps
swift-code-query force-unwraps Sources/

# pretty-printed output
swift-code-query force-unwraps Sources/ --pretty-print
```

Output: `{file, line, column, context}` where context shows the surrounding expression.

**build** — run `swift build` (or `swift test` with `--test`) and return structured output for LLM consumption. Parses build logs into a structured result with success/failure, target, duration, and error details.

```bash
# build the default target
swift-code-query build

# run tests
swift-code-query build --test

# see the schema
swift-code-query build --schema
```

Output: `BuildResult` — `{success, target, duration, output, errors}`.

**`--schema` flag** — every new command supports `--schema`, which prints the
JSON Schema for its output type and exits.  Small models can use this to
construct correct queries on the first attempt, avoiding token-wasting retry
loops.

**members** — list the direct members of a type (properties, methods, enum
cases, subscripts, initializers).  The "what's inside this type" command.

```bash
# list members of a specific type in a file
swift-code-query members Sources/NormalizerCore/Normalizer.swift --type Normalizer

# pretty-printed
swift-code-query members Sources/NormalizerCore/Normalizer.swift --type Normalizer --pretty-print

# see the schema
swift-code-query members --schema
```

Output: `{name, kind, file, line, column, signature, modifiers}`.

**complexity** — measure cyclomatic complexity per function.  Counts decision
points (if, guard, for, while, switch, catch, &&, ||) and rates each function
as simple (1-5), moderate (6-10), complex (11-20), or very_complex (21+).

```bash
# all functions
swift-code-query complexity Sources/

# only complex or worse
swift-code-query complexity Sources/ --min-complexity 11

# top 5 most complex
swift-code-query complexity Sources/ --limit 5
```

Output: `{name, file, line, column, complexity, rating}`.

**diff** — semantic declaration diff between two source files.  Compares
top-level declarations (functions, structs, classes, enums, protocols,
typealiases, variables) by name+kind and reports added, removed, and
changed signatures.

```bash
# compare two files
swift-code-query diff Sources/old.swift Sources/new.swift

# compare a file against stdin (pipe)
cat Sources/new.swift | swift-code-query diff Sources/old.swift -
```

Output: `{file1, file2, addedCount, removedCount, changedCount, added: [...], removed: [...], changed: [...]}`.

**find** — the "i know the name but not what it is" command.  Give it a symbol
name and it searches every declaration kind across your project, returning
the kind, file, and signature.  **Default output is compact JSON** for agent
consumption; use `--pretty-print` for human-readable output.

```bash
# substring match (default) — compact JSON output
swift-code-query find "normalize" Sources/

# exact match
swift-code-query find "Normalizer" Sources/ --exact

# pretty-printed JSON for human review
swift-code-query find "normalize" Sources/ --pretty-print

# limit results
swift-code-query find "normalize" Sources/ --limit 5

# pipe source through stdin (use `-` as path)
cat Sources/Foo.swift | swift-code-query find "MyStruct" -
```

Default output format is `compact` — single-line JSON with no whitespace.
Use `--pretty-print` to get pretty-printed JSON, or `--output-format short`
for `file:line:col  [kind]  signature` text.  No need to know whether
something is a struct, class, protocol, or enum before you ask.

`query --name <pattern>` also now defaults to searching all declaration kinds
when `--name` is given without kind flags, so both paths solve the dilemma.

**format** — format or minify source files.  The `--minify` mode strips all
indentation and blank lines for LLM-optimized token efficiency (research shows
LLMs maintain accuracy on unformatted code while saving ~24.5% input tokens).

```bash
# pretty-print with canonical formatting (tabs for indent)
swift-code-query format Sources/ --dry-run

# minify for LLM consumption
swift-code-query format Sources/ --minify --dry-run

# pipe source through stdin (use `-` as path)
cat Sources/Foo.swift | swift-code-query format - --minify --dry-run
```

### `normalizer-tool`

Normalize or minify file syntax.  Used internally by the SPM plugin, but also
available as a standalone binary for direct agent use.

```
normalizer-tool --file <path>... [--lf|--crlf] [--minify] [--dry-run]
```

```bash
# normalize with defaults (tabs for indent, LF endings, trailing ws stripped)
normalizer-tool --file Sources/Foo.swift

# minify for LLM consumption
normalizer-tool --file Sources/Foo.swift --minify --dry-run
```

## SPM command plugin

The `NormalizeSyntax` plugin is available through Swift Package Manager:

```bash
# normalize all source files in the package
swift package --allow-writing-to-package-directory normalize-syntax

# minify mode
swift package --allow-writing-to-package-directory normalize-syntax --minify

# preview without writing
swift package --allow-writing-to-package-directory normalize-syntax --dry-run
```

The plugin discovers all source files (`.swift`, `.m`, `.mm`, `.c`, `.h`, `.cc`,
`.cpp`, `.cxx`, `.s`, `.S`, `.metal`) across every target and normalizes them
in place.

### plugin flags

| flag | effect |
|---|---|
| `--lf` | Unix line endings (default) |
| `--crlf` | Windows line endings |
| `--keep-trailing-whitespace` | Do not strip trailing whitespace |
| `--no-final-newline` | Do not guarantee a trailing newline |
| `--collapse-blank-lines` | Collapse runs of blank lines to one |
| `--tabs-to-spaces <n>` | Convert leading tabs to `<n>` spaces |
| `--spaces-to-tabs <n>` | Convert runs of `<n>` leading spaces to tabs (default: 4) |
| `--preserve-indentation` | Leave leading whitespace untouched |
| `--minify` | Strip indentation and blank lines for LLM-optimized token efficiency |
| `--dry-run` | Report changes without writing files |

## default behaviour

- **Output format**: compact JSON (single-line, no whitespace).  Use `--pretty-print`
  for human-readable pretty-printed JSON, or `--output-format short` for text.
- **Line endings**: LF (Unix).  Use `--crlf` for Windows.
- **Trailing whitespace**: stripped.
- **Final newline**: guaranteed.
- **Indentation**: tabs (each complete run of 4 leading spaces becomes one tab).
  Use `--preserve-indentation` to leave as-authored, or `--tabs-to-spaces <n>`
  / `--spaces-to-tabs <n>` to convert explicitly.
- **Minify mode** (`--minify`): strips all leading whitespace and collapses
  blank lines, based on research showing LLMs maintain accuracy on unformatted
  code while saving ~24.5% input tokens.

## project layout

```
Makefile                                  build & install targets
Package.swift                              SPM manifest (plugin + executables)
README.md
scripts/
  build-and-install.sh                     CI/automation build script
Sources/
  NormalizerCore/                          shared normalization logic (unit-tested)
    Normalizer.swift                       normalize(), splitLines(), collapseBlankLines()
    NormalizationOptions.swift             options struct with .standard and .minified presets
  normalizer-tool/                         CLI tool invoked by the plugin (and standalone)
    main.swift                             argument parsing + file processing
  swift-code-query/                        agentic code query/inspect/search/index tool (24 files)
    SwiftCodeQuery.swift                   @main entry point (ArgumentParser, 20 subcommands)
    FindCommand.swift                      find symbol by name across all kinds
    QueryCommand.swift                     list declarations via swift-syntax SyntaxVisitor
    InspectCommand.swift                   show detailed symbol info
    FormatCommand.swift                    format/minify using NormalizerCore
    SearchCommand.swift                    full-text search with regex
    ReferencesCommand.swift                AST-based symbol references
    DependenciesCommand.swift              import listing
    IndexCommand.swift                     comprehensive project index
    ApiCommand.swift                       public API surface extraction
    ConformancesCommand.swift              protocol conformance & inheritance
    CallgraphCommand.swift                 call edges between functions
    MembersCommand.swift                   list direct members of a type
    ComplexityCommand.swift                cyclomatic complexity per function
    DiffCommand.swift                      semantic declaration diff
    BuildCommand.swift                     structured build/test output
    ForceUnwrapsCommand.swift              force-unwrap scanner
    TreeCommand.swift                      hierarchical symbol tree
    ValidateCommand.swift                  shallow syntax validation
    MacroExpandCommand.swift               macro expansion site finder
    DoccCheckCommand.swift                 docc documentation validation
    OutputFormat.swift                     OutputFormat enum, formatOutput, writeOutput
    Declarations.swift                     DeclarationInfo, SymbolDetail, SymbolFinder
    Visitors.swift                         syntax visitors (FunctionNameCollector, etc.)
    Helpers.swift                          collectSwiftFiles, lineColumn, UsageError
    SyntaxUtils.swift                      trivia helpers, declaration kind helpers
  Examples/                                demo source files for plugin testing
    Example.swift
    Messy.swift
  hermes-plugin/                           Hermes Agent plugin (Python)
    __init__.py                            tool schemas + handlers (8 tools)
    swift_package_inspector.py             orchestration layer calling swift-code-query
    test_tools.py                          assertion tests
    AGENTS.md                              agent orientation
    plugin.yaml                            Hermes plugin manifest
Plugins/
  NormalizeSyntaxPlugin/                   thin SPM command plugin (glue to normalizer-tool)
    Plugin.swift                           CommandPlugin entry point
    ArgumentParser.swift                   flag parsing (mirrors normalizer-tool flags)
Tests/
  NormalizerCoreTests/                     17 tests (Swift Testing)
    NormalizerTests.swift
```

## building from source

```bash
# debug build
make

# release build
make release

# install to /usr/local/bin
make install

# release build + install
make install-release

# custom prefix
PREFIX=/opt/tools make install

# run tests
make test

# clean
make clean
```

Or use the build script:

```bash
./scripts/build-and-install.sh              # debug → /usr/local
./scripts/build-and-install.sh --release    # release → /usr/local
PREFIX=/opt/tools ./scripts/build-and-install.sh --release
```

## dependencies

- Swift 6.0+
- [swift-argument-parser](https://github.com/apple/swift-argument-parser) 1.5+
- [swift-syntax](https://github.com/swiftlang/swift-syntax) 600.0+

These are fetched automatically by SPM during `swift build`.

## research basis

The `--minify` mode is informed by *"The Hidden Cost of Readability: How Code
Formatting Silently Consumes Your LLM Budget"* (arXiv 2508.13666, Aug 2025),
which found that LLMs maintain functional accuracy on unformatted code while
saving ~24.5% input tokens.  The paper's conclusion — that a deterministic,
AST-safe formatter that can strip all non-semantic formatting is the right
approach for LLM consumption — directly motivates the minify pass.

See also:
- *"Beyond Functional Correctness: Investigating Coding Style Inconsistencies in
  Large Language Models"* (arXiv 2407.00456)
- *"Does Prompt Formatting Have Any Impact on LLM Performance?"* (arXiv 2411.10541)

## troubleshooting

### "swift-code-query: command not found"

The binary must be installed in PATH:

```bash
# install to /usr/local/bin (default)
make install-plugin

# verify
swift-code-query --version
```

If you used a custom `PREFIX`, add it to your PATH:

```bash
export PATH="/opt/tools/bin:$PATH"
```

Or set `SWIFT_CODE_QUERY_PATH` for the Python plugin:

```bash
export SWIFT_CODE_QUERY_PATH=/opt/tools/bin/swift-code-query
```

### "Swift 6.0+ toolchain required"

Install or select the Swift 6.0 toolchain:

```bash
# check current version
swift --version

# install via Xcode or https://swift.org/download/
```

### "Permission denied" when installing

The default install prefix `/usr/local/bin` requires `sudo` on macOS.
The Makefile auto-detects this, but you can also use a custom prefix:

```bash
make install PREFIX=~/.local
make install-plugin PREFIX=~/.local
```

### "Plugin not found" after install

The Hermes plugin must be symlinked or copied into `~/.hermes/plugins/`:

```bash
# verify
ls -la ~/.hermes/plugins/swift-package-utilitykit

# if missing, re-run install
make install-plugin

# or manually symlink
ln -sf "$PWD/hermes-plugin" ~/.hermes/plugins/swift-package-utilitykit
```

Then reload Hermes:

```bash
hermes plugin reload
hermes tool list | grep pkg_
```

### "make install-plugin" fails with "PLUGIN_MODE is required"

In noninteractive mode (`INSTALL_INTERACTIVE=0`), you must specify
`PLUGIN_MODE`:

```bash
make install-plugin INSTALL_INTERACTIVE=0 PLUGIN_MODE=symlink
make install-plugin INSTALL_INTERACTIVE=0 PLUGIN_MODE=copy
```

### "swift build" fails with cryptic errors

Ensure you have the correct Swift toolchain and all dependencies:

```bash
# clean build
swift package reset
swift build

# check Swift version (6.0+ required)
swift --version | head -1
```

### Integration tests fail

The integration tests run the `swift-code-query` binary as a subprocess.
Ensure the binary is built first:

```bash
swift build
swift test
```

If tests fail with "binary not found", build the debug binary explicitly:

```bash
swift build --product swift-code-query
swift test
```

### Performance: no caching

Every `swift-code-query` command parses every source file independently.
Running `find`, `query`, and `api` on the same 100-file project parses
300 ASTs.  This is by design — the tool prioritizes correctness and
simplicity over caching.  For repeated queries on the same codebase,
use `index` (single parse, comprehensive output) or pipe results through
`jq`/`dasel` for filtering instead of re-running the tool.
