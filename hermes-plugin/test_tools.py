#!/usr/bin/env python3
"""Assertion-based unit tests for the swift-package-inspector pure functions.

Gap-closure over the old smoke test (which only printed): every test here
hard-asserts on the exact output shape and values, and exits non-zero on any
failure so it can gate CI / the benchmark harness.  Covers the parsers and
the newer tools (targets, docc, build, test, clean) so they no longer rely
solely on the corpus F1 gate.

Run:
    python3 test_tools.py            # quick: parsers + docc (no build)
    python3 test_tools.py --full     # also build/test/clean on a live fixture
"""
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import swift_package_inspector as sa

FAILURES = []
CHECKS = 0


def check(cond, label, detail=""):
    global CHECKS
    CHECKS += 1
    if not cond:
        FAILURES.append(f"{label}: {detail}".strip())


def _make_package(tmp: Path) -> Path:
    """Write a dependency-free Swift package that actually builds and tests."""
    pkg = tmp / "FixturePkg"
    (pkg / "Sources" / "Fixture").mkdir(parents=True, exist_ok=True)
    (pkg / "Tests" / "FixtureTests").mkdir(parents=True, exist_ok=True)
    (pkg / "Package.swift").write_text(
        '// swift-tools-version: 5.9\n'
        'import PackageDescription\n'
        'let package = Package(\n'
        '    name: "FixturePkg",\n'
        '    products: [.library(name: "Fixture", targets: ["Fixture"])],\n'
        '    targets: [\n'
        '        .target(name: "Fixture"),\n'
        '        .testTarget(name: "FixtureTests", dependencies: ["Fixture"]),\n'
        '    ]\n'
        ')\n'
    )
    (pkg / "Sources" / "Fixture" / "Fixture.swift").write_text(
        '/// A fixture value.\n'
        'public struct Fixture {\n'
        '    public let value: Int\n'
        '    public init(_ v: Int) { value = v }\n'
        '    /// Adds two values.\n'
        '    public func add(_ other: Int) -> Int { value + other }\n'
        '    func internalNoDoc() {}\n'
        '}\n'
    )
    (pkg / "Tests" / "FixtureTests" / "FixtureTests.swift").write_text(
        'import XCTest\n'
        '@testable import Fixture\n'
        'final class FixtureTests: XCTestCase {\n'
        '    func testAdd() { XCTAssertEqual(Fixture(2).add(3), 5) }\n'
        '}\n'
    )
    return pkg


def _make_pkg_manifest() -> str:
    return (
        '// swift-tools-version: 5.9\n'
        'import PackageDescription\n'
        'let package = Package(\n'
        '    name: "MultiTarget",\n'
        '    products: [.library(name: "Core", targets: ["Core"])],\n'
        '    targets: [\n'
        '        .target(name: "Core"),\n'
        '        .target(name: "HasPath", path: "Custom/Dir"),\n'
        '        .testTarget(name: "CoreTests", dependencies: ["Core"]),\n'
        '        .executableTarget(name: "CLI"),\n'
        '    ]\n'
        ')\n'
    )


# ---------------------------------------------------------------------------
# Parser tests (no build needed, use inline fixtures)
# ---------------------------------------------------------------------------

