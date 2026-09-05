"""swift-package-inspector core: narrow, pre-digested Swift package inspection
and security-audit primitives.

ARCHITECTURE (refactored 2026-08-13):
  Code-analysis logic (scanning, querying, indexing) has been moved into the
  ``swift-package-tool`` binary (swift-package-utilitykit).  This Python module
  is now a thin orchestration layer that:
    - Calls ``swift-package-tool`` for code analysis (scans, API surface, index)
    - Calls ``swift package show-dependencies --format json`` for dependencies
    - Calls ``swift package describe --type json`` for target metadata
    - Calls ``swift build`` / ``swift test`` for build/test (each run gets a
      fresh ephemeral scratch dir under the package's own ``.build``, deleted
      when the run finishes — no persistent build state, no new top-level
      dir) and sweeps crashed-run leftovers on clean

  This eliminates ~1200 lines of regex-based parsing and AST heuristics from
  the Python layer, replacing them with the AST-guaranteed output of the Swift
  binary.

Design contract (for small-model workers like LFM 2.5 2.6B):
  - Each function takes an explicit, bounded target (an absolute path) and
    returns structured JSON-ready dicts.  No open-ended exploration, no
    free-form shell.
  - The model calls a function, reads the digest, records findings.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Dict, List, Optional

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

# Path to the swift-package-tool binary.  Resolved once at import time.
# Preference order: SWIFT_CODE_QUERY_PATH env override > PATH lookup.
# Last-resort fallback matches the Makefile/install.sh default install
# location (~/.local/bin, user-local, no sudo) so the resolver and the
# installer agree on where the binary lives.
_DEFAULT_SWIFT_CODE_QUERY = os.path.expanduser("~/.local/bin/swift-package-tool")
_SWIFT_CODE_QUERY = os.environ.get(
    "SWIFT_CODE_QUERY_PATH",
    shutil.which("swift-package-tool") or _DEFAULT_SWIFT_CODE_QUERY,
)


def _run_swift_code_query(args: list[str], timeout: int = 120) -> dict:
    """Run swift-package-tool with the given args and return parsed JSON.

    The return value is a single, unambiguous contract:

      success: {"ok": True, "data": <parsed JSON (dict or list)>,
                "stdout": <raw text>, "stderr": <raw text>, "exit_code": <int>}
      failure: {"ok": False, "error": "<message>", "stdout": ..., "stderr": ...,
                "exit_code": <int or None>}

    ``data`` carries the verbatim JSON payload — for array-emitting
    subcommands (`search`, `api`, `force-unwraps`, `build`, `test`) that is a
    *list*, for object-emitting ones (`index`, `dependencies --grouped`) a
    *dict*.  Callers check ``ok`` first and then read ``data``; they must not
    assume ``data`` is a dict.
    """
    try:
        proc = subprocess.run(
            [_SWIFT_CODE_QUERY] + args,
            capture_output=True, text=True, timeout=timeout,
        )
    except FileNotFoundError:
        return {"ok": False, "error": f"swift-package-tool not found at {_SWIFT_CODE_QUERY}",
                "stdout": "", "stderr": "", "exit_code": None}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": f"swift-package-tool timed out after {timeout}s",
                "stdout": "", "stderr": "", "exit_code": None}

    if proc.returncode != 0:
        return {"ok": False, "error": proc.stderr.strip() or proc.stdout.strip(),
                "stdout": proc.stdout, "stderr": proc.stderr, "exit_code": proc.returncode}

    try:
        data = json.loads(proc.stdout)
    except (json.JSONDecodeError, ValueError) as exc:
        return {"ok": False, "error": f"failed to parse swift-package-tool output: {exc}",
                "stdout": proc.stdout, "stderr": proc.stderr, "exit_code": proc.returncode}

    return {"ok": True, "data": data,
            "stdout": proc.stdout, "stderr": proc.stderr, "exit_code": proc.returncode}


def _run_swift(args: list[str], cwd: str, timeout: int = 600) -> subprocess.CompletedProcess:
    """Run a swift CLI command and return the completed process."""
    return subprocess.run(
        args, cwd=cwd, capture_output=True, text=True, timeout=timeout,
    )


def _resolve_target(target: str) -> str:
    """Resolve a possibly-relative target against cwd; validate existence."""
    p = Path(target).expanduser()
    if not p.is_absolute():
        p = Path.cwd() / p
    p = p.resolve()
    if not p.exists():
        raise ValueError(f"target does not exist: {p}")
    return str(p)


def _package_path(target: str) -> Path:
    """Find Package.swift for target (target itself, else a containing dir)."""
    t = Path(target)
    cand = t / "Package.swift" if t.is_dir() else t.parent / "Package.swift"
    return cand


# Root, per package, for audit build scratch: a subdirectory of the package's
# own .build (the standard SwiftPM derived-data location, gitignored by
# convention), so an audit never creates a new top-level directory in the
# project.  the tool still keeps no persistent build state: each build/test
# run gets a fresh, empty run-* subdir that it removes when the run finishes,
# so nothing on disk can go stale or drift from the current source.  only
# crashed runs leave residue here, swept by clean().
def _audit_root(pkg_dir: Path) -> Path:
    """The audit scratch root for a package: ``<pkg>/.build/swift-package-audit``."""
    return pkg_dir / ".build" / "swift-package-audit"


# run dirs under _audit_root() older than this are considered abandoned (a
# live concurrent audit never sits idle that long) and are swept by clean().
_STALE_RUN_AGE_SECONDS = 3600


def _new_scratch(pkg_dir: Path) -> Path:
    """Create a fresh, empty scratch dir for a single audit build/test run.

    the created dir lives under ``<pkg>/.build/swift-package-audit/`` — never
    a new top-level dir — and is owned by the caller, which must remove it
    when the run finishes. every run starts from a clean slate, so an audit
    verdict always reflects the current source with no cached incremental
    state that could be corrupt or out of alignment.
    """
    root = _audit_root(pkg_dir)
    root.mkdir(parents=True, exist_ok=True)
    return Path(tempfile.mkdtemp(prefix="run-", dir=str(root)))


def _iter_swift_files(root: str) -> list[Path]:
    """Return all .swift files under root, excluding .build and .git."""
    root_path = Path(root)
    results: list[Path] = []
    if not root_path.exists():
        return results
    skip = {".build", ".build-audit", ".git", ".swiftpm"}
    for dirpath, dirnames, filenames in os.walk(root_path):
        dirnames[:] = [d for d in dirnames if d not in skip]
        for fn in filenames:
            if fn.endswith(".swift"):
                results.append(Path(dirpath) / fn)
    results.sort()
    return results


# ---------------------------------------------------------------------------
# Tool 1: pkg_build
# ---------------------------------------------------------------------------

# Patterns for parsing Swift build diagnostics.
_BUILD_WARNING_RE = re.compile(r"^.*?(?:warning:\s|:\s*warning:\s).*$", re.MULTILINE)
_BUILD_ERROR_RE = re.compile(r"^.*?(?:error:\s|:\s*error:\s).*$", re.MULTILINE)
_BUILD_NOTE_RE = re.compile(r"^.*?(?:note:\s|:\s*note:\s).*$", re.MULTILINE)


def _parse_build_diagnostics(stdout: str, stderr: str) -> dict:
    """Parse combined build output for warning/error/note counts and samples."""
    combined = stdout + "\n" + stderr
    warnings = _BUILD_WARNING_RE.findall(combined)
    errors = _BUILD_ERROR_RE.findall(combined)
    notes = _BUILD_NOTE_RE.findall(combined)
    warn_unique = list(dict.fromkeys(warnings))[:10]
    err_unique = list(dict.fromkeys(errors))[:10]
    note_unique = list(dict.fromkeys(notes))[:10]
    return {
        "warning_count": len(warnings),
        "error_count": len(errors),
        "note_count": len(notes),
        "warnings": [w.strip() for w in warn_unique],
        "errors": [e.strip() for e in err_unique],
        "notes": [n.strip() for n in note_unique],
        "has_warnings": len(warnings) > 0,
        "has_errors": len(errors) > 0,
    }


def build(target: str, build_args: Optional[List[str]] = None,
          build_target: Optional[str] = None) -> dict:
    """Run ``swift build`` via ``swift-package-tool build`` and return structured JSON.

    Delegates to the Swift binary which parses the raw build output into
    structured phases, diagnostics, and a summary — much more LLM-friendly
    than raw stdout. builds in a fresh ephemeral scratch dir under the
    package's own ``.build`` that this call removes when it finishes — no
    persistent build state, and the real ``.build`` products are untouched.
    """
    target = _resolve_target(target)
    pkg = _package_path(target)
    pkg_dir = pkg.parent

    scratch = _new_scratch(pkg_dir)
    try:
        # note: the binary path is not repeated here — _run_swift_code_query
        # prepends it. doubling it breaks argument parsing (the binary ends up
        # consumed as find's <symbol> and --timeout is rejected).
        cmd = ["build", str(pkg_dir), "--timeout", "600"]
        if build_target:
            cmd += ["--target", build_target]
        if build_args:
            # pass extra args as a single string; = form avoids the
            # dash-prefixed-value rejection
            cmd += [f"--extra-args={' '.join(build_args)}"]
        # build into a fresh ephemeral scratch dir under .build that this call
        # removes when it finishes — no persistent build state, and the real
        # .build products are never touched
        cmd += [f"--extra-args=--scratch-path {scratch}"]
        cmd += ["--output-format", "json"]

        try:
            result = _run_swift_code_query(cmd)
        except Exception as exc:
            return {"ok": False, "build_succeeded": False,
                    "error": f"swift-package-tool build failed: {exc}",
                    "stdout": "", "stderr": "", "exit_code": None,
                    "diagnostics": {"warning_count": 0, "error_count": 0, "note_count": 0,
                                   "has_warnings": False, "has_errors": False}}

        if not result.get("ok", True) or "error" in result:
            return {"ok": False, "build_succeeded": False,
                    "error": result.get("error", "unknown error"),
                    "stdout": "", "stderr": "", "exit_code": None,
                    "diagnostics": {"warning_count": 0, "error_count": 0, "note_count": 0,
                                   "has_warnings": False, "has_errors": False}}

        try:
            raw = result.get("data")
            if raw is None:
                raise KeyError("missing data")
            if isinstance(raw, list) and len(raw) == 1:
                raw = raw[0]
        except (KeyError, IndexError) as exc:
            return {"ok": False, "build_succeeded": False,
                    "error": f"failed to parse build result: {exc}",
                    "stdout": str(result.get("stdout", "")),
                    "stderr": str(result.get("stderr", "")), "exit_code": None,
                    "diagnostics": {"warning_count": 0, "error_count": 0, "note_count": 0,
                                   "has_warnings": False, "has_errors": False}}

        diag = raw.get("diagnostics", {})
        return {
            "ok": True,
            "build_succeeded": raw.get("succeeded", False),
            "exit_code": raw.get("exitCode"),
            "target": target,
            "package_path": str(pkg_dir),
            "duration": raw.get("duration", 0),
            "phases": raw.get("phases", []),
            "diagnostics": {
                "warning_count": diag.get("warningCount", 0),
                "error_count": diag.get("errorCount", 0),
                "note_count": diag.get("noteCount", 0),
                "warnings": [w.get("message", "") for w in diag.get("warnings", [])],
                "errors": [e.get("message", "") for e in diag.get("errors", [])],
                "notes": [n.get("message", "") for n in diag.get("notes", [])],
                "has_warnings": diag.get("warningCount", 0) > 0,
                "has_errors": diag.get("errorCount", 0) > 0,
            },
            "summary": raw.get("summary", ""),
            "raw_log": raw.get("rawLog", ""),
        }
    finally:
        # the scratch dir is wholly owned by this run — remove it and the
        # now-empty audit dirs so no build state survives the call
        shutil.rmtree(scratch, ignore_errors=True)
        try:
            _audit_root(pkg_dir).rmdir()
        except OSError:
            pass  # concurrent run still active, or root not empty
        try:
            (pkg_dir / ".build").rmdir()
        except OSError:
            pass  # package's own build products exist — never touch them


# ---------------------------------------------------------------------------
# Tool 1b: pkg_test
# ---------------------------------------------------------------------------

def test(target: str, filter: Optional[str] = None) -> dict:
    """Run ``swift test`` via ``swift-package-tool build --test`` and return structured JSON.

    The test build runs in a fresh ephemeral scratch dir under the package's
    own ``.build`` that this call removes when it finishes, so the consumer
    package's real build products are never touched and no build state
    survives the run (see ``clean()``).
    """
    target = _resolve_target(target)
    pkg = _package_path(target)
    if not pkg.exists():
        return {"ok": False, "test_succeeded": False, "error": f"no Package.swift at {pkg}"}
    pkg_dir = pkg.parent

    scratch = _new_scratch(pkg_dir)
    try:
        # note: same as build() — no binary path here, _run_swift_code_query adds it
        cmd = ["build", str(pkg_dir), "--test", "--timeout", "1200",
               "--output-format", "json"]
        if filter:
            cmd += ["--filter", filter]
        # isolate the test build in a fresh ephemeral scratch dir under .build
        # that this call removes when it finishes — no persistent build state,
        # and the real .build products are never touched. use the = form:
        # argument-parser rejects a dash-prefixed option value.
        cmd += [f"--extra-args=--scratch-path {scratch}"]

        try:
            result = _run_swift_code_query(cmd)
        except Exception as exc:
            return {"ok": False, "test_succeeded": False,
                    "error": f"swift-package-tool build --test failed: {exc}",
                    "stdout": "", "stderr": "", "exit_code": None}

        if not result.get("ok", True) or "error" in result:
            return {"ok": False, "test_succeeded": False,
                    "error": result.get("error", "unknown error"),
                    "stdout": "", "stderr": "", "exit_code": None}

        try:
            raw = result.get("data")
            if raw is None:
                raise KeyError("missing data")
            if isinstance(raw, list) and len(raw) == 1:
                raw = raw[0]
        except (KeyError, IndexError) as exc:
            return {"ok": False, "test_succeeded": False,
                    "error": f"failed to parse test result: {exc}",
                    "stdout": str(result.get("stdout", "")),
                    "stderr": str(result.get("stderr", "")), "exit_code": None}

        # parse executed/failed test counts from the run log. XCTest emits
        # "Executed N tests, with M failures" and Swift Testing emits
        # "Test run with N tests in M suites".
        raw_log = raw.get("rawLog", "") or ""
        tests_total: Optional[int] = None
        tests_failed: Optional[int] = None
        m = re.search(r"Executed (\d+) tests?, with (\d+) failure", raw_log)
        if m:
            tests_total = int(m.group(1))
            tests_failed = int(m.group(2))
        else:
            m = re.search(r"Test run with (\d+) tests? in", raw_log)
            if m:
                tests_total = int(m.group(1))
                tests_failed = 0
        no_tests = (tests_total == 0) if tests_total is not None else \
            ("no tests found" in raw_log.lower() or "no test" in raw_log.lower())

        diag = raw.get("diagnostics", {})
        return {
            "ok": True,
            "test_succeeded": raw.get("succeeded", False),
            "exit_code": raw.get("exitCode"),
            "target": target,
            "package_path": str(pkg_dir),
            "duration": raw.get("duration", 0),
            "tests_total": tests_total,
            "tests_failed": tests_failed,
            "no_tests": no_tests,
            "phases": raw.get("phases", []),
            "diagnostics": {
                "warning_count": diag.get("warningCount", 0),
                "error_count": diag.get("errorCount", 0),
                "note_count": diag.get("noteCount", 0),
                "warnings": [w.get("message", "") for w in diag.get("warnings", [])],
                "errors": [e.get("message", "") for e in diag.get("errors", [])],
                "notes": [n.get("message", "") for n in diag.get("notes", [])],
                "has_warnings": diag.get("warningCount", 0) > 0,
                "has_errors": diag.get("errorCount", 0) > 0,
            },
            "summary": raw.get("summary", ""),
            "raw_log": raw_log,
        }
    finally:
        # the scratch dir is wholly owned by this run — remove it and the
        # now-empty audit dirs so no build state survives the call
        shutil.rmtree(scratch, ignore_errors=True)
        try:
            _audit_root(pkg_dir).rmdir()
        except OSError:
            pass  # concurrent run still active, or root not empty
        try:
            (pkg_dir / ".build").rmdir()
        except OSError:
            pass  # package's own build products exist — never touch them


# ---------------------------------------------------------------------------
# Tool 1c: pkg_clean
# ---------------------------------------------------------------------------

def clean(target: str) -> dict:
    """Remove audit build artifacts (ephemeral, non-destructive).

    every build()/test() run uses a fresh scratch dir under
    ``<pkg>/.build/swift-package-audit/`` that it deletes when done, so the
    tool normally leaves nothing to clean. this method sweeps any leftover
    scratch dirs abandoned by crashed runs (those older than
    ``_STALE_RUN_AGE_SECONDS``, so a concurrent live audit is never touched)
    and removes legacy pre-ephemeral ``.build-audit`` residue from the package
    dir. the package's real ``.build`` products and sources are never touched.
    """
    target = _resolve_target(target)
    pkg = _package_path(target)
    if not pkg.exists():
        return {"ok": False, "cleaned": False, "error": f"no Package.swift at {pkg}"}
    pkg_dir = pkg.parent

    root = _audit_root(pkg_dir)
    removed_runs = 0
    now = time.time()
    if root.exists():
        for entry in root.iterdir():
            try:
                if entry.is_dir() and (now - entry.stat().st_mtime) > _STALE_RUN_AGE_SECONDS:
                    shutil.rmtree(entry, ignore_errors=True)
                    removed_runs += 1
            except OSError:
                continue
        try:
            root.rmdir()
        except OSError:
            pass  # live runs remain under the root

    # legacy residue from the pre-ephemeral design (deterministic .build-audit)
    legacy = pkg_dir / ".build-audit"
    if legacy.exists():
        shutil.rmtree(legacy, ignore_errors=True)

    return {
        "ok": True,
        "cleaned": True,
        "exit_code": 0,
        "target": target,
        "package_path": str(pkg_dir),
        "scratch_root": str(root),
        "removed_runs": removed_runs,
        "removed_legacy_build_audit": not legacy.exists(),
        "note": "Audit builds use ephemeral scratch dirs under "
                "<pkg>/.build/swift-package-audit/ that clean up after "
                "themselves; this swept crashed-run leftovers and legacy "
                ".build-audit residue. the package's real .build products "
                "and sources are untouched.",
    }


# ---------------------------------------------------------------------------
# Tool 2-5: Scanning (delegated to swift-package-tool search)
# ---------------------------------------------------------------------------

# Regex patterns for each scan category.  These are passed to
# ``swift-package-tool search`` as the search pattern.  The Python layer
# post-processes the results for scope clustering and severity ranking.
_UNSAFE_PTR_PATTERNS: list[tuple] = [
    ("UnsafePointer", r"\bUnsafePointer\b"),
    ("UnsafeMutablePointer", r"\bUnsafeMutablePointer\b"),
    ("UnsafeRawPointer", r"\bUnsafeRawPointer\b"),
    ("UnsafeMutableRawPointer", r"\bUnsafeMutableRawPointer\b"),
    ("UnsafeBufferPointer", r"\bUnsafeBufferPointer\b"),
    ("withUnsafeBytes", r"\bwithUnsafeBytes\b"),
    ("withUnsafeMutableBytes", r"\bwithUnsafeMutableBytes\b"),
    ("withUnsafeBufferPointer", r"\bwithUnsafeBufferPointer\b"),
    ("withUnsafePointer", r"\bwithUnsafePointer\b"),
    ("Unmanaged", r"\bUnmanaged\b"),
    ("unsafeBitCast", r"\bunsafeBitCast\b"),
    ("unsafeDowncast", r"\bunsafeDowncast\b"),
    ("unsafeAddressOf", r"\bunsafeAddressOf\b"),
]

_FORCE_UNWRAP_RE = re.compile(r"(?<=[\w\]\)\"'])\!(?![=\~])")

_SECRET_PATTERNS: list[tuple] = [
    ("aws_access_key", r"\bAKIA[0-9A-Z]{16}\b"),
    ("aws_secret_key",
     r"\b(?:aws)?_?secret[_ ]?access[_ ]?key\s*[:=]\s*[\"'][A-Za-z0-9/+=]{20,}[\"']"),
    ("github_token", r"\bgh[pousr]_[A-Za-z0-9]{36,}\b"),
    ("bearer_token", r"(?:bearer|authorization)\s+sk_(?:live|test)_[A-Za-z0-9]{16,}"),
    ("stripe_key", r"\bsk_(?:live|test)_[A-Za-z0-9]{16,}\b"),
    ("private_key", r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    ("generic_password",
     r"(?:password|passwd|pwd|secret)\s*[:=]\s*[\"'][^\"']{6,}[\"']"),
    ("api_key", r"\bapi[_ ]?key\s*[:=]\s*[\"'][A-Za-z0-9]{16,}[\"']"),
]

_PROCESS_SAFETY_PATTERNS: list[tuple] = [
    ("raw_fork_without_exec", r"\bfork\(\)"),
    ("posix_spawn", r"\bposix_spawn(?:p)?\s*\("),
    ("missing_cloexec",
     r"\b(?:open|openat|socket|socketpair|pipe2?|dup)\s*\([^;]*?(?!O_CLOEXEC|FD_CLOEXEC)"),
    ("fd_mutation", r"\bdup(?:2|3)?\s*\(|\bfcntl\s*\(|\bioctl\s*\("),
    ("fork_and_handoff", r"\bexecve?\s*\(|\bexecvp\s*\(|\bexecl(?:p|pe)?\s*\("),
]

_LABEL_PRIORITY = [
    "private_key", "aws_secret_key", "aws_access_key", "github_token",
    "bearer_token", "stripe_key", "api_key", "generic_password",
]


def _search_with_swift_code_query(pattern: str, target: str,
                                   is_regex: bool = True) -> list[dict]:
    """Run ``swift-package-tool search`` and return the parsed matches.

    Returns a list of dicts with at least ``file``, ``line``, ``column``,
    ``line_content`` fields.  Raises ``RuntimeError`` on failure so callers
    can surface the error instead of silently returning empty results.
    """
    args = ["search", pattern, target, "--output-format", "compact"]
    if is_regex:
        args.append("--regex")
    result = _run_swift_code_query(args)
    if not result.get("ok", True) or "error" in result:
        raise RuntimeError(
            f"swift-package-tool search failed: {result.get('error', 'unknown error')}"
        )
    # swift-package-tool search returns a JSON array of SearchMatch objects.
    data = result.get("data")
    if isinstance(data, list):
        return data
    return []


def _scan_with_swift_code_query(
    patterns: list[tuple[str, str]],
    target: str,
) -> list[dict]:
    """Run ``swift-package-tool search`` with a combined regex from *patterns*.

    Each pattern is a ``(display_name, regex)`` pair.  The helper builds a
    combined regex (``pat1|pat2|...``), runs the search, and attaches the
    matching ``display_name`` to each result by re-testing the line content.

    Returns a list of dicts with at least ``file``, ``line``, ``line_content``,
    and ``api`` (the display name of the matched pattern).
    """
    if not patterns:
        return []

    # build a combined regex with named groups so we can identify which
    # pattern matched.  use non-capturing groups for the individual patterns.
    combined = "|".join(f"(?:{pat})" for _, pat in patterns)
    try:
        matches = _search_with_swift_code_query(combined, target, is_regex=True)
    except RuntimeError:
        return []

    # re-test each match's line content to determine which pattern fired.
    # the tool emits the field as `lineContent` (camelCase).
    results: list[dict] = []
    for m in matches:
        line = m.get("lineContent", m.get("line_content", ""))
        for display, pat in patterns:
            if re.search(pat, line):
                results.append({
                    "file": m.get("file", ""),
                    "line": m.get("line", 0),
                    "column": m.get("column", 0),
                    "lineContent": line,
                    "line_content": line,
                    "api": display,
                })
                break  # first match wins
    return results


def _is_test_source(path: str) -> bool:
    """True if a Swift file lives in a test target or is a *Tests.swift file."""
    s = path.replace("\\", "/")
    return "/Tests/" in s or s.endswith("Tests.swift")


def _function_scopes(lines: list[str]) -> list[int]:
    """Return a per-line scope id (0 = file/module scope) using brace depth."""
    scope_ids = [0] * len(lines)
    depth = 0
    stack: list[tuple[int, int]] = []
    next_id = 1
    for idx, line in enumerate(lines):
        stripped = line.strip()
        is_comment = stripped.startswith("//")
        is_control_flow = bool(re.match(
            r"\b(?:guard|if|for|while|switch|case|catch|repeat|return)\b", stripped))
        opens_scope = (not is_comment and not is_control_flow) and bool(re.search(
            r"\b(?:func|init|deinit|subscript)\b|"
            r"\b(?:var|let)\b[^{]*\{", stripped))
        for ch in line:
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
        while stack and depth < stack[-1][1]:
            stack.pop()
        if opens_scope:
            stack.append((next_id, depth))
            next_id += 1
            scope_ids[idx] = stack[-1][0]
        elif stack:
            scope_ids[idx] = stack[-1][0]
    return scope_ids


def _enclosing_member(lines: list[str], scope_ids: list[int], line_idx: int) -> str:
    """Return the member declaration line that owns ``line_idx`` (or '')."""
    if line_idx < 0 or line_idx >= len(lines):
        return ""
    sid = scope_ids[line_idx]
    if sid == 0:
        return ""
    for i in range(line_idx, -1, -1):
        if scope_ids[i] == sid:
            m = re.search(
                r"\b(?:func|init|deinit|subscript)\b\s*([A-Za-z0-9_]+)?", lines[i])
            if m:
                return m.group(0)
    return ""


def _reachability(member: str) -> str:
    """Classify a member's input reachability by its declaration name."""
    if not member:
        return "internal"
    if re.search(
        r"parse|decode|read|recv|url|request|response|handler|input|load|"
        r"fetch|receive|init\b|unwrap|convert|deserialize|message", member, re.I,
    ):
        return "input"
    if re.search(
        r"close|cleanup|deinit|teardown|shutdown|remove|free|destroy|stop|"
        r"cancel|invalidate|dispose", member, re.I,
    ):
        return "cleanup"
    return "internal"


