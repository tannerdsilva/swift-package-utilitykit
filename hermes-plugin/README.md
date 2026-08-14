# swift-package-inspector (Hermes plugin)

Narrow, pre-digested Swift package inspection and security-audit tools for
agent workers. Each tool constrains scope and returns structured JSON, so a
model (small or large) executes well-bounded checks instead of open-ended
reasoning.

## Tools (toolset `swift-package-inspector`)

| Tool | Purpose | Returns |
|---|---|---|
| `pkg_build` | Build the package (or a specific target) | pass/fail + structured warning/error/note counts, summary line, raw output tail |
| `pkg_scan` | Scan for security/code-quality issues | unified findings by category, severity counts, top findings. Categories: unsafe_ptrs, force_unwraps, process_safety, secrets |
| `pkg_list_dependencies` | List dependencies | name, requirement kind, pinned version. Use compact=true for names only |
| `pkg_list_targets` | List targets with source paths | name, type, file count, line count, per-file heatmap. Use compact=true for names/types only |
| `pkg_test` | Run tests | pass/fail, tests executed/failed, build-vs-test error disambiguation |
| `pkg_clean` | Remove audit build artifacts | confirmation that `.build-audit` was reset (never touches real `.build`/sources) |
| `pkg_docc_check` | DocC documentation analysis | coverage ratio, catalog layout, uncovered symbol inventory |
| `pkg_inspector` | One-call orientation | targets, deps, audit totals, build/test/docs verdicts, README intent, git state. Use compact=true for summary + counts only |

### Force-unwrap classification

`pkg_scan_force_unwraps` enriches each hit with a `primary` subkind and a
`subkinds` count breakdown so a triaging model/verifier can prioritize:

| `primary` | Meaning | Severity |
|---|---|---|
| `try_force` | `try!` on a throwing call (crash if it throws) | high |
| `as_cast` | `as!` forced cast (crash on type mismatch) | high |
| `force_unwrap` | plain `!` optional force-unwrap | medium |

A line with mixed forms (e.g. `try! g() as! String`) reports both counts and
sets `primary` to the most severe present. The stable `kind: "force_unwrap"`
field is preserved for backward compatibility (benchmark scoring and any
downstream parser that keys on `kind`).

### Triage summary

`pkg_stats_overview` is the entry point for small-model workers. Instead of
dumping hundreds of raw hits, it returns `totals` (findings by severity and
category), `per_file` (risk concentration), and `top_findings` (severity-ordered,
capped at 50), with the raw scan output kept under `details` for a follow-up
drill-down call.

### Severity model: reachability-aware

Every scan finding carries a stable `severity` key (`critical`/`high`/`medium`/
`low`) plus `context` (`source`/`test`) and `reachability`
(`input`/`internal`/`cleanup`). Severity is the operator's consequence adjusted
for how reachable that code path is, so the triage ranks what a reviewer should
look at rather than every raw `!` or pointer:

- **Test code** (`Tests/` or `*Tests.swift`) is only exercised by the harness, so
  its findings cap at `medium` even for `try!`/`as!`.
- **Cleanup paths** (close/cleanup/deinit/teardown/shutdown) rank `low`: nobody
  feeds them input at runtime.
- **Attacker-reachable members** (parse/decode/read/recv/url/request/handler/
  init) keep their operator consequence, so a `try!` on parsed input is genuinely
  `high`.
- **Internal utility code** (neither obviously reachable nor cleanup) caps
  high-consequence operators at `medium`, plain unwraps/reads at `low`.

`top_findings` sorts by severity then reachability (`input` before `internal`
before `cleanup`), so the headline list points at attacker-reachable findings
first. `severity_hint` remains on `unsafe_ptr` findings as a deprecated alias;
`severity` is the canonical key.

### Target listing

