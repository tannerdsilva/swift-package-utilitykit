# swift-package-tool API Reference

## Overview

`swift-package-tool` is a Swift source code analysis and editing tool with 30 subcommands.
All output is compact JSON by default (single-line, no whitespace) for
token-efficient consumption by LLMs. Use `--pretty-print` for human-readable
output.

## Global flags

| Flag | Description |
|---|---|
| `--version` | Print version and exit |
| `--help` | Print help and exit |

## Output formats

Every subcommand supports `--output-format <format>`:

| Format | Description | Example |
|---|---|---|
| `compact` (default) | Single-line JSON array | `[{"name":"foo","kind":"func"}]` |
| `json` | Pretty-printed JSON | `[\n  {\n    "name": "foo",...` |
| `csv` | Comma-separated values | `name,kind,file,line` |
| `short` | Minimal one-line per result | `Sources/main.swift:42 func foo()` |
| `jsonl` | One JSON object per line | `{"name":"foo"}\n{"name":"bar"}` |

## Subcommands

### `find` (default)

Find a symbol by name across all declaration kinds.

```
swift-package-tool find <symbol> [<paths>...] [--exact] [--case-sensitive]
    [--output-format <format>] [--pretty-print] [--include <exts>]
    [--exclude <exts>] [--limit <n>] [--schema]
```

| Argument | Description |
|---|---|
| `symbol` | Symbol name to search for (substring match by default) |
| `paths` | Files or directories to search (default: `.`). Use `-` for stdin. |

| Flag/Option | Description |
|---|---|
| `--exact` | Require exact name match (case-insensitive) |
| `--case-sensitive` | Case-sensitive search |
| `--output-format` | json, compact, csv, short |
| `--pretty-print` | Pretty-print JSON output |
| `--include` | Only files with these extensions (comma-separated) |
| `--exclude` | Skip files with these extensions (comma-separated) |
| `--limit` | Maximum number of results |
| `--schema` | Print JSON Schema for output type and exit |

**Output type:** `FindResult` — `{name, kind, file, line, column, signature, docComment, modifiers}`

---

### `query`

List declarations with kind/signature filters.

```
swift-package-tool query [<paths>...] [--kind <kinds>] [--name <pattern>]
    [--all] [--count] [--sort <field>] [--output-format <format>]
    [--pretty-print] [--include <exts>] [--exclude <exts>]
    [--limit <n>] [--schema]
```

| Flag/Option | Description |
|---|---|
| `--kind` | Filter by declaration kind(s): function, struct, class, enum, protocol, etc. |
| `--name` | Filter by name (substring match) |
| `--all` | Include all declaration kinds |
| `--count` | Return count only (no detail) |
| `--sort` | Sort by: name, kind, file, line |
| `--output-format` | json, compact, csv, short |
| `--pretty-print` | Pretty-print JSON output |
| `--include` | Only files with these extensions |
| `--exclude` | Skip files with these extensions |
| `--limit` | Maximum results |
| `--schema` | Print JSON Schema for output type and exit |

**Output type:** `DeclarationInfo` — `{name, kind, file, line, column, offset, signature, docComment, modifiers}`

---

### `inspect`

Detailed information about a specific symbol.

```
swift-package-tool inspect <symbol> [<paths>...] [--output-format <format>]
    [--pretty-print] [--include <exts>] [--exclude <exts>]
    [--output-path <file>]
```

| Argument | Description |
|---|---|
| `symbol` | Symbol name to inspect |
| `paths` | Files or directories to search (default: `.`). Use `-` for stdin. |

| Flag/Option | Description |
|---|---|
| `--output-format` | json, compact, short, jsonl |
| `--pretty-print` | Pretty-print JSON output |
| `--include` | Only files with these extensions |
| `--exclude` | Skip files with these extensions |
| `--output-path` | Write output to file instead of stdout |

**Output type:** `SymbolDetail` — `{name, kind, file, line, column, signature, docComment, modifiers, children, sourceText}`

---

### `format`

Format or minify Swift source files.

```
swift-package-tool format <files>... [--minify] [--preserve-indentation]
    [--in-place]
```

| Argument | Description |
|---|---|
| `files` | Files to format. Use `-` for stdin (prints result to stdout). |

