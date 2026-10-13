#!/usr/bin/env python3
"""What already exists for a ticket: Claude sessions, branches, PRs — and what to do next.

autopilot.sh asks this before it touches a ticket, so it never starts a second
agent on work that a session (open in a kitty window or long since closed), a
branch, or a PR already carries. Several sessions are usually open at once.

    ticket-state.py KEY [KEY ...] [--repos a,b,c] [--org ORG] [--fetch]

--repos / --org default to AP_REPOS / AP_GH_ORG from ~/.config/voice-setup/autopilot.conf.

Prints one JSON object per line, one per KEY:

    {"key", "verdict", "reason", "resume": {...} | null, "sessions": [...],
     "branches": [...], "prs": [...]}

verdict is one of:
    pr-open          an open PR exists — finish that PR, don't start over
    merged           a PR for it is already merged — nothing to build
    live-working     a session on it is running and wrote within LIVE_MIN — leave it
    live-manual      a session on it is open, but a human started it — never take over
    live-waiting     an agent session is open and quiet < TAKEOVER_MIN — probably waiting on me
    takeover         an agent session is open but idle — stop it, resume it, finish it
    resume           a closed session worked on it — resume that session
    branch-only      a branch exists but no session — build on that branch
    new              nothing exists — start fresh

Matching a session: its OPENING prompt names the key (how ⌃⌘J sessions start), or
it created/checked out a branch containing the key. A transcript that merely
mentions the key — e.g. the session that wrote the ticket — is not a match.
"""

import argparse
import glob
import json
import os
import re
import subprocess
import sys
import time

PROJECTS = os.path.expanduser("~/.claude/projects")
GIT_BASE = os.environ.get("GIT_BASE", os.path.expanduser("~/Documents/git"))
CONF = os.path.expanduser("~/.config/voice-setup/autopilot.conf")
LIVE_MIN = 30          # wrote to its transcript this recently => still working
TAKEOVER_MIN = 120     # an open agent session quieter than this is fair to take over
AGENT_OPENER = "You are building Jira ticket"   # jira-agent.sh build-mode prompt
# The orchestrator's own runs (any "<WORD> AUTOPILOT" opener, incl. older names)
# name the keys in their prompt but never build anything — never a match.
AUTOPILOT_OPENER = re.compile(r"^\w+ AUTOPILOT\b")
STATE_ROOT = os.path.expanduser("~/.local/state/")
# A session continued after compaction opens with a summary of everything it did,
# which names tickets it only discussed. Only its own branch commands count.
SUMMARY_OPENER = "This session is being continued from a previous conversation"
MAX_SCAN_LINES = 400
DIGITS = re.compile(r"\d+")


def key_re(key):
    # ABC-46 must not match ABC-465.
    return re.compile(re.escape(key) + r"(?!\d)", re.IGNORECASE)


def opening(path):
    """(cwd, sid, opening prompt) — same rules as claude-sessions.py."""
    cwd = sid = None
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for n, line in enumerate(fh):
                if n > MAX_SCAN_LINES:
                    break
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                cwd = o.get("cwd") or cwd
                sid = o.get("sessionId") or sid
                if o.get("type") != "user" or o.get("isSidechain"):
                    continue
                c = (o.get("message") or {}).get("content")
                if isinstance(c, list):
                    c = " ".join(b.get("text", "") for b in c if isinstance(b, dict))
                if isinstance(c, str) and c.strip():
                    return cwd, sid, re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", c)).strip()
    except OSError:
        pass
    return cwd, sid, ""


def claude_processes():
    """[(pid, cwd, command)] for running claude CLIs."""
    try:
        out = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True,
                             text=True, check=False).stdout
    except OSError:
        return []
    procs = []
    for line in out.splitlines():
        pid, _, cmd = line.strip().partition(" ")
        if os.path.basename(cmd.split(" ", 1)[0]) != "claude":
            continue
        cwd = subprocess.run(["lsof", "-a", "-p", pid, "-d", "cwd", "-Fn"],
                             capture_output=True, text=True, check=False).stdout
        cwd = next((l[1:] for l in cwd.splitlines() if l.startswith("n")), "")
        procs.append((int(pid), cwd, cmd))
    return procs


