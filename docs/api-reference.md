# swift-code-query API Reference

## Overview

`swift-code-query` is a Swift source code analysis tool with 19 subcommands.
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
swift-code-query find <symbol> [<paths>...] [--exact] [--case-sensitive]
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
swift-code-query query [<paths>...] [--kind <kinds>] [--name <pattern>]
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
swift-code-query inspect <symbol> [<paths>...] [--output-format <format>]
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
swift-code-query format <files>... [--minify] [--preserve-indentation]
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
swift-code-query search <pattern> [<paths>...] [--regex] [--ignore-case]
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
swift-code-query references <symbol> [<paths>...] [--output-format <format>]
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
swift-code-query dependencies [<paths>...] [--output-format <format>]
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
swift-code-query index [<paths>...] [--output-format <format>]
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
swift-code-query api [<paths>...] [--include-internal] [--output-format <format>]
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
swift-code-query conformances [<paths>...] [--output-format <format>]
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
swift-code-query callgraph [<paths>...] [--output-format <format>]
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
swift-code-query members [<paths>...] --type <name> [--output-format <format>]
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
swift-code-query complexity [<paths>...] [--min-complexity <n>]
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
swift-code-query diff <file1> <file2> [--output-format <format>]
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
swift-code-query tree [<paths>...] [--include <exts>] [--exclude <exts>]
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
swift-code-query validate [<paths>...] [--warnings] [--output-format <format>]
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
swift-code-query macro-expand [<paths>...] [--output-format <format>]
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
swift-code-query build [<target>] [--test] [--schema]
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
swift-code-query force-unwraps [<paths>...] [--output-format <format>]
    [--pretty-print] [--include <exts>] [--exclude <exts>]
```

| Flag/Option | Description |
|---|---|
| `--output-format` | json, compact, short |
| `--pretty-print` | Pretty-print JSON output |
| `--include` | Only files with these extensions (comma-separated) |
| `--exclude` | Skip files with these extensions (comma-separated) |

**Output type:** `ForceUnwrapItem` — `{file, line, column, context}`