`pkg_list_targets` parses `Package.swift` and reports every target with its
resolved source path. It applies SwiftPM's default-path rules: a target with no
explicit `path:` resolves to `Sources/<name>` for regular targets (library,
executable, macro, system-library, plugin) and `Tests/<name>` for test targets.
Binary targets carry no source tree. Each entry reports the declared type
(`library`/`executable`/`test`/`macro`/`system_library`/`plugin`/`binary`), the
resolved absolute path, whether that directory exists on disk, and the count of
`.swift` files under it. Targets declared but not yet created on disk are still
listed with `exists: false`.

Since the model-facing summary, each target also carries a **per-file size/symbol
heatmap** that turns the raw path dump into a signal a model can act on:
`file_stats` (per file: relative path, `lines`, `symbols` as a `{kind: count}`
breakdown, `symbol_count`), plus target-level `total_lines`, `total_symbols`,
and `largest_files` (top 5 by line count). This is how a model learns "this
67-file library's core is `URL + Parser.swift`, 654 lines, 86 symbols" without
reading random paths.

### Orientation overview

`pkg_inspector` is the recommended first call on an unfamiliar package:
one compact JSON payload that answers "what is this, what shape is it, is it
healthy?" It composes the other tools and returns `summary` (a human-readable
one-liner), `readme_intent` (first README paragraph), a target→size table,
the package's largest files, dependency count + the risky subset, audit totals,
build/test verdicts, and doc coverage. Call it once to build a mental model,
then drill into individual tools or files.

The payload also surfaces **`agents_md`**: when the package root contains an
`AGENTS.md` (the canonical agent-orientation/instruction file), its content is
included (capped at 4000 chars) so a worker obeys project-specific conventions
without a second call. When absent, `agents_md` is `{"present": false}`.

The payload is also **diff-aware**: the `git` field reports whether the working
tree differs from HEAD (via `git status --porcelain`), listing the changed
files. This surfaces in-flight, uncommitted hardening work that a static scan of
the committed tree would miss. Build/derived artifacts (`.build-audit`,
`.build`, `.swiftpm`, `DerivedData`) are filtered so the diff reflects real
source changes, not the tool's own build caches.

### Process-safety scan

`pkg_scan_process_safety` covers the vulnerability classes a memory-safety
scan cannot: `fork()` without an immediate `exec()`/`_exit()` (post-fork work in
a multithreaded process), missing `O_CLOEXEC`/`FD_CLOEXEC` on fd-creating calls
(fd leaks across `exec()`), and raw `dup`/`fcntl`/`ioctl` fd-mutation that can
leak descriptors. `posix_spawn` is reported as a positive site (the safe
replacement for fork+exec), so reviewers can verify a migration. Reachability
and severity follow the same model as the other scans.

### Build / test / clean verdicts

`pkg_build` and `pkg_test` give small-model workers authoritative,
machine-checked results so they never guess whether a project builds or its
tests pass. `pkg_test` distinguishes three outcomes: tests pass, tests
fail, or the package fails to **compile** (a `build_errored` flag separates
toolchain/compiler errors from genuine test failures), and reports the executed
test count. Both build into an isolated `.build-audit/` directory so the audit
never pollutes the package's real build state. `pkg_clean` resets that
isolated dir (`swift package clean --build-path .build-audit`); it never touches
the real `.build` or checked-in sources.

### DocC documentation analysis

`pkg_docc_check` audits documentation *intent and completeness* at the source
level, no DocC binary required. It reports any `*.docc` catalogs (Swift-DocC
sources, with their markdown files), whether the manifest references a
`swift-docc-plugin` or `documentationTargets`, and a static measure of `///`
doc-comment coverage on public declarations across `Sources/` — declarations
counted, documented, the coverage ratio, and an inventory of *uncovered
symbols*. Each uncovered symbol is named (`name` + `kind`) with its `file` and
`line`, so a reviewer or worker can address them directly. Pass
`uncovered_limit` to bound that inventory (omit/0 for all). A package can be
well-documented inline (high coverage) yet ship no DocC catalog (poor
discoverable reference docs), and vice versa; the tool surfaces both signals so
a reviewer sees the gap.