def _severity_from(context: str, reach: str, base: str) -> str:
    """Rank a finding from consequence (``base``) plus reachability/context."""
    if context == "test":
        return "medium" if base == "high" else "low"
    if reach == "cleanup":
        return "low"
    if reach == "input":
        return base
    return "medium" if base == "high" else "low"


def _severity_for(api: str) -> str:
    high = {"unsafeBitCast", "unsafeDowncast", "unsafeAddressOf", "Unmanaged"}
    med = {"UnsafePointer", "UnsafeMutablePointer", "UnsafeRawPointer",
           "UnsafeMutableRawPointer", "UnsafeBufferPointer",
           "withUnsafeBytes", "withUnsafeMutableBytes",
           "withUnsafeBufferPointer", "withUnsafePointer"}
    return "high" if api in high else ("medium" if api in med else "low")


def scan_unsafe_ptrs(target: str) -> dict:
    """Scan Swift sources for unsafe pointer / memory API usage.

    Delegates regex matching to ``swift-package-tool search`` for consistency
    with the AST-level tool, then post-processes for scope clustering and
    severity ranking (same logic as the original Python-only version).
    """
    target = _resolve_target(target)
    raw = _scan_with_swift_code_query(_UNSAFE_PTR_PATTERNS, target)
    if not raw:
        return {"ok": True, "target": target, "count": 0, "findings": []}

    # group by file for scope clustering
    by_file: dict[str, list[dict]] = {}
    for hit in raw:
        by_file.setdefault(hit["file"], []).append(hit)

    findings: list[dict] = []
    for file_path, hits in by_file.items():
        try:
            lines = open(file_path, encoding="utf-8", errors="replace").read().splitlines()
        except Exception as exc:
            findings.append({
                "file": file_path, "line": 0, "api": "READ_ERROR",
                "match": str(exc), "severity_hint": "low",
            })
            continue

        scopes = _function_scopes(lines)
        clustered: dict[int, list] = {}
        for hit in hits:
            sid = scopes[hit["line"] - 1]
            clustered.setdefault(sid, []).append(hit["line"])

        context = "test" if _is_test_source(file_path) else "source"
        for sid, hit_lines in clustered.items():
            rep = min(hit_lines)
            api = next(h["api"] for h in hits if h["line"] == rep)
            member = _enclosing_member(lines, scopes, rep - 1)
            reach = _reachability(member)
            base = _severity_for(api)
            findings.append({
                "file": file_path, "line": rep, "api": api, "match": api,
                "severity_hint": _severity_for(api),
                "severity": _severity_from(context, reach, base),
                "context": context, "reachability": reach,
                "related_lines": sorted(set(hit_lines)),
            })

    seen = set()
    unique: list[dict] = []
    for f in findings:
        key = (f["file"], f["line"], f["api"])
        if key not in seen:
            seen.add(key)
            unique.append(f)
    return {"ok": True, "target": target, "count": len(unique), "findings": unique}


