"""swift-package-inspector plugin entrypoint.

Registers narrow, pre-digested Swift package inspection and security-audit
tools under the ``swift-package-inspector`` toolset.  Designed for small-model
workers (LFM 2.5 8b): the tools each constrain scope and return structured
data, so the model executes well-bounded checks instead of open-ended
reasoning.  See ``swift_package_inspector.py`` for the per-tool contract.

The plugin is wired via ``register(ctx)`` (the Hermes directory-plugin
contract: plugin.yaml manifest + __init__.py with register(ctx)).
"""

from __future__ import annotations

import logging

from . import swift_package_inspector as sa

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Tool schemas (Hermes registry form).  The registry expects a bare function
# object — ``name``, ``description``, ``parameters`` — and wraps it in the
# OpenAI ``{"type":"function","function":{...}}`` envelope itself (and injects
# ``name``).  Passing a pre-wrapped envelope double-wraps the schema and hides
# description/parameters from ``tool_describe`` / ``tool_search``.  Keep params
# minimal and explicit so a small model cannot invent parameters or drift
# off-scope.
# ---------------------------------------------------------------------------

_BUILD_SCHEMA = {
    "name": "pkg_build",
    "description": "Build the package (or a specific target). Returns pass/fail + warning/error counts.",
    "parameters": {
        "type": "object",
        "properties": {
            "target": {
                "type": "string",
                "description": "Absolute path to the Swift package directory or Package.swift.",
            },
            "build_target": {
                "type": "string",
                "description": "Optional: build only this target (e.g. 'MyLibrary'). Faster than a full build.",
            },
            "build_args": {
                "type": "array",
                "items": {"type": "string"},
                "description": "Optional extra args to swift build. Default: none.",
            },
        },
        "required": ["target"],
    },
}

_SCAN_SCHEMA = {
    "name": "pkg_scan",
    "description": (
        "Scan for security and code-quality issues. Runs one or more "
        "scan categories and returns unified findings with severity counts. "
        "Use compact=true for a quick triage pass."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "target": {
                "type": "string",
                "description": "Absolute path to the Swift package directory or Package.swift.",
            },
            "categories": {
                "type": "array",
                "items": {"type": "string", "enum": [
                    "unsafe_ptrs", "force_unwraps", "process_safety", "secrets", "all"
                ]},
                "description": "Scan categories to run. Default: all.",
            },
            "compact": {
                "type": "boolean",
                "description": "If true, return counts and top-5 findings only. Default: false.",
            },
        },
        "required": ["target"],
    },
}

_DEPS_SCHEMA = {
    "name": "pkg_list_dependencies",
    "description": "List dependencies with requirement kinds and pinned versions. Use compact=true for names only.",
    "parameters": {
        "type": "object",
        "properties": {
            "target": {
                "type": "string",
                "description": "Absolute path to the Swift package directory or Package.swift.",
            },
            "compact": {
                "type": "boolean",
                "description": "If true, return name, requirement kind, and pinned version only. Default: false.",
            },
        },
        "required": ["target"],
    },
}

_TARGETS_SCHEMA = {
    "name": "pkg_list_targets",
    "description": "List targets with source paths and file counts. Use compact=true for names and types only.",
    "parameters": {
        "type": "object",
        "properties": {
            "target": {
                "type": "string",
                "description": "Absolute path to the Swift package directory or Package.swift.",
            },
            "compact": {
                "type": "boolean",
                "description": "If true, return name, type, file count, and line count only. Default: false.",
            },
        },
        "required": ["target"],
    },
}

_TEST_SCHEMA = {
    "name": "pkg_test",
    "description": "Run tests and report pass/fail with counts. Distinguishes test failures from build errors.",
    "parameters": {
        "type": "object",
        "properties": {
            "target": {
                "type": "string",
                "description": "Absolute path to the Swift package directory or Package.swift.",
            },
            "filter": {
                "type": "string",
                "description": "Optional regex to run only matching test cases (passed to `swift test --filter`).",
            },
        },
        "required": ["target"],
    },
}

_CLEAN_SCHEMA = {
    "name": "pkg_clean",
    "description": "Remove isolated audit build artifacts. Safe: never touches real .build or sources.",
    "parameters": {
        "type": "object",
        "properties": {
            "target": {
                "type": "string",
                "description": "Absolute path to the Swift package directory or Package.swift.",
            },
        },
        "required": ["target"],
    },
}

_DOCC_SCHEMA = {
    "name": "pkg_docc_check",
    "description": "Analyze DocC documentation coverage. Returns coverage ratio and uncovered symbols.",
    "parameters": {
        "type": "object",
        "properties": {
            "target": {
                "type": "string",
                "description": "Absolute path to the Swift package directory or Package.swift.",
            },
            "uncovered_limit": {
                "type": "integer",
                "description": "Optional cap on uncovered symbols returned (0 or omit = all).",
            },
        },
        "required": ["target"],
    },
}

_OVERVIEW_SCHEMA = {
    "name": "pkg_inspector",
    "description": (
        "One-call orientation: targets, deps, audit totals, build/test verdicts, "
        "doc coverage, README intent, and git state. Call this FIRST to understand "
        "a package before drilling into specific tools."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "target": {
                "type": "string",
                "description": "Absolute path to the Swift package directory or Package.swift.",
            },
            "compact": {
                "type": "boolean",
                "description": "If true, return summary and counts only. Default: false.",
            },
        },
        "required": ["target"],
    },
}


# ---------------------------------------------------------------------------
# Handlers: model-facing tools.  The registry contract requires handlers to
# return a JSON string (they receive the validated arg dict).
# ---------------------------------------------------------------------------