def test_list_targets_default_path():
    """list_targets must apply SwiftPM default-path rules correctly."""
    tmp = Path(tempfile.mkdtemp(prefix="sat-"))
    (tmp / "Package.swift").write_text(_make_pkg_manifest())
    (tmp / "Sources" / "Core").mkdir(parents=True)
    (tmp / "Sources" / "Core" / "Core.swift").write_text("public struct Core {}\n")
    (tmp / "Tests" / "CoreTests").mkdir(parents=True)
    (tmp / "Tests" / "CoreTests" / "T.swift").write_text("import XCTest\n")
    (tmp / "Custom" / "Dir").mkdir(parents=True)
    (tmp / "Custom" / "Dir" / "P.swift").write_text("public struct P {}\n")
    # executableTarget CLI also needs its default Sources/CLI dir on modern SwiftPM
    (tmp / "Sources" / "CLI").mkdir(parents=True)
    (tmp / "Sources" / "CLI" / "main.swift").write_text("print(\"hi\")\n")

    r = sa.list_targets(str(tmp))
    check(r.get("ok"), "list_targets ok")
    check(r.get("count") == 4, "list_targets count", f"got {r.get('count')}")
    by_name = {t["name"]: t for t in r["targets"]}

    # Core: no explicit path -> default Sources/Core
    core = by_name.get("Core")
    check(core is not None, "Core present")
    if core:
        check(core["path_kind"] == "default", "Core path_kind", str(core))
        check(core["type"] == "library", "Core type", core["type"])
        check(core["exists"] and core["swift_file_count"] == 1, "Core exists+1 file", str(core))
        check(str(core["path"]).endswith("Sources/Core"), "Core path", core["path"])

    # HasPath: explicit path -> Custom/Dir
    hp = by_name.get("HasPath")
    check(hp is not None, "HasPath present")
    if hp:
        check(hp["path_kind"] == "explicit", "HasPath path_kind", str(hp))
        check(str(hp["path"]).endswith("Custom/Dir"), "HasPath path", hp["path"])
        check(hp["swift_file_count"] == 1, "HasPath file count", str(hp))

    # CoreTests: testTarget -> default Tests/CoreTests
    ct = by_name.get("CoreTests")
    check(ct is not None, "CoreTests present")
    if ct:
        check(ct["type"] == "test", "CoreTests type", ct["type"])
        check(ct["path_kind"] == "default", "CoreTests path_kind", str(ct))
        check(str(ct["path"]).endswith("Tests/CoreTests"), "CoreTests path", ct["path"])

    # CLI: executableTarget -> default Sources/CLI. SwiftPM 6+ requires the
    # default dir to exist for a declared target, so after the fixture creates
    # it the target exists and carries its one source file.
    cli = by_name.get("CLI")
    check(cli is not None, "CLI present")
    if cli:
        check(cli["type"] == "executable", "CLI type", cli["type"])
        check(cli["exists"], "CLI exists (default dir created by fixture)", str(cli))
        check(cli["swift_file_count"] == 1, "CLI one file", str(cli))


def test_list_dependencies():
    tmp = Path(tempfile.mkdtemp(prefix="sat-"))
    # local path-based deps resolve offline (no network fetch). one loose
    # (from:) and one exact pin exercise both requirement rendering paths.
    (tmp / "LibA").mkdir(parents=True)
    (tmp / "LibA" / "Sources" / "LibA").mkdir(parents=True)
    (tmp / "LibA" / "Sources" / "LibA" / "LibA.swift").write_text("public struct LibA {}\n")
    (tmp / "LibA" / "Package.swift").write_text(
        '// swift-tools-version: 5.9\nimport PackageDescription\n'
        'let package = Package(name: "LibA",\n'
        '    products: [.library(name: "LibA", targets: ["LibA"])],\n'
        '    targets: [.target(name: "LibA")])\n')
    (tmp / "LibB").mkdir(parents=True)
    (tmp / "LibB" / "Sources" / "LibB").mkdir(parents=True)
    (tmp / "LibB" / "Sources" / "LibB" / "LibB.swift").write_text("public struct LibB {}\n")
    (tmp / "LibB" / "Package.swift").write_text(
        '// swift-tools-version: 5.9\nimport PackageDescription\n'
        'let package = Package(name: "LibB",\n'
        '    products: [.library(name: "LibB", targets: ["LibB"])],\n'
        '    targets: [.target(name: "LibB")])\n')
    (tmp / "Package.swift").write_text(
        '// swift-tools-version: 5.9\nimport PackageDescription\n'
        'let package = Package(\n'
        '    name: "D",\n'
        '    dependencies: [\n'
        f'        .package(name: "libA", path: "{tmp / "LibA"}"),\n'
        f'        .package(name: "libB", path: "{tmp / "LibB"}"),\n'
        '    ],\n'
        '    targets: [\n'
        '        .target(name: "D", dependencies: [\n'
        '            .product(name: "LibA", package: "libA"),\n'
        '            .product(name: "LibB", package: "libB"),\n'
        '        ])\n'
        '    ]\n'
        ')\n')
    (tmp / "Sources" / "D").mkdir(parents=True)
    (tmp / "Sources" / "D" / "D.swift").write_text("import LibA\nimport LibB\npublic func f() {}\n")

    r = sa.list_dependencies(str(tmp))
    check(r.get("ok"), "deps ok", str(r.get("error")))
    check(r.get("count") == 2, "deps count", str(r.get("count")))
    names = {d["name"] for d in r["dependencies"]}
    # show-dependencies reports each dep under its declared package name/identity
    check(names == {"liba", "libb"}, "deps names", str(names))
    for d in r["dependencies"]:
        check(d.get("requirement_kind") in ("unknown", "from", "exact"),
              f"requirement kind present: {d['name']}", str(d))


