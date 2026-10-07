"""Robust Luau block-balancing checker."""
import re, sys, os

def strip_strings_comments(src):
    out = []
    i, n = 0, len(src)
    in_string = None
    while i < n:
        c = src[i]
        nxt = src[i+1] if i+1 < n else ''
        nxt2 = src[i+2] if i+2 < n else ''
        if in_string == 'bc':
            if c == ']' and nxt == ']':
                in_string = None; i += 2; continue
            out.append('\n' if c == '\n' else ' '); i += 1; continue
        if in_string == 'lc':
            if c == '\n': in_string = None; out.append('\n')
            else: out.append(' ')
            i += 1; continue
        if in_string == 'dq':
            if c == '\\': out.append(c); out.append(nxt); i += 2; continue
            if c == '"': in_string = None
            out.append(c); i += 1; continue
        if in_string == 'sq':
            if c == '\\': out.append(c); out.append(nxt); i += 2; continue
            if c == "'": in_string = None
            out.append(c); i += 1; continue
        if in_string == 'lb':
            if c == ']' and nxt == ']': in_string = None; i += 2; out.append(' '); continue
            out.append('\n' if c == '\n' else ' '); i += 1; continue
        if c == '-' and nxt == '-':
            if nxt2 == '[': in_string = 'bc'; i += 3; continue
            in_string = 'lc'; i += 2; continue
        if c == '"': in_string = 'dq'; out.append(c); i += 1; continue
        elif c == "'": in_string = 'sq'; out.append(c); i += 1; continue
        elif c == '[' and nxt == '[': in_string = 'lb'; i += 2; out.append(' '); continue
        else:
            out.append('\n' if c == '\n' else c); i += 1
    return ''.join(out)


def check_file(path):
    with open(path) as f:
        src = f.read()
    cleaned = strip_strings_comments(src)
    word_re = re.compile(r"[A-Za-z_][A-Za-z_0-9]*")
    line_of = [0]*(len(cleaned)+1)
    ln = 1
    for i, ch in enumerate(cleaned):
        line_of[i] = ln
        if ch == '\n': ln += 1
    line_of[len(cleaned)] = ln

    stack = []
    errors = []
    expecting_do = None
    expecting_then = False
    expecting_then_reuses_block = False  # then after elseif doesn't open new block
    for m in word_re.finditer(cleaned):
        tok = m.group(0); pos = m.start(); cln = line_of[pos]
        if tok == 'function':
            stack.append(('function', cln))
        elif tok == 'repeat':
            stack.append(('repeat', cln))
        elif tok == 'if':
            expecting_then = True
            expecting_then_reuses_block = False
        elif tok == 'elseif':
            if not stack or stack[-1][0] != 'if_block':
                errors.append(f"L{cln}: 'elseif' with no matching if")
            expecting_then = True
            expecting_then_reuses_block = True
        elif tok == 'else':
            if not stack or stack[-1][0] != 'if_block':
                errors.append(f"L{cln}: 'else' with no matching if")
        elif tok == 'then':
            if expecting_then:
                if not expecting_then_reuses_block:
                    stack.append(('if_block', cln))
                expecting_then = False
                expecting_then_reuses_block = False
            else:
                errors.append(f"L{cln}: unexpected 'then'")
        elif tok == 'for': expecting_do = 'for'
        elif tok == 'while': expecting_do = 'while'
        elif tok == 'do':
            if expecting_do:
                stack.append((expecting_do + '_loop', cln)); expecting_do = None
            else:
                stack.append(('do_block', cln))
        elif tok == 'until':
            if not stack or stack[-1][0] != 'repeat':
                errors.append(f"L{cln}: 'until' without repeat")
            else: stack.pop()
        elif tok == 'end':
            if not stack: errors.append(f"L{cln}: spurious 'end'")
            else: stack.pop()
    for kind, cln in stack:
        errors.append(f"L{cln}: unclosed '{kind}' (missing 'end')")
    return errors, len(src.split('\n'))


if __name__ == "__main__":
    roots = sys.argv[1:] or ['src']
    total = 0
    for root in roots:
        for dp, _, files in os.walk(root):
            for f in sorted(files):
                if f.endswith('.lua'):
                    p = os.path.join(dp, f)
                    errs, lines = check_file(p)
                    status = "OK" if not errs else f"{len(errs)} issues"
                    rel = os.path.relpath(p, os.getcwd())
                    print(f"  {rel} ({lines} lines): {status}")
                    for e in errs: print("    ", e)
                    total += len(errs)
    print()
    if total: print(f"{total} issue(s)"); sys.exit(1)
    else: print("All Lua files have balanced blocks.")
