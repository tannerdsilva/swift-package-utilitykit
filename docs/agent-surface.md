# the agent surface

how a harness (or the model driving one) should read this binary's answers —
the two dialects, the `EditResult` contract, and the read-before-write loop.
The frames below were **measured against the built binary**; the evaluation
method and the raw numbers live in
`.hermes/plans/2026-10-13_185044-v3.1.0-agent-read-and-envelope.md` (the read
half) and `.hermes/plans/apply-side/2026-10-16_140130-apply-side-hardening.md`
(the apply half).

## the two dialects

The same binary serves two dialects, and they have different failure contracts:

| | plugin one-shot (`{"tool": ..., "args": ...}`) | MCP JSON-RPC session (`initialize` -> `tools/call`) |
|---|---|---|
| success | `{"result":"<text>"}` | `{"jsonrpc":"2.0","id":N,"result":{"content":[{"type":"text","text":"..."}],"isError":false}}` |
| failure | `{"result":"Error: <text>"}` | same shape with `"isError":true` |
| exit code | always 0, including failures | n/a |

- The one-shot dialect **folds `isError` into the `Error: ` prefix on purpose**
  (swift-mcp's `MCPPluginDialect` documents the fold). A plugin-dialect consumer
  has no flag to read — match the prefix; the structured payload rides along
  after it.
- **Exit codes do not report tool outcomes on either dialect.** Read `status`
  on an `EditResult` payload, or the `Error: ` result prefix.

## the EditResult contract

Every edit verb (the CLI family and the `pkg_edit_*` tools alike) answers with
the same payload. The fields a consumer should read:

- **`status` is the truth.** `applied` and `alreadyCurrent` succeeded;
  `missed`, `blocked` and `failed` did not — a non-zero CLI exit mirrors the
  failure statuses.
- **`modified` describes the transform** — on a preview it says the edit
  *would* change the file.
- **`dryRun` describes the write.** `true` means the file on disk did not
  change (a preview, or a no-op path). `modified: true, dryRun: true` is a
  preview.
- **`verified` is the parse check.** `blocked` means the write was withheld
  because the edit would not parse (`--force` / `force` overrides).
- **`suggestions` appears on a miss** — the closest lines to the selector that
  matched nothing, numbered, best first, capped at 3. The `warning` names the
  first one, so a text-only consumer still gets the hint. Ties break toward a
  line that can be retried: **a code line beats a comment line**, then the line
  whose leading token matches the selector's, then the nearest indentation.

## read before you write

Measured: **50.5 % of this model's edit attempts missed their selector**, and
**27 of 28 classifiable misses aimed at text that does not exist in the file at
all**. An edit needs exact text; the surface returns it.

1. **`pkg_search`** — locate text across a package: every matching line, with
   its location and surrounding context.
2. **`pkg_read`** — the file's text with line numbers, bounded. `lines` reads
   a range; when output is bounded, the note says how many lines were withheld
   and which `--lines` reads on — truncation is never silent.
3. **`pkg_edit_*`** — the edit. On a miss the result teaches (see
   `suggestions`), so the next attempt can aim at real text.
4. **`pkg_build` / `pkg_test`** — the verdict.

## when a selector will not match

`replace` is text-only and exact. If `pkg_read` already gave you the lines and
`pkg_edit_replace` keeps missing the text, stop hunting for the selector:
**`pkg_edit_replace_range`** replaces lines A-B outright and never matches
anything.

- The line numbers are `pkg_read`'s — 1-based and inclusive, and a trailing
  newline does not open a new line.
- An end past the file clamps to the last line; `start > end` or `start < 1` is
  a usage error; a range that selects no lines is a `missed` result and the file
  is untouched.
- Content is taken verbatim and every content line inherits the indentation of
  the range's first line. Empty content is refused — use `pkg_edit_delete` to
  remove lines.
- It is **one call and one write**. There is no half-applied state to recover
  from — unlike `delete` + `insert`, where a failed second call leaves the
  deletion in place. Prefer this route.

## when several places must change together

**`pkg_edit_batch`** takes a whole plan in one round-trip. The plan goes inline
as `plan`, or as a plan file named by `path` — exactly one of the two. Inline is
the route that needs no setup: nothing on the surface can create a file.

- By default operations are sequential and continue-on-failure — a failed
  operation does not undo its predecessors.
- **`atomic: true`** makes the plan all-or-nothing: every operation is staged in
  memory and the touched files are written **only if every operation applied**.
  Use it whenever a partial landing would be worse than nothing.
- `fail_fast: true` stops at the first failure; combined with `atomic` it also
  writes nothing.
- Operation N sees operation N-1's staged result, so a plan can build on its own
  earlier steps within one call.

One honest limit: `atomic` is atomicity against *operation failure*, not
cross-file crash atomicity — POSIX cannot write two files as one. A single-file
plan is crash-atomic as well, because its one write goes through the same
atomic-write path every verb uses.

## paths and the shell

- MCP tool paths must be **absolute** (plugin tools run from the plugin
  directory); the CLI resolves relative paths against the working directory.
  A leading `~` expands on both.
- There is **no shell** between the caller and the tools: arguments are exact
  bytes. MCP content arguments are taken verbatim; the CLI expands `\n` / `\\`
  in content arguments for shell callers unless `--literal-content` is passed
  (the `pkg_edit_*` tools always pass it — JSON already decoded the escapes).