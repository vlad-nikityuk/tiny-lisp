#!/usr/bin/env python3
"""Repo rules from CLAUDE.md: file map, import direction, stale names in docs and sources."""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Documented exceptions (importer unit -> allowed target unit). Everything else follows the layer rule.
EXCEPTIONS = {
    ("runtime", "vm/bytecode"),
    ("lang/expand", "lang/eval"),
    ("lang/expand", "vm/compiler"),
    ("lib/natives", "lang/expand"),
    ("lib/natives", "vm/compiler"),
    ("lib/natives", "lang/parser"),
}

# Layers increase toward the entry point; a file may import same layer (internal), lower layers, and EXCEPTIONS.
LAYER = {
    "runtime": 0,
    "lang/parser": 1,
    "lang/compile": 1,
    "vm/bytecode": 2,
    "vm/scan": 2,
    "vm/compiler": 2,
    "vm/exec": 2,
    "lang/eval": 3,
    "lang/expand": 4,
    "lib/source": 5,
    "lib/natives": 5,
    "repl": 6,
}

EXTRA_RUNTIME = {"runtime"}  # any src/runtime/*.zig


def unit_of(zig: Path) -> str:
    rel = zig.relative_to(ROOT)
    if rel == Path("src/repl.zig"):
        return "repl"
    if rel.parts[:2] == ("src", "runtime"):
        return "runtime"
    if rel.parts[:2] == ("src", "lang"):
        return f"lang/{rel.name.removesuffix('.zig')}"
    if rel.parts[:2] == ("src", "vm"):
        return f"vm/{rel.name.removesuffix('.zig')}"
    if rel.parts[:2] == ("src", "lib"):
        return f"lib/{rel.name.removesuffix('.zig')}"
    raise ValueError(rel)


def resolve_import(importer: Path, spec: str) -> str | None:
    if spec == "std":
        return None
    target = (importer.parent / spec).resolve()
    if not target.is_relative_to(ROOT):
        return None
    if target.suffix != ".zig":
        return None
    return unit_of(target)


def parse_file_map() -> set[str]:
    text = (ROOT / "CLAUDE.md").read_text()
    m = re.search(r"```\nsrc/repl\.zig", text)
    if not m:
        sys.exit("repo_rules: CLAUDE.md file map not found")
    block = text[m.start() + 4 : text.find("\n```", m.start() + 4)]
    mapped: set[str] = set()
    prefix: str | None = None
    for line in block.splitlines():
        if not line.strip() or line.strip().startswith("#"):
            continue
        head = line.strip()
        if head.startswith("src/"):
            path = head.split()[0]
            if path.endswith("/"):
                prefix = path
            else:
                mapped.add(path)
                prefix = None
            continue
        name = head.split()[0]
        if prefix and (name.endswith(".zig") or name.endswith(".lisp")):
            mapped.add(prefix + name)
    return mapped


def check_file_map(mapped: set[str]) -> list[str]:
    errs: list[str] = []
    actual = {
        str(p.relative_to(ROOT)).replace("\\", "/")
        for p in ROOT.glob("src/**/*.zig")
    } | {"src/lib/stdlib.lisp"}
    for p in sorted(actual - mapped):
        errs.append(f"file map: missing {p}")
    for p in sorted(mapped - actual):
        errs.append(f"file map: lists missing file {p}")
    return errs


def check_imports() -> list[str]:
    errs: list[str] = []
    for zig in sorted((ROOT / "src").rglob("*.zig")):
        u = unit_of(zig)
        layer = LAYER[u]
        for spec in re.findall(r'@import\(\s*"([^"]+)"\s*\)', zig.read_text()):
            target = resolve_import(zig, spec)
            if target is None:
                continue
            if u == "runtime" and target == "runtime":
                continue
            if u.startswith("vm/") and target.startswith("vm/"):
                continue
            if u.startswith("lib/") and target.startswith("lib/"):
                continue
            if (u, target) in EXCEPTIONS:
                continue
            tlayer = LAYER.get(target)
            if tlayer is None:
                errs.append(f"imports: {zig.relative_to(ROOT)} -> unknown unit {target}")
                continue
            if tlayer > layer:
                errs.append(
                    f"imports: {zig.relative_to(ROOT)} ({u}) must not import {target} "
                    f"(documented direction in CLAUDE.md)"
                )
    return errs


STALE = [
    (re.compile(r"\bruntime\.zig\b"), "runtime.zig"),
    (re.compile(r"\bstdlib_native\b"), "stdlib_native"),
    (re.compile(r"\blang\.zig\b"), "lang.zig"),
    (re.compile(r"\btest-tree\b"), "test-tree"),
    (re.compile(r"\bTIER2\b"), "TIER2"),
    (re.compile(r"\btree evaluator\b"), "tree evaluator"),
    (re.compile(r"\bsecond tier\b"), "second tier"),
    (re.compile(r"\bGo\.eval\b"), "Go.eval"),
    (re.compile(r"\bGo\.args\b"), "Go.args"),
    (re.compile(r"\bvm\.zig\b.*executor", re.I), "vm.zig as executor"),
    (re.compile(r"src/macro/"), "src/macro/ path"),
]

SCAN_SUFFIXES = {".md", ".zig", ".lisp", ".py", ".yml"}
SKIP = {ROOT / "spec/repo_rules.py"}
SCAN_ROOTS = [
    ROOT / "src",
    ROOT / "spec",
    ROOT / "bench",
    ROOT / ".github",
    ROOT / ".claude/skills",
    ROOT / "README.md",
    ROOT / "CLAUDE.md",
    ROOT / "AGENTS.md",
    ROOT / "Makefile",
]


def check_stale() -> list[str]:
    errs: list[str] = []
    paths: list[Path] = []
    for root in SCAN_ROOTS:
        if root.is_file():
            paths.append(root)
        else:
            paths.extend(p for p in root.rglob("*") if p.is_file())
    for path in paths:
        if path.suffix not in SCAN_SUFFIXES:
            continue
        if path in SKIP or ".variants" in path.parts:
            continue
        try:
            text = path.read_text()
        except UnicodeDecodeError:
            continue
        for rx, label in STALE:
            if rx.search(text):
                errs.append(f"stale {label!r} in {path.relative_to(ROOT)}")
    return errs


def main() -> int:
    mapped = parse_file_map()
    errors = check_file_map(mapped) + check_imports() + check_stale()
    for e in errors:
        print(e, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())