def test_force_unwrap_classification():
    tmp = Path(tempfile.mkdtemp(prefix="sat-"))
    (tmp / "Package.swift").write_text(
        '// swift-tools-version: 5.9\nimport PackageDescription\n'
        'let package = Package(name: "F", targets: [.target(name: "F")])\n')
    src = tmp / "Sources" / "F"
    src.mkdir(parents=True)
    (src / "F.swift").write_text(
        'public struct F {\n'
        '    public func a() { let x = optional! }\n'          # plain
        '    public func b() { try! risky() }\n'              # try!
        '    public func c() { let y = value as! Int }\n'      # as!
        '    public func d() { let z = a != b }\n'             # != must be ignored
        '}\n'
    )
    r = sa.scan_force_unwraps(str(tmp))
    check(r.get("count") == 3, "force count (ignore !=)", str(r.get("count")))
    primaries = [f["primary"] for f in r["findings"]]
    check("force_unwrap" in primaries, "plain detected", str(primaries))
    check("try_force" in primaries, "try! detected", str(primaries))
    check("as_cast" in primaries, "as! detected", str(primaries))
    # try! line must carry a subkind breakdown with try_force>0
    tf = [f for f in r["findings"] if f["primary"] == "try_force"]
    if tf:
        check(tf[0]["subkinds"]["try_force"] == 1, "try! subkind count", str(tf[0]))


def test_docc_check_and_uncovered_symbols():
    tmp = Path(tempfile.mkdtemp(prefix="sat-"))
    (tmp / "Package.swift").write_text(
        '// swift-tools-version: 5.9\nimport PackageDescription\n'
        'let package = Package(name: "Docc", targets: [.target(name: "Docc")])\n')
    src = tmp / "Sources" / "Docc"
    src.mkdir(parents=True)
    (src / "Docc.swift").write_text(
        '/// Documented struct.\n'
        'public struct Good {}\n'
        'public struct Bad {}\n'
        'public func alsoBad() {}\n'
    )
    r = sa.docc_check(str(tmp))
    check(r.get("ok"), "docc ok")
    cov = r.get("coverage") or {}
    check(cov.get("declarations") == 3, "docc decl count", str(cov))
    check(cov.get("documented") == 1, "docc documented", str(cov))
    check(cov.get("undocumented") == 2, "docc undocumented", str(cov))
    check(abs(cov.get("coverage") - 1 / 3) < 0.001, "docc coverage ratio", str(cov.get("coverage")))

    # uncovered symbols must be named with kind+file+line
    syms = cov.get("uncovered_symbols", [])
    check(len(syms) == 2, "uncovered count", str(len(syms)))
    names = {s["name"] for s in syms}
    check("Bad" in names and "alsoBad" in names, "uncovered names", str(names))
    for s in syms:
        # the swift tool reports function decls with kind "function"
        check(s.get("kind") in ("struct", "function", "func"), "uncovered kind", str(s))
        check(s.get("line", 0) > 0, "uncovered line", str(s))
        check(s.get("file", "").endswith("Docc.swift"), "uncovered file", str(s))

    # uncovered_limit must bound the list but keep the full count
    r2 = sa.docc_check(str(tmp), uncovered_limit=1)
    cov2 = r2.get("coverage") or {}
    check(len(cov2.get("uncovered_symbols", [])) == 1, "limit bounds list", str(len(cov2.get("uncovered_symbols", []))))
    check(cov2.get("undocumented") == 2, "limit keeps full count", str(cov2.get("undocumented")))