def scan_force_unwraps(target: str) -> dict:
    """Scan Swift sources for force-unwrap ``!`` usage, classified by subkind.

    Delegates to ``swift-package-tool force-unwraps`` for AST-guaranteed
    detection, then post-processes for scope clustering and severity ranking.
    """
    target = _resolve_target(target)
    cmd = ["force-unwraps", target,
           "--output-format", "json"]
    result = _run_swift_code_query(cmd)
    if not result.get("ok", True) or "error" in result:
        # fall back to regex-based scan
        return _scan_force_unwraps_fallback(target)

    try:
        raw = result.get("data")
        if not isinstance(raw, list):
            return _scan_force_unwraps_fallback(target)
    except (KeyError, TypeError):
        return _scan_force_unwraps_fallback(target)

    if not raw:
        return {"ok": True, "target": target, "count": 0, "findings": []}

    # group by file for scope analysis
    files_data: dict[str, list[dict]] = {}
    for item in raw:
        f = item["file"]
        files_data.setdefault(f, []).append(item)

    findings: list[dict] = []
    for file_path, items in files_data.items():
        try:
            lines = Path(file_path).read_text(encoding="utf-8", errors="replace").splitlines()
        except Exception:
            lines = []
        scopes = _function_scopes(lines)

        for item in items:
            idx = item["line"]
            kind = item["kind"]
            context = "test" if _is_test_source(file_path) else "source"
            member = _enclosing_member(lines, scopes, idx - 1) if lines else ""
            reach = _reachability(member)
            base = "high" if kind in ("try_force", "as_cast") else "medium"

            findings.append({
                "file": file_path, "line": idx, "kind": "force_unwrap",
                "match": item.get("context", "")[:200],
                "primary": kind, "subkinds": {kind: 1},
                "severity": _severity_from(context, reach, base),
                "context": context, "reachability": reach,
            })

    # coalesce multiple operators on the same file+line into one finding —
    # a line can carry both `try!` and a trailing `!`. keep the worst
    # severity and the most severe primary kind so the ranking is honest.
    by_spot: dict[tuple[str, int], dict] = {}
    for f in findings:
        key = (f["file"], f["line"])
        existing = by_spot.get(key)
        if existing is None:
            by_spot[key] = f
            continue
        # merge subkinds
        for k, v in f.get("subkinds", {}).items():
            existing.setdefault("subkinds", {})[k] = existing["subkinds"].get(k, 0) + v
        # worst primary wins (try_force/as_cast > force_unwrap)
        order = {"force_unwrap": 0, "try_force": 1, "as_cast": 1}
        if order.get(f["primary"], 0) > order.get(existing["primary"], 0):
            existing["primary"] = f["primary"]
        # worst severity wins
        sev_order = {"low": 0, "medium": 1, "high": 2}
        if sev_order.get(f["severity"], 0) > sev_order.get(existing["severity"], 0):
            existing["severity"] = f["severity"]

    findings = list(by_spot.values())
    findings.sort(key=lambda f: (f["file"], f["line"]))
    return {"ok": True, "target": target, "count": len(findings), "findings": findings}


