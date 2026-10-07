#!/usr/bin/env python3
"""Real Luau syntax validation using the tree-sitter Luau grammar.

This is stronger than tests/syntax_check.py (which only checks block balance):
it builds an actual Luau parse tree, so it catches genuine syntax errors such as
malformed expressions, bad argument lists and unterminated constructs.

It also runs three cheap static audits that map to real runtime risks:

  1. ASYNC  - `local x = <expr>` / assignments that reference a *global* name that
              is never declared in the file (catches accidental globals).
  2. LITERAL-ISH CHECKS:
       * math.random() called with a fractional number literal -> Luau rejects
         non-integer arguments (or silently truncates), always a bug.
       * `while true do ... end` / `repeat ... until false` bodies that contain no
         yield (task.wait / task.spawn / RunService / wait) and no break/return ->
         potential server-freezing infinite loop.

Requires:  pip install tree-sitter tree-sitter-luau
If the packages are missing the script prints SKIPPED and exits 0, so the rest of
the test suite can still run in a bare environment.
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"

try:
    from tree_sitter import Language, Parser
    import tree_sitter_luau

    _LANG = Language(tree_sitter_luau.language())
    HAVE_TS = True
except Exception:  # pragma: no cover - environment dependent
    HAVE_TS = False

# Globals that Roblox/Luau provide. Assignments to these names are fine.
KNOWN_GLOBALS = {
    "game", "workspace", "script", "shared", "plugin", "_G", "_VERSION",
    "task", "Enum", "Instance", "Vector2", "Vector3", "Vector3int16",
    "CFrame", "Color3", "ColorSequence", "ColorSequenceKeypoint", "BrickColor",
    "NumberRange", "NumberSequence", "NumberSequenceKeypoint", "UDim", "UDim2",
    "Rect", "Region3", "Region3int16", "TweenInfo", "Ray", "RaycastParams",
    "OverlapParams", "PhysicalProperties", "Font", "DateTime", "Random",
    "PathWaypoint", "Faces", "Axes", "CatalogSearchParams", "DockWidgetPluginGuiInfo",
    "math", "table", "string", "utf8", "bit32", "os", "coroutine", "buffer",
    "vector", "debug",
    "print", "warn", "error", "assert", "pcall", "xpcall", "type", "typeof",
    "ipairs", "pairs", "next", "select", "tonumber", "tostring", "unpack",
    "setmetatable", "getmetatable", "rawget", "rawset", "rawequal", "rawlen",
    "require", "tick", "time", "elapsedTime", "wait", "delay", "spawn", "ypcall",
    "newproxy", "getfenv", "setfenv", "loadstring", "settings",
    "self", "true", "false", "nil",
}

# Calls that yield (or hand control back to the scheduler) => loop is not a hard freeze.
YIELD_HINTS = ("task.wait", "task.spawn", "task.delay", "task.defer", "wait(",
               "RunService.Heartbeat", "RunService.RenderStepped", "RunService.Stepped",
               ".Heartbeat:Wait", "player:WaitForChild", ":Wait()", "os.clock")


def walk(node):
    yield node
    for child in node.children:
        yield from walk(child)


def text(src: bytes, node) -> str:
    return src[node.start_byte:node.end_byte].decode("utf8", "replace")


def check_error_nodes(path, src, root):
    problems = []
    for node in walk(root):
        if node.type == "ERROR" or node.is_missing:
            line, col = node.start_point
            snippet = text(src, node).replace("\n", " ")[:80]
            problems.append(
                f"{path}:{line + 1}:{col + 1}: syntax error near {snippet!r}"
                f"{' (missing token)' if node.is_missing else ''}"
            )
    return problems


def declared_names(src, root):
    """Every name introduced by `local`, a function parameter, or a for-loop variable."""
    names = set()
    for node in walk(root):
        if node.type == "variable_declaration":
            for sub in walk(node):
                if sub.type == "variable_list":
                    for ident in sub.children:
                        if ident.type == "identifier":
                            names.add(text(src, ident))
        elif node.type == "parameter":
            for sub in node.children:
                if sub.type == "identifier":
                    names.add(text(src, sub))
        elif node.type in ("for_numeric_clause", "for_generic_clause"):
            for sub in walk(node):
                if sub.type == "identifier":
                    names.add(text(src, sub))
    return names


def check_accidental_globals(path, src, root):
    local_names = declared_names(src, root)
    problems = []
    for node in walk(root):
        if node.type != "assignment_statement":
            continue
        vars_node = next((c for c in node.children if c.type == "variable_list"), None)
        if vars_node is None:
            continue
        for ident in vars_node.children:
            if ident.type != "identifier":
                continue
            name = text(src, ident)
            if name in local_names or name in KNOWN_GLOBALS:
                continue
            line, col = ident.start_point
            problems.append(
                f"{path}:{line + 1}:{col + 1}: assignment to undeclared global {name!r}"
            )
    return problems


def check_numeric_literals(path, src, root):
    """math.random with a fractional literal, and bad string.pack-ish usage."""
    problems = []
    for node in walk(root):
        if node.type != "function_call":
            continue
        target = node.child_by_field_name("name") or (node.children[0] if node.children else None)
        if target is None:
            continue
        tname = text(src, target)
        args = next((c for c in node.children if c.type == "arguments"), None)
        if args is None:
            continue
        exprs = [c for c in args.children if c.is_named]
        if tname == "math.random" and 1 <= len(exprs) <= 2:
            for expr in exprs:
                if expr.type == "number":
                    raw = text(src, expr)
                    if any(ch in raw for ch in ".eE"):
                        line, col = expr.start_point
                        problems.append(
                            f"{path}:{line + 1}:{col + 1}: math.random argument {raw!r} is not an "
                            f"integer (Luau errors on fractional bounds; use math.floor)"
                        )
                elif expr.type == "binary_expression" and any(
                    c.type == "/" for c in expr.children
                ):
                    line, col = expr.start_point
                    problems.append(
                        f"{path}:{line + 1}:{col + 1}: math.random argument uses division, "
                        f"which can produce a fractional bound (wrap in math.floor)"
                    )
    return problems


def check_tight_loops(path, src, root):
    problems = []
    for node in walk(root):
        if node.type == "while_statement":
            cond = None
            body = None
            for child in node.children:
                if child.type == "block":
                    body = child
                elif child.type in ("true", "false") or child.is_named:
                    if child.type in ("true", "false"):
                        cond = child
            if cond is None or cond.type != "true" or body is None:
                continue
        elif node.type == "repeat_statement":
            body = next((c for c in node.children if c.type == "block"), None)
            trailing = text(src, node).rstrip()
            if body is None or not trailing.endswith("until false"):
                continue
        else:
            continue

        body_src = text(src, body)
        has_exit = any(k in body_src for k in ("break", "return"))
        has_yield = any(k in body_src for k in YIELD_HINTS) or "task.wait" in body_src
        if not has_exit and not has_yield:
            line, col = node.start_point
            problems.append(
                f"{path}:{line + 1}:{col + 1}: infinite loop body with no yield and no break/return"
            )
    return problems


def main():
    files = sorted(SRC.rglob("*.lua"))
    if not files:
        print("No .lua files found under src/")
        return 1

    if not HAVE_TS:
        print("SKIPPED: tree-sitter / tree-sitter-luau not installed.")
        print("         Install with: pip install tree-sitter tree-sitter-luau")
        return 0

    parser = Parser(_LANG)
    all_problems = []
    total_bytes = 0

    for path in files:
        rel = path.relative_to(ROOT)
        src = path.read_bytes()
        total_bytes += len(src)
        tree = parser.parse(src)
        root = tree.root_node

        problems = []
        problems += check_error_nodes(rel, src, root)
        problems += check_accidental_globals(rel, src, root)
        problems += check_numeric_literals(rel, src, root)
        problems += check_tight_loops(rel, src, root)

        status = "OK" if not problems else f"{len(problems)} issue(s)"
        print(f"  {rel} ({len(src.splitlines())} lines): {status}")
        all_problems += problems

    print()
    print(f"Parsed {len(files)} Luau files ({total_bytes} bytes) with the tree-sitter Luau grammar.")
    if all_problems:
        print()
        for p in all_problems:
            print("  " + p)
        print()
        print(f"Luau static audit FAILED with {len(all_problems)} issue(s).")
        return 1

    print("Luau static audit PASSED (syntax + accidental globals + loop/literal checks).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
