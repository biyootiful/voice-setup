#!/usr/bin/env python3
"""One turn of the session-finder chat (Ctrl+Cmd+F).

    session-chat.py "find me the session where we fixed the druid case issue"
    session-chat.py --conv <id> "no, the one before that — it had Sam in it"

Prints JSON: {"conv": <id to pass next turn>, "reply": <text>, "sessions": [...]}.

Why a chat and not a result list: when you ask an agent "find me the session…",
the agent digs — shortlists, opens transcripts, checks what actually happened —
and answers like a colleague who remembers ("that was the Sept 25 billing session;
it found the alias config and opened ABC-3655"). Follow-ups ("no, the other one")
need that context, so each conversation is a resumed headless Claude session.
find-session.py's index is its shortlist tool; the transcripts are its evidence.
"""

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CHAT_DIR = os.path.expanduser("~/.local/state/session-finder")
PROJECTS = os.path.expanduser("~/.claude/projects")

spec = importlib.util.spec_from_file_location("find_session", os.path.join(HERE, "find-session.py"))
fs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fs)
FINDER = os.path.join(HERE, "find-session.py")

BRIEF = f"""{fs.FINDER_OPENER} CHAT. You help the user find their past Claude Code sessions.
They describe them the way they'd talk to an agent: a topic, a ticket ("ABC460"), a
person who came up, a PR, roughly when, or what they were trying to do.

Where things are:
  • Transcripts: {PROJECTS}/<cwd with / → ->/<session-id>.jsonl (JSON lines;
    files can be many MB — Grep them, or tail/jq the end; don't Read whole files).
  • How it ended: the transcript's last messages, and gh pr view / gh pr list for
    any PR it opened.
  • Shortlist tool (fast, keyword-based, use it first):
      python3 {FINDER} --json --no-llm --limit 15 "<their words or keywords>"
    Each row: sid, cwd, when (last active), title (opening message), tickets,
    live (true = open in a window right now).

How to answer — like the agent that was in that session would:
  • Dig before answering. Shortlist, then Grep the likely transcripts for their
    specifics to confirm what actually happened there. Try other phrasings,
    names, ticket keys if the first pass misses.
  • Lead with the session you think it is: when, which repo, what it was doing
    and how it ended (PR opened, merged, still mid-way, waiting on something).
    Then runner-ups in a line each, only if they're real contenders.
  • If it is open in a window right now, say so — they should switch to it, not
    reopen it.
  • Ask one short question only if it is genuinely ambiguous.
  • Plain words, short. No preamble, no recap of their question.

End EVERY reply with the sessions you named, best first, at most 4:
<sessions>[{{"sid": "<full session id>", "why": "<under 10 words>"}}]</sessions>
(use [] if none). The UI turns these into Open buttons.

Their message:
"""


def run_turn(conv, message, model):
    os.makedirs(CHAT_DIR, exist_ok=True)
    prompt = message if conv else BRIEF + message
    cmd = ["claude", "-p", prompt, "--model", model, "--output-format", "json",
           "--permission-mode", "dontAsk",
           "--allowedTools", f"Bash(python3 {FINDER}:*),Grep,Glob,Read,"
           "Bash(tail:*),Bash(head:*),Bash(jq:*),Bash(grep:*),Bash(wc:*),"
           "Bash(gh pr view:*),Bash(gh pr list:*)"]
    if conv:
        cmd += ["--resume", conv]
    env = dict(os.environ)
    env["PATH"] = os.pathsep.join([os.path.expanduser("~/.local/bin"), "/opt/homebrew/bin",
                                   env.get("PATH", "/usr/bin:/bin")])
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=240, cwd=CHAT_DIR, env=env)
    try:
        out = json.loads(r.stdout)
    except ValueError:
        raise RuntimeError((r.stderr or r.stdout or "claude returned nothing").strip()[:300])
    return out.get("session_id") or conv, out.get("result") or ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("message", nargs="+")
    ap.add_argument("--conv", default="")
    ap.add_argument("--model", default="sonnet")
    a = ap.parse_args()
    try:
        conv, text = run_turn(a.conv, " ".join(a.message), a.model)
    except (RuntimeError, OSError, subprocess.SubprocessError) as e:
        print(json.dumps({"conv": a.conv, "reply": f"Search failed: {e}", "sessions": []}))
        return

    picks = []
    m = re.search(r"<sessions>(.*?)</sessions>", text, flags=re.S)
    if m:
        try:
            picks = json.loads(m.group(1))
        except ValueError:
            picks = []
        text = (text[:m.start()] + text[m.end():]).strip()

    entries = fs.load_index()
    by_sid = {e["sid"]: e for e in entries}
    live = fs.live_sids(entries)
    sessions = []
    for p in picks if isinstance(picks, list) else []:
        sid = str(p.get("sid", "")) if isinstance(p, dict) else ""
        e = by_sid.get(sid) or next((v for k, v in by_sid.items() if sid and k.startswith(sid)), None)
        if e:
            sessions.append(fs.row(e, str(p.get("why", ""))[:80], live))
    print(json.dumps({"conv": conv, "reply": text, "sessions": sessions}))


if __name__ == "__main__":
    main()