def _scan_force_unwraps_fallback(target: str) -> dict:
    """Fallback regex-based force-unwrap scan when swift-package-tool is unavailable."""
    target = _resolve_target(target)
    files = _iter_swift_files(target)
    findings: list[dict] = []

    for path in files:
        try:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except Exception as exc:
            findings.append({
                "file": str(path), "line": 0, "kind": "READ_ERROR",
                "match": str(exc),
            })
            continue
        scopes = _function_scopes(lines)
        for idx, line in enumerate(lines, start=1):
            stripped = line.strip()
            if stripped.startswith("//"):
                continue
            matches = list(_FORCE_UNWRAP_RE.finditer(line))
            if not matches:
                continue

            subkinds = {"force_unwrap": 0, "try_force": 0, "as_cast": 0}
            for m in matches:
                before = line[max(0, m.start() - 4):m.start()].rstrip()
                if before.endswith("as"):
                    subkinds["as_cast"] += 1
                elif before.endswith("try"):
                    subkinds["try_force"] += 1
                else:
                    subkinds["force_unwrap"] += 1
            present = [k for k in ("force_unwrap", "try_force", "as_cast")
                       if subkinds[k] > 0]
            primary = present[-1] if present else "force_unwrap"

            context = "test" if _is_test_source(str(path)) else "source"
            member = _enclosing_member(lines, scopes, idx - 1)
            reach = _reachability(member)
            base = "high" if primary in ("try_force", "as_cast") else "medium"

            findings.append({
                "file": str(path), "line": idx, "kind": "force_unwrap",
                "match": line.strip()[:200],
                "primary": primary, "subkinds": subkinds,
                "severity": _severity_from(context, reach, base),
                "context": context, "reachability": reach,
            })

    return {"ok": True, "target": target, "count": len(findings), "findings": findings}