def branch_commands(body):
    """Branch names this session itself created or switched to, from its Bash calls.
    Only tool calls count: a ticket description that QUOTES a branch name is not work."""
    names = []
    for line in body.splitlines():
        if '"tool_use"' not in line:
            continue
        try:
            o = json.loads(line)
        except ValueError:
            continue
        for b in (o.get("message") or {}).get("content") or []:
            if not isinstance(b, dict) or b.get("type") != "tool_use":
                continue
            cmd = (b.get("input") or {}).get("command") or ""
            names += re.findall(r"git\b[^|;&]*?\b(?:checkout\s+(?:-b\s+)?|switch\s+(?:-c\s+)?)([\w./-]+)", cmd)
    return names


def candidate_files(keys):
    """Transcripts that mention any key at all — grep is far faster than parsing every file."""
    # Top-level transcripts only; subagent sidechains live in subdirectories.
    # One pass per file in Python: macOS grep took 17+ minutes over ~300MB with
    # dozens of patterns (-iE and -F alike). Find each key prefix ("ABC-"),
    # read the digits after it, and test the number against the wanted set.
    wanted = {}
    for k in keys:
        prefix, _, num = k.upper().rpartition("-")
        wanted.setdefault(prefix + "-", set()).add(num)
    out = []
    for path in glob.glob(os.path.join(PROJECTS, "*", "*.jsonl")):
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        if any(hit(text, pre, nums) for pre, nums in wanted.items()):
            out.append(path)
    return out


def hit(text, prefix, nums):
    for pre in (prefix, prefix.lower()):
        i = text.find(pre)
        while i != -1:
            j = i + len(pre)
            m = DIGITS.match(text, j)
            if m and m.group() in nums:
                return True
            i = text.find(pre, j)
    return False


