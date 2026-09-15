# ``swift-package-tool``

A Swift source code analysis tool with 35 subcommands for code intelligence,
security auditing, and LLM-optimized formatting.

## Overview

``swift-package-tool`` is the analysis engine of ``swift-package-utilitykit``.
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
- ``TreeCommand``
- ``ValidateCommand``
- ``MacroExpandCommand``
- ``DoccCheckCommand``

### API & Conformances

- ``ApiCommand``
- ``ConformancesCommand``
- ``CallgraphCommand``
- ``MembersCommand``
- ``ComplexityCommand``
- ``DiffCommand``
- ``ForceUnwrapsCommand``

### Build & Clean

- ``BuildCommand``
- ``CleanCommand``

### Editing

- ``ReplaceCommand``
- ``InsertCommand``
- ``DeleteCommand``
- ``PrependCommand``
- ``AppendCommand``
- ``AddImportCommand``
- ``AddConformanceCommand``
- ``AddMemberCommand``
- ``WrapCommand``
- ``SortCommand``
- ``BatchCommand``

### Installation

- ``InstallCommand``
- ``UninstallCommand``
- ``PathWireCommand``

### Formatting

- ``FormatCommand``
- ``NormalizerCore``
