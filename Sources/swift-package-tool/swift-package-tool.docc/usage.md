# Usage

## Basic usage

```bash
swift-package-tool <subcommand> [options] [paths]
```

All subcommands accept one or more file paths or directories. When no
paths are given, most commands default to the current directory.

## Output formats

All commands support ``--output-format`` with these values:

- ``json`` — Pretty-printed JSON (human-readable)
- ``compact`` — Single-line JSON per array (default, LLM-optimized)
- ``csv`` — Comma-separated values
- ``short`` — Human-readable text summary
- ``jsonl`` — JSON Lines (one object per line)

## Common flags

| Flag | Description |
|------|-------------|
| ``--pretty-print`` | Force pretty-printed JSON output |
| ``--output <file>`` | Write output to file instead of stdout |
| ``--schema`` | Print JSON Schema for the output type and exit |
| ``--include <exts>`` | Only process files with these extensions |
| ``--exclude <exts>`` | Skip files with these extensions |
| ``--output-format <fmt>`` | Output format (json, compact, csv, short, jsonl) |

## Examples

```bash
# Find a symbol
swift-package-tool find "decode" Sources/

# List all public API
swift-package-tool api Sources/ --include-internal

# Build a project index
swift-package-tool index Sources/ --output index.json

# Scan for force-unwraps
swift-package-tool force-unwraps Sources/ --pretty-print

# Diff two files
swift-package-tool diff file1.swift file2.swift

# Get complexity metrics
swift-package-tool complexity Sources/ --limit 10
```