# ---------------------------------------------------------------------------
# Build / test / clean gates (live fixture, --full only)
# ---------------------------------------------------------------------------

def test_build_test_clean(tmp):
    pkg = _make_package(tmp)

    # build must succeed and report the real exit code
    b = sa.build(str(pkg))
    check(b.get("build_succeeded"), "build succeeds", str(b.get("raw_stderr"))[-400:])

    # test_check must pass and count the 1 test (SwiftPM 6 "Test run with N")
    t = sa.test(str(pkg))
    check(t.get("test_succeeded"), "test_check passes", str(t.get("stderr"))[-400:])
    check(t.get("tests_total") == 1, "test_check counts 1 test", f"got {t.get('tests_total')}")
    check(t.get("tests_failed") == 0, "test_check 0 failures", str(t.get("tests_failed")))
    check(t.get("no_tests") is False, "test_check has tests", str(t.get("no_tests")))

    # .build-audit must exist after the test run
    check((pkg / ".build-audit").exists(), ".build-audit exists after test", str(pkg))

    # clean must remove the isolated audit dir and never touch .build/sources
    c = sa.clean(str(pkg))
    check(c.get("cleaned"), "clean reports cleaned", str(c))
    check(not (pkg / ".build-audit").exists(), "clean removed .build-audit", str(pkg))
    check((pkg / "Sources" / "Fixture" / "Fixture.swift").exists(), "clean preserved sources", str(pkg))


def test_list_targets_heatmap():
    """list_targets must emit per-file size/symbol heatmap (lines, symbols, largest)."""
    tmp = Path(tempfile.mkdtemp(prefix="sat-hm-"))
    (tmp / "Package.swift").write_text(_make_pkg_manifest())
    (tmp / "Sources" / "Core").mkdir(parents=True)
    (tmp / "Sources" / "Core" / "Core.swift").write_text(
        "public struct Core {\n"
        "    public let a: Int\n"
        "    public func f() -> Int { 1 }\n"
        "}\n"
    )
    # the manifest references Custom/Dir for HasPath — SwiftPM rejects a
    # nonexistent custom path, so create the directory like the default-path test
    (tmp / "Custom" / "Dir").mkdir(parents=True)
    (tmp / "Custom" / "Dir" / "P.swift").write_text("public struct P {}\n")
    # the manifest declares a CoreTests test target — give it its default dir so
    # SwiftPM does not overlap it with Sources/Core
    (tmp / "Tests" / "CoreTests").mkdir(parents=True)
    (tmp / "Tests" / "CoreTests" / "T.swift").write_text("import XCTest\n")
    # executableTarget CLI also needs its default Sources/CLI dir on modern SwiftPM
    (tmp / "Sources" / "CLI").mkdir(parents=True)
    (tmp / "Sources" / "CLI" / "main.swift").write_text("print(\"hi\")\n")

    r = sa.list_targets(str(tmp))
    core = next(t for t in r["targets"] if t["name"] == "Core")
    check("file_stats" in core, "list_targets has file_stats")
    check(core.get("total_lines") == 4, "total_lines counts lines", f"got {core.get('total_lines')}")
    check(core.get("total_symbols") >= 3, "total_symbols counts decls", f"got {core.get('total_symbols')}")
    check(isinstance(core.get("largest_files"), list) and len(core["largest_files"]) >= 1,
          "largest_files non-empty", str(core.get("largest_files")))
    if core.get("file_stats"):
        fs = core["file_stats"][0]
        check(fs.get("path", "").endswith("Core.swift"), "file_stats path", str(fs.get("path")))
        check(fs.get("lines") == 4, "file_stats lines", str(fs.get("lines")))
        # the swift tool reports function decls with kind "function"
        check("symbols" in fs and fs["symbols"].get("function") == 1, "file_stats symbols", str(fs.get("symbols")))
    # declared-but-created CLI target carries 1 file with its own heatmap keys
    cli = next(t for t in r["targets"] if t["name"] == "CLI")
    check(cli["exists"] is True, "CLI exists (fixture creates its default dir)")
    check(cli.get("total_lines") == 1 and len(cli.get("file_stats", [])) == 1,
          "CLI heatmap present", str(cli.get("total_lines")))