## Design contract

- Every handler takes an explicit, bounded `target` (absolute path) and returns
  structured JSON. No open-ended shell, no raw exploration.
- `pkg_build` gives the model an authoritative build verdict so it
  cannot guess (or hallucinate) whether a project builds.
- Scope is further constrained at the profile level: give the worker profile
  only the `swift-package-inspector` toolset (plus `terminal`/`file`), not the full default
  surface.

## Install

```bash
hermes plugins install ~/workspace/swift-package-utilitykit/hermes-plugin  # local path, or a git URL
hermes plugins enable swift-package-utilitykit
```

For a Hermes worker profile, the plugin must also be symlinked into the
profile's own `plugins/` dir (profile-scoped discovery reads
`profiles/<name>/plugins/`, not the root `~/.hermes/plugins/`) and listed under
`plugins.enabled` — see the worker-profile section below.

## Test

The plugin is covered by a single, **model-free** assertion suite (no LLM
involved) that verifies the tools' pure functions directly — the right
bottom-up foundation before any model is handed the tools.

```bash
cd ~/workspace/swift-package-utilitykit/hermes-plugin
python3 test_tools.py        # assertion-based unit tests (parsers + docc/targets)
python3 test_tools.py --full # ... plus live build/test/clean on a fixture
```

`test_tools.py` hard-asserts on output shape and values (fails non-zero): the
`list_targets` default-path rules + size/symbol heatmap, `list_dependencies`
requirement kinds, force-unwrap classification, reachability-aware severity,
`scan_process_safety`, `docc_check` coverage + uncovered-symbol inventory,
`package_inspector` orientation (incl. AGENTS.md + git diff-awareness), and
(with `--full`) a live `build`/`test_check`/`clean` round-trip on a
generated dependency-free package.

The benchmark harness also gates these
via `bin/run_tool_tests.py`.

## Worker profile: `worker-basic-swift-package-inspector`

A Hermes worker profile pre-wired for a small local model (LFM 2.5 8b) with a
deliberately narrow tool surface, so the model stays on-scope. Point a kanban
card at it for narrow, well-bounded audit sub-tasks. The same narrow surface
works for a larger model (e.g. Qwen 35b) by swapping `model.default`.

| Setting | Value |
|---|---|
| model.default | `LFM2.5-8B-A1B-MLX-bf16` (host `.30`); any model the host serves |
| max_tokens | 131072 |
| platform_toolsets.cli | `swift-package-inspector`, `file`, `terminal` (`kanban` auto-appended by the dispatcher) |
| plugins.enabled | `swift-package-inspector` (plus a symlink into the profile's plugins dir so profile-scoped discovery finds it) |
| reasoning_effort | low |
| max_turns | 100 |

Two gotchas are worth remembering when wiring worker profiles:
- **Kanban workers get their toolset from `platform_toolsets.cli`, NOT the
  top-level `toolsets:` list.** A stale `platform_toolsets.cli` that names the
  `hermes-cli` composite expands to the full default bundle (web, browser,
  delegation, ...), silently leaking out-of-scope tools to the model.
- **Profile-scoped plugin discovery reads `profiles/<name>/plugins/`, not the
  root `~/.hermes/plugins/`.** A user plugin must be symlinked into the profile's
  plugins dir (and listed under `plugins.enabled`) for a worker to see its tools.

The `swift-package-inspector` + `file` + `terminal` surface is exactly the narrow scope the
model needs; `kanban` (auto-added by the dispatcher) lets it complete/report its
card. Everything else (web, browser, delegation, cron) is excluded so a small
model cannot drift into open-ended exploration.

## Add a tool

1. Add a pure function in `swift_package_inspector.py` (returns a JSON-ready dict).
2. Add a handler + schema in `__init__.py`.
3. Call `ctx.register_tool(...)` inside `register(ctx)`.
4. Extend `test_tools.py` and bump the registered-tool count in `register()`.