#!/usr/bin/env python3
"""List Claude Code sessions with the directory each one has to be resumed from.

Claude keys sessions by cwd, so `claude --resume` only ever lists what was started
in the directory you run it in. This reads the transcripts directly and prints the
cwd next to every session, which is the piece you cannot otherwise see.

    claude-sessions.py [TERM] [--deep] [--limit N] [--all]

TERM matches the session's opening prompt, its cwd, or its id, case-insensitively;
--deep searches the whole transcript instead (slower, reads every file).

Output is TSV, one session per line, newest first:

    epoch  session_id  cwd  newest_in_cwd(1|0)  opening_prompt

newest_in_cwd is what makes `claude -c` (continue, no picker) safe: it is 1 only
when this session is the most recent one in that directory, i.e. what -c would
land on. Consumed by claude-resume.sh.
"""

import argparse
import glob
import json
import os
import re
import sys

PROJECTS = os.path.expanduser("~/.claude/projects")
# The opening prompt is normally the first line; scan a little further in case a
# session starts with mode/permission/snapshot records or a resumed prefix.
MAX_SCAN_LINES = 400
SNIPPET = 160


def opening_prompt(path):
    """(cwd, session_id, prompt) from the first real user message in a transcript."""
    cwd = sid = None
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for n, line in enumerate(fh):
                if n > MAX_SCAN_LINES:
                    break
                line = line.strip()
                if not line:
                    continue
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                cwd = o.get("cwd") or cwd
                sid = o.get("sessionId") or sid
                if o.get("type") != "user" or o.get("isSidechain"):
                    continue
                content = (o.get("message") or {}).get("content")
                if isinstance(content, list):  # content blocks
                    content = " ".join(
                        b.get("text", "") for b in content if isinstance(b, dict)
                    )
                if not isinstance(content, str) or not content.strip():
                    continue
                return cwd, sid, clean(content)
    except OSError:
        pass
    return cwd, sid, ""


def clean(text):
    text = re.sub(r"<[^>]+>", " ", text)          # command/system tags
    text = re.sub(r"\s+", " ", text).strip()
    return text[:SNIPPET]


def matches(row, term, deep):
    _, sid, cwd, _, prompt, path = row
    if term in f"{prompt}\n{cwd}\n{sid}".lower():
        return True
    if not deep:
        return False
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return term in fh.read().lower()
    except OSError:
        return False


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("term", nargs="?", default="")
    ap.add_argument("--deep", action="store_true", help="search whole transcripts")
    ap.add_argument("--limit", type=int, default=20)
    ap.add_argument("--all", action="store_true", help="no limit")
    a = ap.parse_args()

    term = a.term.lower()
    rows = []
    for path in glob.glob(os.path.join(PROJECTS, "*", "*.jsonl")):
        try:
            st = os.stat(path)
        except OSError:
            continue
        if not st.st_size:
            continue
        cwd, sid, prompt = opening_prompt(path)
        sid = sid or os.path.basename(path)[:-6]
        cwd = cwd or os.path.dirname(path)
        rows.append([int(st.st_mtime), sid, cwd, 0, prompt, path])

    # Newest per cwd is computed over EVERY session, not just the matches —
    # otherwise a filtered row gets flagged as what `claude -c` would open when a
    # newer, non-matching session in the same directory is what -c actually finds.
    newest = {}
    for r in rows:
        if r[0] > newest.get(r[2], (0, None))[0]:
            newest[r[2]] = (r[0], r[1])
    for r in rows:
        r[3] = 1 if newest[r[2]][1] == r[1] else 0

    if term:
        rows = [r for r in rows if matches(r, term, a.deep)]

    rows.sort(key=lambda r: -r[0])
    if not a.all:
        rows = rows[: a.limit]
    out = sys.stdout
    for r in rows:
        out.write("\t".join(str(x) for x in r[:5]) + "\n")


if __name__ == "__main__":
    main()