def test_package_inspector():
    """package_inspector must return a compact orientation payload with all sections."""
    tmp = Path(tempfile.mkdtemp(prefix="sat-ov-"))
    pkg = tmp / "OviewPkg"
    (pkg / "Sources" / "OviewPkg").mkdir(parents=True)
    (pkg / "Package.swift").write_text(
        '// swift-tools-version: 5.9\n'
        'import PackageDescription\n'
        'let package = Package(\n'
        '    name: "OviewPkg",\n'
        '    products: [.library(name: "OviewPkg", targets: ["OviewPkg"])],\n'
        '    targets: [.target(name: "OviewPkg")]\n'
        ')\n'
    )
    (pkg / "Sources" / "OviewPkg" / "OviewPkg.swift").write_text(
        "/// Doc.\npublic struct OviewPkg {\n    public let v: Int\n}\n"
    )
    (pkg / "README.md").write_text("# OviewPkg\n\nA test package for overview.\n")
    (pkg / "AGENTS.md").write_text(
        "# Conventions\n\nUse only public API in tests. Pin deps exactly.\n"
    )

    r = sa.inspector(str(pkg))
    check(r.get("ok"), "package_inspector ok", str(r.get("error")))
    check(r.get("name") == "OviewPkg", "inspector name", r.get("name"))
    # AGENTS.md must be surfaced when present.
    am = r.get("agents_md") or {}
    check(am.get("present") is True, "overview surfaces AGENTS.md", str(am))
    check("Use only public API" in am.get("content", ""),
          "overview includes AGENTS.md content", str(am.get("content"))[:120])
    # _first_para strips markdown headings, so the "# OviewPkg" title is dropped
    # and the body paragraph remains.
    check("test package for overview" in r.get("readme_intent", ""),
          "overview readme intent", r.get("readme_intent"))
    check(len(r.get("targets", [])) == 1 and r["targets"][0]["name"] == "OviewPkg",
          "overview targets", str(r.get("targets")))
    check("summary" in r and len(r["summary"]) > 10, "overview has summary", r.get("summary"))
    for key in ("dependencies", "audit", "docs", "build", "test", "largest_files", "git"):
        check(key in r, f"overview has {key}", str(r.keys()))
    # git diff-awareness: fixture dir is not a git repo -> clean/not-a-repo, never crashes.
    check(r["git"].get("dirty") is False, "overview git field present+safe", str(r.get("git")))
    # Doc coverage: 2 public decls (struct + let v), only the struct is documented
    # (has a /// comment) -> 50% is correct.
    check(r["docs"].get("coverage_pct") == 50, "overview doc coverage", str(r["docs"].get("coverage_pct")))


def test_reachability_severity():
    """severity must reflect reachability/consequence, not raw operator presence.

    A try! on attacker-controlled parsing input stays high; the same operator
    in a cleanup path or test file is capped so it does not inflate the
    'high' count.  Every finding carries a stable `severity` key.
    """
    tmp = Path(tempfile.mkdtemp(prefix="sat-reach-"))
    (tmp / "Package.swift").write_text(
        '// swift-tools-version: 5.9\nimport PackageDescription\n'
        'let package = Package(name: "R", targets: [.target(name: "R")])\n')
    src = tmp / "Sources" / "R"
    src.mkdir(parents=True)
    (src / "R.swift").write_text(
        'public struct R {\n'
        '    public func parseInput(_ d: Data) {\n'       # attacker-controlled parsing
        '        let s = try! String(data: d, encoding: .utf8)!\n'
        '    }\n'
        '    public func closeChannel() {\n'              # cleanup path
        '        let h = handle!\n'
        '    }\n'
        '}\n'
    )
    r = sa.scan_force_unwraps(str(tmp))
    by_line = {f["line"]: f for f in r["findings"]}
    # line 3 = try! in parseInput -> input reachable, high consequence -> high
    check(by_line[3]["severity"] == "high", "parse try! stays high", str(by_line.get(3)))
    check(by_line[3]["reachability"] == "input", "parseInput reach=input", str(by_line.get(3)))
    # line 6 = plain ! in closeChannel -> cleanup -> low
    check(by_line[6]["severity"] == "low", "cleanup unwrap capped low", str(by_line.get(6)))
    check(by_line[6]["reachability"] == "cleanup", "closeChannel reach=cleanup", str(by_line.get(6)))
    # every finding has a stable severity + context key
    for f in r["findings"]:
        check(f.get("severity") in ("high", "medium", "low"), "stable severity key", str(f))