| Flag/Option | Description |
|---|---|
| `--minify` | Strip all indentation and blank lines for LLM consumption |
| `--preserve-indentation` | Keep original indentation (don't convert to tabs) |
| `--in-place` | Modify files in place instead of printing to stdout |

---

### `search`

Full-text search with regex support.

```
swift-package-tool search <pattern> [<paths>...] [--regex] [--ignore-case]
    [--context <n>] [--output-format <format>] [--pretty-print]
    [--include <exts>] [--exclude <exts>] [--limit <n>]
```

| Argument | Description |
|---|---|
| `pattern` | Search pattern (plain text or regex) |
| `paths` | Files or directories to search (default: `.`) |

| Flag/Option | Description |
|---|---|
| `--regex` | Treat pattern as regex |
| `--ignore-case` | Case-insensitive search |
| `--context` | Number of context lines before/after each match |
| `--output-format` | json, compact, csv, short |
| `--pretty-print` | Pretty-print JSON output |
| `--include` | Only files with these extensions |
| `--exclude` | Skip files with these extensions |
| `--limit` | Maximum matches |

**Output type:** `SearchMatch` — `{file, line, column, line_content, context_before, context_after}`

---

### `references`

Find every usage of a symbol (declarations + calls + accesses).

```
swift-package-tool references <symbol> [<paths>...] [--output-format <format>]
    [--pretty-print] [--include <exts>] [--exclude <exts>]
```

| Argument | Description |
|---|---|
| `symbol` | Symbol name to find references for |
| `paths` | Files or directories to search (default: `.`) |

| Flag/Option | Description |
|---|---|
| `--output-format` | json, compact, csv, short |
| `--pretty-print` | Pretty-print JSON output |
| `--include` | Only files with these extensions |
| `--exclude` | Skip files with these extensions |

**Output type:** `SymbolReference` — `{file, line, column, name, role (declaration|call|access), context}`

---

### `dependencies`

List all import statements across source files.

```
swift-package-tool dependencies [<paths>...] [--output-format <format>]
    [--pretty-print] [--grouped] [--include <exts>] [--exclude <exts>]
    [--schema]
```

| Flag/Option | Description |
|---|---|
| `--output-format` | json, compact, csv, short |
| `--pretty-print` | Pretty-print JSON output |
| `--grouped` | Group imports by file |
| `--include` | Only files with these extensions |
| `--exclude` | Skip files with these extensions |
| `--schema` | Print JSON Schema for output type and exit |

**Output type:** `ImportInfo` — `{module, kind, file, line, column}`

---

### `index`

Build a comprehensive project index.

```
swift-package-tool index [<paths>...] [--output-format <format>]
    [--pretty-print] [--output <file>] [--include <exts>]
    [--exclude <exts>] [--schema]
```

| Flag/Option | Description |
|---|---|
| `--output-format` | json, compact, csv, jsonl |
| `--pretty-print` | Pretty-print JSON output |
| `--output` | Write index to this file instead of stdout |
| `--include` | Only files with these extensions |
| `--exclude` | Skip files with these extensions |
| `--schema` | Print JSON Schema for output type and exit |

**Output type:** `ProjectIndex` — `{generated, fileCount, totalDeclarations, totalImports, files: [FileIndex]}`

---

### `api`

Extract the public API surface of a project.

```
swift-package-tool api [<paths>...] [--include-internal] [--output-format <format>]
    [--pretty-print] [--include <exts>] [--exclude <exts>]
    [--output-path <file>] [--schema]
```

| Flag/Option | Description |
|---|---|
| `--include-internal` | Include internal declarations (not just public/open) |
| `--output-format` | json, compact, csv, short, jsonl |
| `--pretty-print` | Pretty-print JSON output |
| `--include` | Only files with these extensions |
| `--exclude` | Skip files with these extensions |
| `--output-path` | Write output to file instead of stdout |
| `--schema` | Print JSON Schema for output type and exit |

**Output type:** `ApiDeclaration` — `{name, kind, access, file, line, column, signature, conformances, docComment}`

---

### `conformances`

List every type and its protocol conformances/superclasses.

```
swift-package-tool conformances [<paths>...] [--output-format <format>]
    [--pretty-print] [--include <exts>] [--exclude <exts>]
    [--output-path <file>] [--schema]
```

| Flag/Option | Description |
|---|---|
| `--output-format` | json, compact, csv, short, jsonl |
| `--pretty-print` | Pretty-print JSON output |
| `--include` | Only files with these extensions |
| `--exclude` | Skip files with these extensions |
| `--output-path` | Write output to file instead of stdout |
| `--schema` | Print JSON Schema for output type and exit |

**Output type:** `ConformanceInfo` — `{type, kind, file, line, conformances: [name], inheritance: [name]}`

---

### `callgraph`

Build a call graph between functions.

```
swift-package-tool callgraph [<paths>...] [--output-format <format>]
    [--pretty-print] [--include-unknown] [--include <exts>]
    [--exclude <exts>] [--limit <n>] [--output-path <file>] [--schema]
```

| Flag/Option | Description |
|---|---|
| `--output-format` | json, compact, csv, short, jsonl |
| `--pretty-print` | Pretty-print JSON output |
| `--include-unknown` | Include calls to unknown/undeclared functions |
| `--include` | Only files with these extensions |
| `--exclude` | Skip files with these extensions |
| `--limit` | Maximum number of edges |
| `--output-path` | Write output to file instead of stdout |
| `--schema` | Print JSON Schema for output type and exit |

**Output type:** `CallEdge` — `{caller, callee, file, line, column, resolved}`

---

### `members`

List direct members of a type.

```
swift-package-tool members [<paths>...] --type <name> [--output-format <format>]
    [--pretty-print] [--include <exts>] [--exclude <exts>]
    [--output-path <file>] [--schema]
```

| Option | Description |
|---|---|
| `--type` | Type name to list members for |
| `--output-format` | json, compact, csv, short, jsonl |
| `--pretty-print` | Pretty-print JSON output |
| `--include` | Only files with these extensions |
| `--exclude` | Skip files with these extensions |
| `--output-path` | Write output to file instead of stdout |
| `--schema` | Print JSON Schema for output type and exit |

**Output type:** `MemberItem` — `{name, kind, file, line, column, signature, modifiers}`

---

### `complexity`

Measure cyclomatic complexity per function.

```
swift-package-tool complexity [<paths>...] [--min-complexity <n>]
    [--output-format <format>] [--pretty-print] [--include <exts>]
    [--exclude <exts>] [--limit <n>] [--output-path <file>] [--schema]
```

| Flag/Option | Description |
|---|---|
| `--min-complexity` | Only show functions with complexity >= this value |
| `--output-format` | json, compact, csv, short, jsonl |
| `--pretty-print` | Pretty-print JSON output |
| `--include` | Only files with these extensions |
| `--exclude` | Skip files with these extensions |
| `--limit` | Maximum results |
| `--output-path` | Write output to file instead of stdout |
| `--schema` | Print JSON Schema for output type and exit |

**Output type:** `ComplexityItem` — `{name, file, line, column, complexity, rating (simple|moderate|complex|very_complex)}`

---

### `diff`

Semantic declaration diff between two source files.

```
swift-package-tool diff <file1> <file2> [--output-format <format>]
    [--pretty-print] [--output-path <file>] [--schema]
```

| Argument | Description |
|---|---|
| `file1` | First source file (or `-` for stdin) |
| `file2` | Second source file (or `-` for stdin) |

| Flag/Option | Description |
|---|---|
| `--output-format` | json, compact, csv, short |
| `--pretty-print` | Pretty-print JSON output |
| `--output-path` | Write output to file instead of stdout |
| `--schema` | Print JSON Schema for output type and exit |

**Output type:** `DiffResult` — `{file1, file2, addedCount, removedCount, changedCount, added: [DiffDeclaration], removed: [DiffDeclaration], changed: [DiffChange]}`

---

### `tree`

Show a hierarchical symbol tree for Swift source files, formatted as indented Swift-like declarations. Designed for token-efficient agent consumption — no JSON keys, no brackets, just indented text.

```
swift-package-tool tree [<paths>...] [--include <exts>] [--exclude <exts>]
    [--output <file>]
```

| Argument | Description |
|---|---|
| `paths` | Files or directories to scan (default: `.`) |

| Flag/Option | Description |
|---|---|
| `--include` | Only files with these extensions (comma-separated) |
| `--exclude` | Skip files with these extensions (comma-separated) |
| `--output` | Write output to file instead of stdout |

**Output format:** Indented text with Swift-like syntax. Container types (struct, class, enum, protocol, extension) get `{ }` braces around their members. Imports and local variables inside function bodies are omitted.

```
// Sources/Example.swift
public struct Foo {
  private var x: Int
  public static func bar()
  enum Inner {
    case a
    case b
  }
}
```

---

### `validate`

Shallow syntax validation using SwiftParser's built-in diagnostics. Catches syntax-level errors (missing braces, invalid tokens, malformed declarations) without running the full compiler. Does not perform type-checking.

```
swift-package-tool validate [<paths>...] [--warnings] [--output-format <format>]
    [--pretty-print] [--output <file>]
```

| Flag/Option | Description |
|---|---|
| `--warnings` | Include warnings in addition to errors |
| `--output-format` | json, compact, short |
| `--pretty-print` | Pretty-print JSON output |
| `--output` | Write output to file instead of stdout |

**Output type:** `ValidateDiagnostic` — `{file, line, column, severity, message, diagnosticID, fixItCount}`

---

### `macro-expand`

Find and report macro expansion sites in Swift source files. Identifies where macros are used (`#externalMacro`, `#Predicate`, `#stringify`, etc.) and reports their locations, names, and arguments. Does NOT expand macros — that requires running the Swift compiler with the macro implementations loaded as compiler plugins.

```
swift-package-tool macro-expand [<paths>...] [--output-format <format>]
    [--pretty-print] [--output <file>]
```

| Flag/Option | Description |
|---|---|
| `--output-format` | json, compact, short |
| `--pretty-print` | Pretty-print JSON output |
| `--output` | Write output to file instead of stdout |

**Output type:** `MacroExpansion` — `{file, line, column, name, kind (declaration|expression), arguments}`

---

### `build`

Run `swift build` (or `swift test` with `--test`) and return structured output for LLM consumption. Parses build logs into a structured result.

```
swift-package-tool build [<target>] [--test] [--schema]
```

| Argument | Description |
|---|---|
| `target` | Target to build (default: the package's main target) |

| Flag/Option | Description |
|---|---|
| `--test` | Run `swift test` instead of `swift build` |
| `--schema` | Print JSON Schema for output type and exit |

**Output type:** `BuildResult` — `{success, target, duration, output, errors}`

---

### `force-unwraps`

Scan Swift source files for force-unwrap operations (`!`), classifying each occurrence as a force-unwrap, force-try, or force-cast. Uses AST-based detection.

```
swift-package-tool force-unwraps [<paths>...] [--output-format <format>]
    [--pretty-print] [--include <exts>] [--exclude <exts>]
```

| Flag/Option | Description |
|---|---|
| `--output-format` | json, compact, short |
| `--pretty-print` | Pretty-print JSON output |
| `--include` | Only files with these extensions (comma-separated) |
| `--exclude` | Skip files with these extensions (comma-separated) |

**Output type:** `ForceUnwrapItem` — `{file, line, column, context}`

---

### `docc-check`

Validate docc documentation comments by checking that symbol references (backtick-enclosed names in `///` comments) point to declarations that actually exist in the project. Catches stale or misspelled symbol paths. Does not resolve qualified names, module references, or external symbols.

```
swift-package-tool docc-check [<paths>...] [--output-format <format>]
    [--pretty-print] [--include <exts>] [--exclude <exts>]
```

| Flag/Option | Description |
|---|---|
| `--output-format` | json, compact, short |
| `--pretty-print` | Pretty-print JSON output |
| `--include` | Only files with these extensions (comma-separated) |
| `--exclude` | Skip files with these extensions (comma-separated) |

**Output type:** `DoccWarning` — `{file, line, column, severity, message, referencedSymbol}`

---

### `replace`

Find and replace text, or rename a symbol in a file.

**Arguments:**

| Argument | Description |
|---|---|
| `file` | File to edit (required) |

**Options:**

| Option | Description |
|---|---|
| `--old <text>` | Text to find (text mode) |
| `--new <text>` | Replacement text (text mode) |
| `--symbol <name>` | Symbol name to rename (AST mode) |
| `--rename <name>` | New name for the symbol (AST mode) |

**Common flags:** `--dry-run`, `--backup`, `--verify`, `--show-diff`, `--output`, `--force`

**Output type:** `EditResult` — `{file, modified, diff, verified, warning}`

---

### `insert`

Insert code at a precise location in a file.

**Arguments:**

| Argument | Description |
|---|---|
| `file` | File to edit (required) |

**Options:**

| Option | Description |
|---|---|
| `--content <text>` | Content to insert (required) |
| `--after <pattern>` | Insert after the first line containing this text |
| `--before <pattern>` | Insert before the first line containing this text |
| `--at-line <n>` | Insert at this absolute line number |

Content is auto-indented to match the target line.

---

### `delete`

Remove code by line range, symbol, or pattern.

**Arguments:**

| Argument | Description |
|---|---|
| `file` | File to edit (required) |

**Options:**

| Option | Description |
|---|---|
| `--lines <start>-<end>` | Line range to remove (e.g. `10-20`) |
| `--symbol <name>` | Symbol name to remove (AST-aware) |
| `--matching <pattern>` | Remove every line containing this text |

---

### `prepend`

Add code at the beginning of a file.

**Arguments:**

| Argument | Description |
|---|---|
| `file` | File to edit (required) |

**Options:**

| Option | Description |
|---|---|
| `--content <text>` | Content to prepend (required) |
| `--after-imports` | Insert after the last import statement |

---

### `append`

Add code at the end of a file.

**Arguments:**

| Argument | Description |
|---|---|
| `file` | File to edit (required) |

**Options:**

| Option | Description |
|---|---|
| `--content <text>` | Content to append (required) |

---

### `add-import`

Add an import statement to a file. Inserts alphabetically among existing imports. Skips if already present.

**Arguments:**

| Argument | Description |
|---|---|
| `file` | File to edit (required) |

**Options:**

| Option | Description |
|---|---|
| `--module <name>` | Module name to import (required) |

---

### `add-conformance`

Add a protocol conformance to a type. AST-aware — finds the type's inheritance clause and appends the protocol.

**Arguments:**

| Argument | Description |
|---|---|
| `file` | File to edit (required) |

**Options:**

| Option | Description |
|---|---|
| `--type <name>` | Type name to add conformance to (required) |
| `--protocol <name>` | Protocol name to conform to (required) |

---

### `add-member`

Add a property, method, or enum case to a type. AST-aware — finds the type's member block and inserts before the closing brace.

**Arguments:**

| Argument | Description |
|---|---|
| `file` | File to edit (required) |

**Options:**

| Option | Description |
|---|---|
| `--type <name>` | Type name to add the member to (required) |
| `--property <decl>` | Property declaration (e.g. `var x: Int`) |
| `--method <signature>` | Method signature (e.g. `func foo()`) |
| `--body <text>` | Method body (used with `--method`) |
| `--case <name>` | Enum case name |
| `--associated <types>` | Associated value types (comma-separated) |
| `--default <value>` | Default value for a property |
| `--access <modifier>` | Access modifier (public, private, internal) |

---

### `wrap`

Wrap selected lines in a syntactic container.

**Arguments:**

| Argument | Description |
|---|---|
| `file` | File to edit (required) |

**Options:**

| Option | Description |
|---|---|
| `--lines <start>-<end>` | Line range to wrap (required) |
| `--in <container>` | Container type: `do-catch`, `if-let`, `guard-let`, `do` (required) |
| `--variable <name>` | Variable name for `if-let`/`guard-let` |
| `--else <body>` | Else body for `guard-let` |

---

### `sort`

Sort members of a type alphabetically or by kind.

**Arguments:**

| Argument | Description |
|---|---|
| `file` | File to edit (required) |

**Options:**

| Option | Description |
|---|---|
| `--type <name>` | Type name to sort members of (required) |
| `--by <key>` | Sort key: `name` (default) or `kind` |

---

### `clean`

Delete build artifacts without touching dependencies. Runs `swift package clean` under the hood. The dependency cache (`.build/checkouts/`) is **preserved** — the next build recompiles without re-fetching.

To also **destroy** cached dependencies, pass `--purge-all` (or `--destroy-dependencies`). This is a destructive operation: every dependency is deleted from `.build/checkouts/` and must be re-fetched from scratch on the next build.

```
swift-package-tool clean [<path>] [--purge-all | --destroy-dependencies] [--pretty-print]
```

| Argument | Description |
|---|---|
| `path` | Package directory to clean (default: current directory) |

| Flag/Option | Description |
|---|---|
| `--purge-all`, `--destroy-dependencies` | ⚠️ **DESTRUCTIVE:** Delete ALL cached dependencies in addition to build artifacts. Every dependency is removed from `.build/checkouts/` and must be re-fetched from scratch on the next build. |
| `--pretty-print` | Pretty-print JSON output |

**Output type:** `CleanResult` — `{success, mode, directory, output}` — mode is `"clean (dependencies preserved)"` or `"purge-all (dependencies DESTROYED)"`.
