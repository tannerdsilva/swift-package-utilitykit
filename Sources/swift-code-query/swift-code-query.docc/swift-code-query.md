# ``swift-code-query``

A Swift source code analysis tool with 14 subcommands for code intelligence,
security auditing, and LLM-optimized formatting.

## Overview

``swift-code-query`` is the analysis engine of ``swift-package-utilitykit``.
It uses `swift-syntax` for AST-guaranteed parsing and produces compact JSON
output by default for token-efficient consumption by LLM agents.

## Topics

### Essentials

- <doc:installation>
- <doc:usage>

### Code Analysis

- ``FindCommand``
- ``QueryCommand``
- ``InspectCommand``
- ``SearchCommand``
- ``ReferencesCommand``
- ``DependenciesCommand``
- ``IndexCommand``

### API & Conformances

- ``ApiCommand``
- ``ConformancesCommand``
- ``CallgraphCommand``

### Metrics & Diff

- ``MembersCommand``
- ``ComplexityCommand``
- ``DiffCommand``
- ``ForceUnwrapsCommand``

### Formatting

- ``FormatCommand``
- ``NormalizerCore``