def test_test_context_severity_cap():
    """A try! in a test file must not be ranked high (not shipped)."""
    tmp = Path(tempfile.mkdtemp(prefix="sat-testsev-"))
    (tmp / "Package.swift").write_text(
        '// swift-tools-version: 5.9\nimport PackageDescription\n'
        'let package = Package(name: "T", targets: [.target(name: "T")])\n')
    tests = tmp / "Tests" / "TTests"
    tests.mkdir(parents=True)
    (tests / "TTests.swift").write_text(
        'import XCTest\nfinal class TTests: XCTestCase {\n'
        '    func testSomething() { try! risky() }\n'      # try! but in test file
        '}\n'
    )
    r = sa.scan_force_unwraps(str(tmp))
    check(len(r["findings"]) == 1, "finds test try!", str(r.get("count")))
    if r["findings"]:
        f = r["findings"][0]
        check(f["context"] == "test", "context=test", str(f))
        check(f["severity"] != "high", "test try! not high", str(f.get("severity")))


def test_scan_process_safety():
    """process_safety must surface fork/CLOEXEC/fd vocabulary with severity."""
    tmp = Path(tempfile.mkdtemp(prefix="sat-proc-"))
    (tmp / "Package.swift").write_text(
        '// swift-tools-version: 5.9\nimport PackageDescription\n'
        'let package = Package(name: "P", targets: [.target(name: "P")])\n')
    src = tmp / "Sources" / "P"
    src.mkdir(parents=True)
    (src / "P.swift").write_text(
        'import Foundation\n'
        'public func spawnChild() {\n'                       # input handler-ish
        '    let fd = open(path, O_RDONLY)\n'                # missing O_CLOEXEC
        '    posix_spawn(&pid, path, nil, nil, nil, nil)\n'  # safe replacement (positive)
        '}\n'
        'public func forkChild() {\n'
        '    let r = fork()\n'                               # raw fork
        '}\n'
    )
    r = sa.scan_process_safety(str(tmp))
    labels = {f["api"] for f in r["findings"]}
    check("missing_cloexec" in labels, "detects missing O_CLOEXEC", str(labels))
    check("posix_spawn" in labels, "reports posix_spawn (positive)", str(labels))
    check("raw_fork_without_exec" in labels, "detects raw fork", str(labels))
    # posix_spawn is informational/low; missing_cloexec high consequence.
    for f in r["findings"]:
        if f["api"] == "posix_spawn":
            check(f["severity"] == "low", "posix_spawn low (positive)", str(f))
        if f["api"] == "missing_cloexec":
            check(f["severity"] != "low", "missing_cloexec not low", str(f))
    # summarize_audit must fold process_safety into category totals.
    a = sa.stats_overview(str(tmp))
    check(a["totals"]["category"].get("process_safety", 0) > 0,
          "summarize includes process_safety", str(a["totals"]["category"]))


def main():
    only_quick = "--full" not in sys.argv
    print("=== swift-package-inspector assertion tests ===\n")

    test_list_targets_default_path()
    test_list_dependencies()
    test_force_unwrap_classification()
    test_docc_check_and_uncovered_symbols()
    test_list_targets_heatmap()
    test_package_inspector()
    test_reachability_severity()
    test_test_context_severity_cap()
    test_scan_process_safety()

    if not only_quick:
        print("  [build/test/clean] running live fixture...")
        tmp = Path(tempfile.mkdtemp(prefix="sat-build-"))
        try:
            test_build_test_clean(tmp)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    else:
        print("  [build/test/clean] skipped (pass --full to run live)")

    print(f"\n{CHECKS} checks, {len(FAILURES)} failures")
    for f in FAILURES:
        print("  FAIL:", f)
    sys.exit(1 if FAILURES else 0)


if __name__ == "__main__":
    main()