def scan_secrets(target: str) -> dict:
    """Scan Swift sources for hardcoded secrets.

    Uses ``swift-package-tool search`` for regex matching, then deduplicates
    and ranks findings (same logic as the original Python-only version).
    """
    target = _resolve_target(target)
    raw = _scan_with_swift_code_query(_SECRET_PATTERNS, target)
    if not raw:
        return {"ok": True, "target": target, "count": 0, "findings": []}

    findings: list[dict] = []
    for hit in raw:
        findings.append({
            "file": hit["file"], "line": hit["line"], "kind": hit["api"],
            "match": hit.get("line_content", "")[:80],
            "severity_hint": "critical" if hit["api"] in (
                "private_key", "aws_secret_key") else "high",
        })

    best_by_line: dict[tuple, dict] = {}
    for f in findings:
        key = (f["file"], f["line"])
        if key not in best_by_line:
            best_by_line[key] = f
            continue
        cur = best_by_line[key]
        cur_rank = _LABEL_PRIORITY.index(cur["kind"]) if cur["kind"] in _LABEL_PRIORITY else 99
        new_rank = _LABEL_PRIORITY.index(f["kind"]) if f["kind"] in _LABEL_PRIORITY else 99
        if new_rank < cur_rank:
            best_by_line[key] = f

    unique = list(best_by_line.values())
    return {"ok": True, "target": target, "count": len(unique), "findings": unique}


def scan_process_safety(target: str) -> dict:
    """Scan Swift sources for process/subprocess safety issues.

    Delegates to ``swift-package-tool search`` for regex matching, then
    post-processes for scope clustering and severity ranking.
    """
    target = _resolve_target(target)
    raw = _scan_with_swift_code_query(_PROCESS_SAFETY_PATTERNS, target)
    if not raw:
        return {"ok": True, "target": target, "count": 0, "findings": []}

    # group by file for scope clustering
    by_file: dict[str, list[dict]] = {}
    for hit in raw:
        by_file.setdefault(hit["file"], []).append(hit)

    findings: list[dict] = []
    for file_path, hits in by_file.items():
        try:
            lines = open(file_path, encoding="utf-8", errors="replace").read().splitlines()
        except Exception as exc:
            findings.append({
                "file": file_path, "line": 0, "kind": "READ_ERROR",
                "match": str(exc), "severity": "low",
            })
            continue
        scopes = _function_scopes(lines)
        context = "test" if _is_test_source(file_path) else "source"
        for hit in hits:
            idx = hit["line"]
            member = _enclosing_member(lines, scopes, idx - 1)
            reach = _reachability(member)
            base = {
                "raw_fork_without_exec": "high",
                "missing_cloexec": "high",
                "fd_mutation": "medium",
                "fork_and_handoff": "high",
                "posix_spawn": "low",
            }[hit["api"]]
            findings.append({
                "file": file_path, "line": idx, "kind": "process_safety",
                "match": hit.get("line_content", "").strip()[:200],
                "api": hit["api"],
                "severity": _severity_from(context, reach, base),
                "context": context, "reachability": reach,
            })

    return {"ok": True, "target": target, "count": len(findings), "findings": findings}


# ---------------------------------------------------------------------------
# Tool 5: pkg_scan (unified scanner)
# ---------------------------------------------------------------------------

_SCAN_CATEGORIES = {
    "unsafe_ptrs": scan_unsafe_ptrs,
    "force_unwraps": scan_force_unwraps,
    "process_safety": scan_process_safety,
    "secrets": scan_secrets,
}


def scan(target: str, categories: Optional[List[str]] = None,
         compact: bool = False) -> dict:
    """Run one or more scan categories on a Swift package and return unified results."""
    target = _resolve_target(target)
    if not categories or "all" in categories:
        categories = list(_SCAN_CATEGORIES.keys())

    by_category: dict[str, dict] = {}
    all_findings: list[dict] = []
    for cat in categories:
        fn = _SCAN_CATEGORIES.get(cat)
        if fn is None:
            continue
        result = fn(target)
        findings = result.get("findings", [])
        by_category[cat] = {
            "count": len(findings),
            "findings": findings[:5] if compact else findings,
        }
        all_findings.extend(findings)

    severity_counts: dict[str, int] = {"critical": 0, "high": 0, "medium": 0, "low": 0}
    for f in all_findings:
        sev = f.get("severity") or f.get("severity_hint", "low")
        if sev in severity_counts:
            severity_counts[sev] += 1

    _SEV_ORDER = {"critical": 0, "high": 1, "medium": 2, "low": 3}
    top = sorted(all_findings, key=lambda f: _SEV_ORDER.get(
        f.get("severity") or f.get("severity_hint", "low"), 9))[:10]

    return {
        "ok": True, "target": target,
        "categories_run": categories,
        "total_findings": len(all_findings),
        "by_category": by_category,
        "by_severity": severity_counts,
        "top_findings": top if not compact else top[:5],
        "compact": compact,
    }


# ---------------------------------------------------------------------------
# Tool 6: pkg_list_dependencies (via swift package show-dependencies)
# ---------------------------------------------------------------------------

