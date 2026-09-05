# AGENTS.md — swift-package-inspector (swift-package-utilitykit)

## What this is

A Hermes Agent plugin providing 8 narrow, pre-digested Swift package inspection
and security-audit tools.  Designed for small-model workers (LFM 2.5 8b): each
tool constrains scope and returns structured JSON, so the model executes
well-bounded checks instead of open-ended reasoning.

## Architecture

```
Your agent
  │
  ├── pkg_build              → swift build (ephemeral scratch under .build/)
  ├── pkg_test               → swift test (ephemeral scratch under .build/)
  ├── pkg_clean              → sweep crashed-run scratch + legacy residue
  ├── pkg_list_dependencies  → swift package show-dependencies --format json
  ├── pkg_list_targets       → swift package describe --type json
  ├── pkg_docc_check         → swift-package-tool api + heuristic fallback
  ├── pkg_scan               → swift-package-tool search + Python post-processing
  └── pkg_inspector          → composes all above
```

The Python layer retains scope-clustering, severity-ranking, and
reachability-classification logic.  Everything else delegates to the Swift
toolchain for AST-guaranteed accuracy.

**Build/test isolation.** `pkg_build` and `pkg_test` compile into a fresh,
ephemeral scratch dir under the consumer package's own `.build`
(`.build/swift-package-audit/run-*`) that the call deletes before returning.
The tool keeps **no persistent build state** — every verdict is a clean-room
build of the current source — and never creates a new top-level directory in
the project; real `.build` products are never touched. `pkg_clean` sweeps
scratch dirs abandoned by crashed runs (older than 1h, so a live concurrent
audit is never removed) plus legacy `.build-audit` residue from the old
design.

## Recommended workflow

### 1. Orient with `pkg_inspector`

First call on an unfamiliar package.  Returns one compact JSON payload:
targets, deps, audit totals, build/test/docs verdicts, README intent, git state.

### 2. Scan with `pkg_scan`

```python
result = await call_tool("pkg_scan", {
    "target": "/path/to/project",
    "categories": ["unsafe_ptrs", "force_unwraps", "process_safety", "secrets"]
})
```

Returns findings with `severity`, `context` (source/test), and `reachability`
(input/internal/cleanup).  `top_findings` sorts by severity then reachability.

### 3. Inspect with `pkg_list_targets` / `pkg_list_dependencies`

```python
targets = await call_tool("pkg_list_targets", {"target": "/path/to/project", "compact": True})
deps = await call_tool("pkg_list_dependencies", {"target": "/path/to/project", "compact": True})
```

### 4. Verify with `pkg_build` + `pkg_test`

```python
build = await call_tool("pkg_build", {"target": "/path/to/project"})
test  = await call_tool("pkg_test",  {"target": "/path/to/project"})
```

### 5. Document with `pkg_docc_check`

```python
docs = await call_tool("pkg_docc_check", {"target": "/path/to/project", "uncovered_limit": 20})
```

## Prerequisites

- `swift-package-tool` binary in PATH (or set `SWIFT_CODE_QUERY_PATH` env var)
- Swift 6.0+ toolchain
- Hermes Agent with the plugin enabled

## Tool reference

| Tool | Purpose | Returns |
|---|---|---|
| `pkg_build` | Build the package | pass/fail + structured warning/error/note counts |
| `pkg_scan` | Security/code-quality scan | unified findings by category, severity counts |
| `pkg_list_dependencies` | List dependencies | name, requirement kind, pinned version |
| `pkg_list_targets` | List targets with source paths | name, type, file count, line count, heatmap |
| `pkg_test` | Run tests | pass/fail, tests executed/failed |
| `pkg_clean` | Sweep crashed-run scratch + legacy residue under `.build/` | `removed_runs` / `scratch_root` confirmation |
| `pkg_docc_check` | DocC documentation analysis | coverage ratio, uncovered symbol inventory |
| `pkg_inspector` | One-call orientation | targets, deps, audit totals, build/test/docs verdicts |

## Install

```bash
make install-plugin                    # from repo root
# or, directly against the built binary:
swift build -c release
.build/release/swift-package-tool install --copy    # copy plugin
.build/release/swift-package-tool install --symlink # symlink plugin
```
