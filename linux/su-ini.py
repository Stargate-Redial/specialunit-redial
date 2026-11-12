#!/usr/bin/env python3
"""Apply a settings file to an Unreal ini (SpecialUnit.ini), the way the engine applies default.ini deltas.

Usage: python3 -I su-ini.py <ini> <settings> [<settings>...]

In a settings file, under [Section]:
  Key=Value   sets Key: every Key= line of the section is replaced by the lines given for Key in that
              section of the settings (so several Maps= lines replace the whole map list);
  +Key=Value  adds the line if the section does not have it yet;
  -Key=Value  removes that exact line.
Lines starting with ; or # are comments. The ini keeps its CRLF line ends and Windows-1252 text.
Running it again changes nothing.
"""
import sys
from collections import OrderedDict


def read_settings(path):
    sections = OrderedDict()
    sec = None
    with open(path, encoding="cp1252") as f:
        for raw in f:
            line = raw.strip()
            if not line or line[0] in ";#":
                continue
            if line.startswith("[") and line.endswith("]"):
                sec = line[1:-1]
                sections.setdefault(sec, [])
                continue
            if sec is None or "=" not in line:
                sys.exit(f"{path}: line outside a section or without '=': {line}")
            sections[sec].append(line)
    return sections


def apply(ini_lines, sec, ops):
    # locate the section (case-insensitive, as the engine does); create it at the end if missing
    start = next((i for i, l in enumerate(ini_lines) if l.strip().lower() == f"[{sec.lower()}]"), None)
    if start is None:
        if ini_lines and ini_lines[-1].strip():
            ini_lines.append("")
        ini_lines.append(f"[{sec}]")
        start = len(ini_lines) - 1
    end = next((i for i in range(start + 1, len(ini_lines)) if ini_lines[i].startswith("[")), len(ini_lines))
    body = ini_lines[start + 1:end]
    while body and not body[-1].strip():
        body.pop()

    def key(l):
        return l.split("=", 1)[0].strip().lower()

    sets = OrderedDict()
    for op in ops:
        if op[0] not in "+-":
            sets.setdefault(key(op), []).append(op)
    for k, lines in sets.items():
        pos = next((i for i, l in enumerate(body) if "=" in l and key(l) == k), len(body))
        body = [l for l in body if not ("=" in l and key(l) == k)]
        body[pos:pos] = lines
    for op in ops:
        line = op[1:]
        if op[0] == "-":
            body = [l for l in body if l.strip().lower() != line.lower()]
        elif op[0] == "+" and not any(l.strip().lower() == line.lower() for l in body):
            body.append(line)
    tail = ini_lines[end:]
    ini_lines[start + 1:] = body + ([""] if tail else []) + tail


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    path = sys.argv[1]
    with open(path, encoding="cp1252", newline="") as f:
        lines = f.read().replace("\r\n", "\n").split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    for settings in sys.argv[2:]:
        for sec, ops in read_settings(settings).items():
            apply(lines, sec, ops)
    with open(path, "w", encoding="cp1252", newline="") as f:
        f.write("\r\n".join(lines) + "\r\n")


if __name__ == "__main__":
    main()