def list_dependencies(target: str, compact: bool = False) -> dict:
    """List dependencies using ``swift package show-dependencies --format json``.

    Replaces the original regex-based Package.swift parser with SwiftPM's
    own dependency resolver, giving AST-guaranteed accuracy.
    """
    target = _resolve_target(target)
    pkg = _package_path(target)
    if not pkg.exists():
        return {"ok": False, "error": f"no Package.swift at {pkg}", "dependencies": []}
    pkg_dir = pkg.parent

    try:
        proc = _run_swift(
            ["swift", "package", "show-dependencies", "--format", "json"],
            str(pkg_dir), timeout=120,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        return {"ok": False, "error": str(exc), "dependencies": []}

    if proc.returncode != 0:
        return {"ok": False, "error": proc.stderr.strip(), "dependencies": []}

    try:
        data = json.loads(proc.stdout)
    except (json.JSONDecodeError, ValueError) as exc:
        return {"ok": False, "error": f"failed to parse deps output: {exc}",
                "dependencies": []}

    # Flatten the tree into a list. walk children only — the root node is the
    # package under analysis, not a dependency of itself.
    deps: list[dict] = []

    def _walk(node: dict, depth: int):
        name = node.get("identity") or node.get("name", "")
        url = node.get("url", "")
        version = node.get("version") or ""
        requirement = node.get("requirement", {})
        req_kind = requirement.get("type", "unknown") if isinstance(requirement, dict) else "unknown"
        lower = requirement.get("lowerBound", "") if isinstance(requirement, dict) else ""
        upper = requirement.get("upperBound", "") if isinstance(requirement, dict) else ""

        dep = {
            "name": name,
            "url": url,
            "version": version,
            "requirement_kind": req_kind,
            "requirement": f"{req_kind} {lower}..<{upper}" if lower else req_kind,
        }
        deps.append(dep)

        for child in node.get("dependencies", []):
            _walk(child, depth + 1)

    # start at the root's children so the package itself is never listed
    for child in data.get("dependencies", []):
        _walk(child, 1)

    if compact:
        deps = [
            {"name": d["name"], "requirement_kind": d["requirement_kind"],
             "version": d.get("version")}
            for d in deps
        ]

    return {
        "ok": True, "target": target, "count": len(deps),
        "dependencies": deps, "package_path": str(pkg),
        "compact": compact,
    }


# ---------------------------------------------------------------------------
# Tool 7: pkg_list_targets (via swift package describe)
# ---------------------------------------------------------------------------

def list_targets(target: str, compact: bool = False) -> dict:
    """List targets using ``swift package describe --type json``.

    Replaces the original regex-based Package.swift parser with SwiftPM's
    own target resolver, giving AST-guaranteed accuracy.
    """
    target = _resolve_target(target)
    pkg = _package_path(target)
    if not pkg.exists():
        return {"ok": False, "error": f"no Package.swift at {pkg}", "targets": []}
    pkg_dir = pkg.parent

    try:
        proc = _run_swift(
            ["swift", "package", "describe", "--type", "json"],
            str(pkg_dir), timeout=120,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        return {"ok": False, "error": str(exc), "targets": []}

    if proc.returncode != 0:
        return {"ok": False, "error": proc.stderr.strip(), "targets": []}

    try:
        data = json.loads(proc.stdout)
    except (json.JSONDecodeError, ValueError) as exc:
        return {"ok": False, "error": f"failed to parse describe output: {exc}",
                "targets": []}

    targets: list[dict] = []
    for t in data.get("targets", []):
        name = t.get("name", "")
        ttype = t.get("type", "library")
        path = t.get("path", "")
        sources = t.get("sources", [])

        # swift package describe emits the target path relative to the package
        # dir, and each source as a bare filename relative to the target path.
        # anchor both before touching the filesystem.
        def _abs(p: str) -> Path:
            pp = Path(p)
            return (pkg_dir / pp) if not pp.is_absolute() else pp

        target_dir = _abs(path) if path else None
        source_paths = [(target_dir / s) if target_dir else _abs(s) for s in sources]

        # derive whether the path came from SwiftPM's default rule (Sources/<Name>
        # for library/executable, Tests/<Name> for test targets) or an explicit
        # `path` property — describe does not flag this itself.
        def _default_path(n: str, kind: str) -> str:
            if kind == "test":
                return f"Tests/{n}"
            return f"Sources/{n}"

        kind_default = _default_path(name, ttype)
        path_kind = "default" if path == kind_default else "explicit"

        entry = {
            "name": name,
            "type": ttype,
            "path": path,
            "path_kind": path_kind,
            "swift_file_count": len(source_paths),
            "swift_files": sources,
            "exists": target_dir.is_dir() if target_dir else False,
        }

        if source_paths:
            # Count lines per file using swift-package-tool index or simple wc
            file_stats = []
            total_lines = 0
            for src_path in source_paths:
                if src_path.exists():
                    try:
                        text = src_path.read_text(encoding="utf-8", errors="replace")
                        line_count = len(text.splitlines())
                    except OSError:
                        line_count = 0
                    file_stats.append({
                        "path": str(src_path.relative_to(pkg_dir)),
                        "lines": line_count,
                        "symbols": {},
                    })
                    total_lines += line_count

            # AST-backed symbol counts: one swift-package-tool query over the
            # target's sources, bucketed per file by declaration kind.
            swift_source_paths = [p for p in source_paths if p.suffix == ".swift"]
            per_file_kinds: dict[str, dict[str, int]] = {}
            total_symbols = 0
            if swift_source_paths:
                qr = _run_swift_code_query(
                    ["query", "--all"] + [str(p) for p in swift_source_paths]
                    + ["--output-format", "compact"],
                    timeout=60,
                )
                qdata = qr.get("data") if qr.get("ok", True) else None
                if isinstance(qdata, list):
                    for decl in qdata:
                        if not isinstance(decl, dict):
                            continue
                        # query preserves the path form it was given; resolve
                        # symlinks (e.g. /var -> /private/var on macOS) so the
                        # file key matches the resolved target directory.
                        f = os.path.realpath(decl.get("file", ""))
                        kind = decl.get("kind", "declaration")
                        bucket = per_file_kinds.setdefault(f, {})
                        bucket[kind] = bucket.get(kind, 0) + 1
                        total_symbols += 1

            for stats in file_stats:
                abspath = os.path.realpath(str(pkg_dir / stats["path"]))
                stats["symbols"] = per_file_kinds.get(abspath, {})

            file_stats.sort(key=lambda s: -s["lines"])
            entry["file_stats"] = file_stats
            entry["total_symbols"] = total_symbols
            entry["total_lines"] = total_lines
            entry["largest_files"] = [
                {"path": s["path"], "lines": s["lines"]}
                for s in file_stats[:5]
            ]
        else:
            entry["file_stats"] = []
            entry["total_lines"] = 0
            entry["total_symbols"] = 0
            entry["largest_files"] = []

        targets.append(entry)

    if compact:
        targets = [
            {"name": t["name"], "type": t["type"],
             "swift_file_count": t["swift_file_count"],
             "total_lines": t["total_lines"], "exists": t["exists"]}
            for t in targets
        ]

    return {
        "ok": True, "target": target, "package_path": str(pkg_dir),
        "count": len(targets), "targets": targets, "compact": compact,
    }


# ---------------------------------------------------------------------------
# Tool 8: pkg_docc_check
# ---------------------------------------------------------------------------

_DOC_COMMENT_RE = re.compile(r"^\s*///")


def _docc_catalogs(pkg_dir: Path) -> list[dict]:
    """Find every *.docc catalog (dir or file) under the package."""
    found: list[dict] = []
    for dirpath, dirnames, filenames in os.walk(pkg_dir):
        dirnames[:] = [d for d in dirnames if d not in (".build", ".git", ".swiftpm", ".build-audit")]
        for d in list(dirnames):
            if d.endswith(".docc"):
                p = Path(dirpath) / d
                md_files = sorted(str(x) for x in p.glob("*.md"))
                found.append({
                    "path": str(p), "kind": "catalog",
                    "markdown_files": md_files, "markdown_file_count": len(md_files),
                })
        for fn in filenames:
            if fn.endswith(".docc"):
                found.append({
                    "path": str(Path(dirpath) / fn), "kind": "file",
                    "markdown_files": [], "markdown_file_count": 0,
                })
    return found


def _parse_decl(line: str) -> Optional[dict]:
    """Parse a Swift declaration line into (kind, symbol name)."""
    stripped = line.strip()
    m = re.match(
        r"^(?:(?:public|open|internal|private|fileprivate)\s+)*"
        r"(?P<kind>class|struct|enum|protocol|func|var|let|subscript|init)\b"
        r"(?P<rest>.*)$", stripped)
    if not m:
        return None
    kind = m.group("kind")
    rest = m.group("rest").strip()
    name = None
    nm = re.match(r"([A-Za-z_][A-Za-z0-9_]*)", rest)
    if nm:
        name = nm.group(1)
    if kind in ("class", "struct", "enum", "protocol"):
        name = name or kind
    elif kind == "subscript":
        name = "subscript"
    elif kind == "init":
        name = name or "init"
    elif kind in ("var", "let", "func"):
        name = name or kind
    return {"kind": kind, "name": name}


def _doc_coverage(files: list[Path], uncovered_limit: Optional[int] = None) -> dict:
    """Measure doc-comment coverage on top-level public declarations."""
    documented = 0
    undoc = 0
    uncovered_symbols: list[dict] = []

    for path in files:
        try:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except Exception:
            continue
        prev_doc = False
        for idx, line in enumerate(lines, start=1):
            stripped = line.strip()
            if not stripped:
                prev_doc = False
                continue
            if _DOC_COMMENT_RE.match(line):
                prev_doc = True
                continue
            parsed = _parse_decl(line)
            if parsed is not None:
                if prev_doc:
                    documented += 1
                else:
                    undoc += 1
                    if uncovered_limit is None or len(uncovered_symbols) < uncovered_limit:
                        uncovered_symbols.append({
                            "name": parsed["name"], "kind": parsed["kind"],
                            "file": str(path), "line": idx,
                            "decl": stripped[:120],
                        })
                prev_doc = False
            else:
                prev_doc = False

    total = documented + undoc
    return {
        "declarations": total, "documented": documented,
        "undocumented": undoc,
        "coverage": round((documented / total), 3) if total else None,
        "uncovered_symbols": uncovered_symbols,
        "uncovered_symbol_count": len(uncovered_symbols),
        "undocumented_samples": uncovered_symbols[:8],
    }


def docc_check(target: str, uncovered_limit: Optional[int] = None) -> dict:
    """Analyze the package's DocC documentation status and doc-comment coverage.

    Uses ``swift-package-tool api --include-internal`` for doc comment coverage
    when available, falling back to the original heuristic parser.
    """
    target = _resolve_target(target)
    pkg = _package_path(target)
    if not pkg.exists():
        return {"ok": False, "error": f"no Package.swift at {pkg}",
                "catalogs": [], "coverage": None}
    pkg_dir = pkg.parent
    text = pkg.read_text(encoding="utf-8", errors="replace")

    catalogs = _docc_catalogs(pkg_dir)

    has_docc_plugin = bool(re.search(
        r"swift-docc-plugin|swift-docc|\bDoccPlugin\b", text))
    doc_targets = re.findall(r"documentationTargets\s*:\s*\[([^\]]*)\]", text)
    doc_target_names = []
    for block in doc_targets:
        doc_target_names += re.findall(r'"([^"]+)"', block)

    # Try swift-package-tool api for doc comment coverage
    coverage = None
    source_roots = [d for d in (pkg_dir / "Sources").iterdir() if d.is_dir()] \
        if (pkg_dir / "Sources").is_dir() else []
    if source_roots:
        sources_path = str(pkg_dir / "Sources")
        api_result = _run_swift_code_query(
            ["api", sources_path, "--include-internal", "--output-format", "compact"],
            timeout=60,
        )
        api_list = api_result.get("data") if api_result.get("ok", True) else None
        if isinstance(api_list, list) and api_list:
            # Use the API result for coverage stats
            total = len(api_list)
            documented = sum(1 for a in api_list if a.get("docComment", "").strip())
            undoc = total - documented
            coverage = {
                "declarations": total,
                "documented": documented,
                "undocumented": undoc,
                "coverage": round(documented / total, 3) if total else None,
                "uncovered_symbols": [
                    {"name": a["name"], "kind": a["kind"],
                     "file": a["file"], "line": a["line"],
                     "decl": a["signature"][:120]}
                    for a in api_list if not a.get("docComment", "").strip()
                ][:uncovered_limit] if uncovered_limit is not None else [
                    {"name": a["name"], "kind": a["kind"],
                     "file": a["file"], "line": a["line"],
                     "decl": a["signature"][:120]}
                    for a in api_list if not a.get("docComment", "").strip()
                ],
                "uncovered_symbol_count": sum(
                    1 for a in api_list if not a.get("docComment", "").strip()),
                "undocumented_samples": [
                    {"name": a["name"], "kind": a["kind"],
                     "file": a["file"], "line": a["line"],
                     "decl": a["signature"][:120]}
                    for a in api_list if not a.get("docComment", "").strip()
                ][:8],
            }
        else:
            # Fallback to heuristic parser
            coverage_files = [
                f for root in source_roots for f in _iter_swift_files(str(root))]
            coverage = _doc_coverage(coverage_files, uncovered_limit=uncovered_limit)

    return {
        "ok": True, "target": target, "package_path": str(pkg_dir),
        "catalogs": catalogs, "catalog_count": len(catalogs),
        "manifest": {
            "has_docc_plugin": has_docc_plugin,
            "documentation_targets": doc_target_names,
        },
        "coverage": coverage,
        "summary": (
            f"{len(catalogs)} DocC catalog(s); "
            f"{coverage['documented']}/{coverage['declarations']} declarations documented "
            f"({coverage['coverage']:.0%}); "
            f"{coverage['undocumented']} uncovered"
            if coverage and coverage["declarations"] else
            f"{len(catalogs)} DocC catalog(s); no public declarations to document"
        ),
    }


# ---------------------------------------------------------------------------
# Tool 9: pkg_stats_overview
# ---------------------------------------------------------------------------

_SEVERITY_RANK = {"critical": 4, "high": 3, "medium": 2, "low": 1}


def _finding_severity(category: str, f: dict) -> str:
    """Assign a triage severity to a normalized finding."""
    stored = f.get("severity")
    if stored in _SEVERITY_RANK:
        return stored
    if category == "dependency":
        return "medium" if f.get("kind") in ("from", "range") else "high"
    if category == "secret":
        hint = f.get("severity_hint", "high")
        return hint if hint in _SEVERITY_RANK else "high"
    if category in ("unsafe_ptr", "process_safety"):
        return "high" if f.get("api") in (
            "Unmanaged", "unsafeBitCast", "withUnsafeMutableBytes") else "medium"
    if category == "force_unwrap":
        return "high" if f.get("primary") in ("try_force", "as_cast") else "medium"
    return "low"


def stats_overview(target: str) -> dict:
    """Run every scan tool and return a compact, triage-ready aggregate."""
    target = _resolve_target(target)

    unsafe = scan_unsafe_ptrs(target).get("findings", [])
    force = scan_force_unwraps(target).get("findings", [])
    deps = list_dependencies(target)
    dep_list = deps.get("dependencies", [])
    secrets = scan_secrets(target).get("findings", [])
    proc = scan_process_safety(target).get("findings", [])

    rows: list[dict] = []
    rows += [{"category": "unsafe_ptr",
              "severity": _finding_severity("unsafe_ptr", f),
              "file": f["file"], "line": f["line"], "kind": f.get("api"),
              "primary": None, "context": f.get("context", "source"),
              "reachability": f.get("reachability", "internal")} for f in unsafe]
    rows += [{"category": "force_unwrap",
              "severity": _finding_severity("force_unwrap", f),
              "file": f["file"], "line": f["line"], "kind": f.get("kind"),
              "primary": f.get("primary"),
              "context": f.get("context", "source"),
              "reachability": f.get("reachability", "internal")} for f in force]
    rows += [{"category": "process_safety",
              "severity": _finding_severity("process_safety", f),
              "file": f["file"], "line": f["line"], "kind": f.get("api"),
              "primary": None, "context": f.get("context", "source"),
              "reachability": f.get("reachability", "internal")} for f in proc]
    rows += [{"category": "dependency",
              "severity": _finding_severity("dependency", d),
              "file": deps.get("package_path", "Package.swift"), "line": -1,
              "kind": d.get("requirement_kind"), "primary": None,
              "context": "source", "reachability": "internal"}
             for d in dep_list
             if d.get("requirement_kind") in ("from", "range", "branch", "unknown")]
    rows += [{"category": "secret", "severity": _finding_severity("secret", f),
              "file": f["file"], "line": f["line"], "kind": f.get("kind"),
              "primary": None, "context": f.get("context", "source"),
              "reachability": f.get("reachability", "internal")} for f in secrets]

    severity_counts = {s: 0 for s in _SEVERITY_RANK}
    category_counts: dict[str, int] = {}
    per_file: dict[str, dict[str, int]] = {}
    for r in rows:
        severity_counts[r["severity"]] = severity_counts.get(r["severity"], 0) + 1
        category_counts[r["category"]] = category_counts.get(r["category"], 0) + 1
        pf = per_file.setdefault(os.path.basename(r["file"]), {})
        pf[r["category"]] = pf.get(r["category"], 0) + 1

    severity_order = {s: i for i, s in enumerate(
        ["critical", "high", "medium", "low"])}
    reach_order = {"input": 0, "internal": 1, "cleanup": 2}
    top = sorted(rows, key=lambda r: (
        severity_order.get(r["severity"], 9),
        reach_order.get(r.get("reachability", "internal"), 1),
        r["category"], r["line"]))[:50]

    return {
        "ok": True, "target": target,
        "totals": {
            "findings": len(rows),
            "severity": severity_counts,
            "category": category_counts,
        },
        "per_file": dict(sorted(
            per_file.items(), key=lambda kv: -sum(kv[1].values()))),
        "top_findings": top,
        "details": {
            "unsafe_ptrs": unsafe,
            "force_unwraps": force,
            "process_safety": proc,
            "dependencies": dep_list,
            "secrets": secrets,
        },
    }


# ---------------------------------------------------------------------------
# Tool 10: pkg_inspector
# ---------------------------------------------------------------------------

def inspector(target: str, compact: bool = False) -> dict:
    """One-call orientation payload: what the project is, its shape, and its health.

    Composes the other tools (targets, dependencies, audit triage, build, test,
    docc) into a single compact JSON object.  Uses ``swift-package-tool index``
    for the project index and ``swift-package-tool api`` for the API surface.
    """
    def _first_para(pkg_dir: Path) -> str:
        for name in ("README.md", "README.markdown"):
            p = pkg_dir / name
            if p.exists():
                txt = p.read_text(encoding="utf-8", errors="replace")
                paras = [ln.strip() for ln in txt.splitlines() if ln.strip()]
                body = " ".join(
                    ln for ln in paras
                    if not ln.startswith("#") and not ln.startswith("```"))
                return body[:400]
        return ""

    def _read_agents_md(pkg_dir: Path) -> dict:
        for name in ("AGENTS.md", "agents.md", "Agents.md"):
            p = pkg_dir / name
            if p.exists():
                try:
                    txt = p.read_text(encoding="utf-8", errors="replace")
                except OSError:
                    return {"present": False}
                return {"present": True, "path": str(p),
                        "content": txt[:4000],
                        "truncated": len(txt) > 4000}
        return {"present": False}

    def _git_diff_state(pkg_dir: Path) -> dict:
        try:
            r = subprocess.run(
                ["git", "-C", str(pkg_dir), "status", "--porcelain",
                 "--untracked-files=all"],
                capture_output=True, text=True, timeout=15,
            )
        except Exception:
            return {"dirty": False, "note": "not a git repo (or git unavailable)"}
        if r.returncode != 0:
            return {"dirty": False, "note": "not a git repo"}
        changed = [ln for ln in r.stdout.splitlines() if ln.strip()]
        if not changed:
            return {"dirty": False, "note": "clean working tree (HEAD)"}
        _NOISE = (".build-audit/", ".build/", "/.swiftpm/", ".git/", "DerivedData")
        real = [ln for ln in changed if not any(n in ln for n in _NOISE)]
        if not real:
            return {"dirty": False,
                    "note": "clean working tree (only build artifacts changed)"}
        return {
            "dirty": True, "changed_file_count": len(real),
            "changed_files": [ln[3:].strip() for ln in real][:30],
            "note": ("working tree differs from HEAD; these uncommitted changes "
                     "are what a reviewer is likely hardening."),
        }

    target = _resolve_target(target)
    pkg = _package_path(target)
    if not pkg.exists():
        return {"ok": False, "error": f"no Package.swift at {pkg}"}
    pkg_dir = pkg.parent

    readme = _first_para(pkg_dir)
    agents = _read_agents_md(pkg_dir)
    git_state = _git_diff_state(pkg_dir)

    # Targets via swift package describe
    tl = list_targets(target)
    target_rows = [
        {"name": t["name"], "type": t["type"],
         "swift_file_count": t["swift_file_count"],
         "total_lines": t["total_lines"], "exists": t["exists"]}
        for t in tl.get("targets", [])
    ]
    all_largest: list[dict] = []
    for t in tl.get("targets", []):
        for lf in t.get("largest_files", []):
            all_largest.append({"target": t["name"], **lf})
    all_largest.sort(key=lambda x: -x["lines"])

    # Dependencies via swift package show-dependencies
    deps = list_dependencies(target)
    dep_rows = deps.get("dependencies", [])
    risky_kinds = ("from", "range", "branch", "unknown")
    risky = [
        {"name": d["name"], "requirement": d["requirement"],
         "kind": d["requirement_kind"]}
        for d in dep_rows if d.get("requirement_kind") in risky_kinds
    ]

    # Audit triage
    audit = stats_overview(target)
    audit_compact = {
        "findings": audit.get("totals", {}).get("findings", 0),
        "severity": audit.get("totals", {}).get("severity", {}),
        "category": audit.get("totals", {}).get("category", {}),
        "top_files": list(audit.get("per_file", {}).items())[:5],
    }

    # Build / test / docs verdicts
    build_result = build(target)
    test_result = test(target)
    docs = docc_check(target)
    cov = docs.get("coverage") or {}
    cov_pct = round(cov["coverage"] * 100) if cov.get("declarations") else None

    lines_total = sum(t.get("total_lines", 0) for t in target_rows)

    summary = (
        f"{pkg_dir.name}: {len(target_rows)} target(s), {lines_total} source lines, "
        f"{len(dep_rows)} dependencies ({len(risky)} with loose/range/branch/unknown "
        f"requirements), {audit_compact['findings']} security findings, "
        f"{'builds' if build_result.get('build_succeeded') else 'does not build'}, "
        f"doc coverage {cov_pct}%."
    )

    result = {
        "ok": True, "target": target, "package_path": str(pkg_dir),
        "name": pkg_dir.name, "summary": summary,
        "readme_intent": readme, "agents_md": agents, "git": git_state,
        "targets": target_rows,
        "largest_files": all_largest[:8],
        "dependencies": {
            "count": len(dep_rows), "risky_count": len(risky),
            "risky": risky[:10],
        },
        "audit": audit_compact,
        "docs": {
            "coverage_pct": cov_pct, "catalog_count": docs.get("catalog_count"),
            "documented": cov.get("documented"),
            "undocumented": cov.get("undocumented"),
            "declarations": cov.get("declarations"),
        },
        "build": {
            "succeeded": build_result.get("build_succeeded"),
            "exit_code": build_result.get("exit_code"),
        },
        "test": {
            "succeeded": test_result.get("test_succeeded"),
            "tests_total": test_result.get("tests_total"),
            "tests_failed": test_result.get("tests_failed"),
        },
    }

    if compact:
        result = {
            "ok": True, "target": target, "package_path": str(pkg_dir),
            "name": pkg_dir.name, "summary": summary,
            "target_count": len(target_rows),
            "dep_count": len(dep_rows),
            "risky_dep_count": len(risky),
            "finding_count": audit_compact.get("findings", 0),
            "build_succeeded": build_result.get("build_succeeded"),
            "test_succeeded": test_result.get("test_succeeded"),
            "doc_coverage_pct": cov_pct,
            "compact": True,
        }

    return result