def find_sessions(keys):
    res = {k: key_re(k) for k in keys}
    found = {k: [] for k in keys}
    procs = claude_processes()
    now = time.time()
    for path in candidate_files(keys):
        try:
            st = os.stat(path)
            with open(path, encoding="utf-8", errors="replace") as fh:
                body = fh.read()
        except OSError:
            continue
        cwd, sid, prompt = opening(path)
        sid = sid or os.path.basename(path)[:-6]
        # The orchestrator's own runs (any dir under ~/.local/state) name every key.
        if AUTOPILOT_OPENER.match(prompt) or (cwd or "").startswith(STATE_ROOT):
            continue
        branches = branch_commands(body)
        for k, r in res.items():
            in_prompt = bool(r.search(prompt)) and not prompt.startswith(SUMMARY_OPENER)
            made_branch = any(r.search(b) for b in branches)
            if not (in_prompt or made_branch):
                continue
            found[k].append({
                "sid": sid,
                "cwd": cwd,
                "idle_min": max(0, int((now - st.st_mtime) // 60)),
                "live_pid": None,
                "agent_launched": prompt.startswith(AGENT_OPENER),
                "opened_with_key": in_prompt,
                "made_branch": made_branch,
                "prompt": prompt[:140],
            })
    # Attach running processes. A resume carries its sid in argv. A fresh ⌃⌘J
    # launch carries only the prompt, so it belongs to the most recently written
    # agent session for that key in the process's own cwd — and to no other.
    for k, r in res.items():
        sess = sorted(found[k], key=lambda s: s["idle_min"])
        for pid, pcwd, cmd in procs:
            owner = next((s for s in sess if s["sid"] in cmd), None)
            if owner is None and AGENT_OPENER in cmd and r.search(cmd):
                owner = next((s for s in sess if s["agent_launched"] and s["opened_with_key"]
                              and s["cwd"] == pcwd and not s["live_pid"]), None)
            if owner is not None and not owner["live_pid"]:
                owner["live_pid"] = pid
        found[k] = sess
    return found


def repo_refs(repos, fetch):
    """Branch names per repo, read once for all keys."""
    refs = {}
    for repo in repos:
        d = os.path.join(GIT_BASE, repo)
        if not os.path.isdir(os.path.join(d, ".git")):
            continue
        if fetch:
            subprocess.run(["git", "-C", d, "fetch", "-q", "--prune", "origin"],
                           capture_output=True, check=False)
        refs[repo] = subprocess.run(["git", "-C", d, "for-each-ref", "--format=%(refname:short)",
                                     "refs/heads", "refs/remotes/origin"],
                                    capture_output=True, text=True, check=False).stdout.split()
    return refs


def repo_prs(repos, org):
    """Recent PRs per repo, listed once for all keys."""
    prs = {}
    for repo in repos:
        # GitHub search misses these (see jira-triage notes); a listing does not.
        p = subprocess.run(["gh", "pr", "list", "-R", f"{org}/{repo}", "--state", "all",
                            "--limit", "200", "--json",
                            "number,state,headRefName,baseRefName,url,title,isDraft"],
                           capture_output=True, text=True, check=False)
        try:
            prs[repo] = json.loads(p.stdout or "[]")
        except ValueError:
            prs[repo] = []
    return prs


def find_branches(key, refs):
    r = key_re(key)
    out = []
    for repo, names in refs.items():
        for n in sorted({x.removeprefix("origin/") for x in names if r.search(x)}):
            out.append({"repo": repo, "branch": n,
                        "remote": f"origin/{n}" in names, "local": n in names})
    return out


def find_prs(key, prs):
    r = key_re(key)
    return [dict(pr, repo=repo) for repo, rows in prs.items() for pr in rows
            if r.search(pr["headRefName"]) or r.search(pr["title"])]


def verdict(sessions, branches, prs):
    open_prs = [p for p in prs if p["state"] == "OPEN"]
    live = [s for s in sessions if s["live_pid"]]
    working = [s for s in live if s["idle_min"] < LIVE_MIN]
    if working:
        return "live-working", f"session {working[0]['sid']} wrote {working[0]['idle_min']}m ago", working[0]
    for s in live:
        if not s["agent_launched"]:
            return "live-manual", f"open session {s['sid']} was started by hand", s
    # Quiet for under TAKEOVER_MIN may just mean I am reading its output or
    # answering its NEEDS YOU block — don't pull the window out from under me.
    waiting = [s for s in live if s["idle_min"] < TAKEOVER_MIN]
    if waiting:
        return "live-waiting", f"agent session {waiting[0]['sid']} idle {waiting[0]['idle_min']}m — may be waiting on a human", waiting[0]
    if open_prs:
        best = live[0] if live else (sessions[0] if sessions else None)
        return "pr-open", f"{open_prs[0]['repo']}#{open_prs[0]['number']} is open", best
    if any(p["state"] == "MERGED" for p in prs) and not branches_unmerged(branches, prs):
        return "merged", "a PR for it is merged", None
    if live:
        return "takeover", f"agent session {live[0]['sid']} idle {live[0]['idle_min']}m (pid {live[0]['live_pid']})", live[0]
    # Only a session the agent launcher opened is worth resuming unattended. A
    # hand session — even one that cut a branch — is a human's conversation; its
    # branch still shows up below as branch-only, so a fresh build can reuse it.
    builds = [s for s in sessions if s["agent_launched"]]
    if builds:
        return "resume", f"closed session {builds[0]['sid']} worked on it", builds[0]
    if branches:
        return "branch-only", f"{branches[0]['repo']}:{branches[0]['branch']} exists", None
    return "new", "nothing exists yet", None


def branches_unmerged(branches, prs):
    merged_heads = {(p["repo"], p["headRefName"]) for p in prs if p["state"] == "MERGED"}
    return [b for b in branches if (b["repo"], b["branch"]) not in merged_heads]


def conf(name):
    """A shell-style NAME="value" from autopilot.conf (single-line values only)."""
    try:
        with open(CONF, encoding="utf-8") as fh:
            for line in fh:
                m = re.match(r'\s*' + name + r'=(["\']?)(.*)\1\s*$', line)
                if m:
                    return m.group(2)
    except OSError:
        pass
    return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("keys", nargs="+")
    ap.add_argument("--repos", default=conf("AP_REPOS"))
    ap.add_argument("--org", default=conf("AP_GH_ORG"))
    ap.add_argument("--fetch", action="store_true", help="git fetch each repo first")
    a = ap.parse_args()
    keys = [k.upper() for k in a.keys]
    repos = [x for x in re.split(r"[,\s]+", a.repos) if x]
    if not repos or not a.org:
        sys.exit("ticket-state.py: set AP_REPOS and AP_GH_ORG in autopilot.conf (or pass --repos/--org)")
    sessions = find_sessions(keys)
    refs = repo_refs(repos, a.fetch)
    all_prs = repo_prs(repos, a.org)
    for k in keys:
        br = find_branches(k, refs)
        prs = find_prs(k, all_prs)
        v, why, s = verdict(sessions[k], br, prs)
        print(json.dumps({"key": k, "verdict": v, "reason": why, "resume": s,
                          "sessions": sessions[k], "branches": br, "prs": prs}))
        sys.stdout.flush()


if __name__ == "__main__":
    main()