def _require_target(args: dict) -> str:
    """Return the required `target` arg or raise a model-helpful error.

    The LFM 8b model sometimes emits a tool call with empty arguments (``{}``),
    skipping the required ``target``.  A bare KeyError gives it nothing to
    recover with, so raise a message that tells it exactly what path to pass.
    """
    t = args.get("target")
    if not t:
        raise ValueError(
            "Missing required argument 'target'. Pass the absolute path to the "
            "Swift package directory you are auditing, e.g. "
            '{"target": "/path/to/Package.swift"}.'
        )
    return t


def _h_build(args: dict, **kwargs) -> str:
    import json
    try:
        res = sa.build(
            target=_require_target(args),
            build_args=args.get("build_args"),
            build_target=args.get("build_target"),
        )
        return json.dumps(res)
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"ok": False, "build_succeeded": False, "error": str(exc)})


def _h_scan(args: dict, **kwargs) -> str:
    import json
    try:
        return json.dumps(sa.scan(
            target=_require_target(args),
            categories=args.get("categories"),
            compact=args.get("compact", False),
        ))
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"ok": False, "error": str(exc), "findings": []})


def _h_deps(args: dict, **kwargs) -> str:
    import json
    try:
        return json.dumps(sa.list_dependencies(
            target=_require_target(args),
            compact=args.get("compact", False),
        ))
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"ok": False, "error": str(exc), "dependencies": []})


def _h_targets(args: dict, **kwargs) -> str:
    import json
    try:
        return json.dumps(sa.list_targets(
            target=_require_target(args),
            compact=args.get("compact", False),
        ))
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"ok": False, "error": str(exc), "targets": []})


def _h_test(args: dict, **kwargs) -> str:
    import json
    try:
        return json.dumps(sa.test(
            target=_require_target(args),
            filter=args.get("filter"),
        ))
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"ok": False, "test_succeeded": False, "error": str(exc)})


def _h_clean(args: dict, **kwargs) -> str:
    import json
    try:
        return json.dumps(sa.clean(target=_require_target(args)))
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"ok": False, "cleaned": False, "error": str(exc)})


def _h_docc(args: dict, **kwargs) -> str:
    import json
    try:
        return json.dumps(sa.docc_check(
            target=_require_target(args),
            uncovered_limit=args.get("uncovered_limit"),
        ))
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"ok": False, "error": str(exc), "catalogs": [], "coverage": None})


def _h_overview(args: dict, **kwargs) -> str:
    import json
    try:
        return json.dumps(sa.inspector(
            target=_require_target(args),
            compact=args.get("compact", False),
        ))
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"ok": False, "error": str(exc)})


def register(ctx) -> None:
    """Register the swift-package-inspector tools into the global registry + this plugin."""
    ctx.register_tool(
        name="pkg_build",
        toolset="swift-package-inspector",
        schema=_BUILD_SCHEMA,
        handler=_h_build,
        description="Build a Swift package and report the authoritative result.",
        emoji="🛠️",
    )
    ctx.register_tool(
        name="pkg_scan",
        toolset="swift-package-inspector",
        schema=_SCAN_SCHEMA,
        handler=_h_scan,
        description="Scan a Swift package for security and code-quality issues.",
        emoji="🔎",
    )
    ctx.register_tool(
        name="pkg_list_dependencies",
        toolset="swift-package-inspector",
        schema=_DEPS_SCHEMA,
        handler=_h_deps,
        description="Parse a Swift package's dependency inventory.",
        emoji="📦",
    )
    ctx.register_tool(
        name="pkg_list_targets",
        toolset="swift-package-inspector",
        schema=_TARGETS_SCHEMA,
        handler=_h_targets,
        description="List a Swift package's targets with their resolved source paths.",
        emoji="🗂️",
    )
    ctx.register_tool(
        name="pkg_test",
        toolset="swift-package-inspector",
        schema=_TEST_SCHEMA,
        handler=_h_test,
        description="Run a Swift package's test suite and report whether it passes.",
        emoji="🧪",
    )
    ctx.register_tool(
        name="pkg_clean",
        toolset="swift-package-inspector",
        schema=_CLEAN_SCHEMA,
        handler=_h_clean,
        description="Remove a Swift package's isolated audit build artifacts.",
        emoji="🧹",
    )
    ctx.register_tool(
        name="pkg_docc_check",
        toolset="swift-package-inspector",
        schema=_DOCC_SCHEMA,
        handler=_h_docc,
        description="Analyze a Swift package's DocC docs status and doc-comment coverage.",
        emoji="📖",
    )
    ctx.register_tool(
        name="pkg_inspector",
        toolset="swift-package-inspector",
        schema=_OVERVIEW_SCHEMA,
        handler=_h_overview,
        description="One-call orientation payload: targets, deps, audit, build/test, docs.",
        emoji="🧭",
    )
    logger.info("swift-package-inspector plugin registered %d tools", 8)


# Also expose the pure functions for direct/testing use and for other plugins.
__all__ = [
    "sa",
    "register",
    "pkg_build",
    "pkg_scan",
    "pkg_test",
    "pkg_clean",
    "pkg_docc_check",
    "pkg_list_dependencies",
    "pkg_list_targets",
    "pkg_inspector",
]

# Re-export functions at module level so tests / future plugins can call them
# without importing the private module object.
pkg_build = sa.build
pkg_scan = sa.scan
pkg_test = sa.test
pkg_clean = sa.clean
pkg_docc_check = sa.docc_check
pkg_list_dependencies = sa.list_dependencies
pkg_list_targets = sa.list_targets
pkg_inspector = sa.inspector
