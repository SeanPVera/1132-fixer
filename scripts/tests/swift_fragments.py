"""Render string-literal shell fragments from ShellCommands.swift for fixture tests.

Only named interpolations are supported. Every `\\(expression)` must be supplied by the
test; an unknown one raises instead of running a partially rendered script.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "Sources/1132Fixer/ShellCommands.swift").read_text()

_ESCAPES = {"n": "\n", "t": "\t", "0": "\0", "\\": "\\", '"': '"', "'": "'"}


def _strip_indent(body, indent):
    lines = body.split("\n")
    out = []
    for line in lines:
        if line.strip() == "":
            out.append("")
        else:
            if not line.startswith(" " * indent):
                raise AssertionError("literal line is less indented than its delimiter: " + line)
            out.append(line[indent:])
    return "\n".join(out)


def literal_after(anchor, source=SOURCE):
    """Body of the first non-raw multi-line literal after `anchor`, still escaped."""
    start = source.index(anchor)
    open_at = source.index('"""\n', start)
    body_start = open_at + 4
    close_at = source.index('"""', body_start)
    line_start = source.rindex("\n", 0, close_at) + 1
    indent = close_at - line_start
    return _strip_indent(source[body_start:line_start - 1], indent)


def raw_literal(name, source=SOURCE):
    """Body of `static let <name> = #\"\"\" ... \"\"\"#` (raw: no escapes apply)."""
    opener = f'static let {name} = #"""\n'
    body_start = source.index(opener) + len(opener)
    close_at = source.index('"""#', body_start)
    line_start = source.rindex("\n", 0, close_at) + 1
    return _strip_indent(source[body_start:line_start - 1], close_at - line_start)


def render(fragment, **values):
    """Applies Swift escapes and `\\(name)` interpolations, like the Swift compiler would."""
    out = []
    i = 0
    while i < len(fragment):
        ch = fragment[i]
        if ch != "\\":
            out.append(ch)
            i += 1
            continue
        nxt = fragment[i + 1]
        if nxt == "\n":  # line continuation
            i += 2
            continue
        if nxt == "(":
            depth, j = 1, i + 2
            while depth:
                depth += {"(": 1, ")": -1}.get(fragment[j], 0)
                j += 1
            expression = fragment[i + 2:j - 1]
            if expression not in values:
                raise AssertionError("no fixture value for interpolation: " + expression)
            out.append(str(values[expression]))
            i = j
            continue
        if nxt not in _ESCAPES:
            raise AssertionError("unsupported Swift escape: \\" + nxt)
        out.append(_ESCAPES[nxt])
        i += 2
    return "".join(out)
