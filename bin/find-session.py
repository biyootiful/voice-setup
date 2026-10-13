#!/usr/bin/env python3
"""Find a Claude Code session from a plain-English description of it.

    find-session.py "find me the session where it worked on onboarding doc creation"
    find-session.py "which session is ABC460"
    find-session.py "the one that made this PR https://github.com/org/repo/pull/905"
    find-session.py --recent              # newest sessions, no query
    find-session.py "..." --json          # for Hammerspoon (⌃⌘F)
    find-session.py "..." --no-llm        # keyword ranking only (fast, offline)

You ask it the way you would ask an agent. The phrasing that actually comes up:
a topic ("the druid query case insensitive issue"), a ticket written any way
("ABC460", "abc-460"), a person who was mentioned ("Sam Lee", "Priya"), a PR
link, recency ("I just used it", "yesterday"), or several at once ("find them").

Two stages, because neither alone is good enough:
  1. Keyword shortlist over a cached index of every transcript: what you typed,
     what the agent answered, tool output, branches it cut, PRs it touched,
     ticket keys. Cheap and exhaustive, but literal.
  2. Haiku reranks the shortlist against your words and says why each one
     matches. That is what turns "the butler bot session" into the right row.
     If claude is unavailable, stage 1's order is used.

The index lives in ~/.cache/voice-setup/session-index.json and is refreshed
incrementally (a transcript is re-read only when its size or mtime changes).
"""

import argparse
import glob
import json
import math
import os
import re
import subprocess
import sys
import time

PROJECTS = os.path.expanduser("~/.claude/projects")
CACHE = os.path.expanduser("~/.cache/voice-setup/session-index.json")
INDEX_VERSION = 3
BLOB_CAP = 60_000          # chars of searchable text kept per session
USER_KEEP = 24             # user messages kept for the reranker's card
SHORTLIST = 20
FINDER_OPENER = "SESSION FINDER"   # this script's own rerank prompt — never a result

KEY_RE = re.compile(r"\b([A-Z][A-Z0-9]{1,9})-(\d{1,6})\b")
LOOSE_KEY_RE = re.compile(r"\b([A-Za-z][A-Za-z0-9]{1,9}?)-?(\d{2,6})\b")
PR_RE = re.compile(r"github\.com/([\w.-]+)/([\w.-]+)/pull/(\d+)")
BRANCH_RE = re.compile(r"git\s+(?:checkout\s+-b|switch\s+-c|worktree\s+add\s+(?:\S+\s+)*?-b)\s+(\S+)")
# A session that was itself a "find me the session…" request echoes every word of
# the next such request; it is never the answer.
FIND_REQUEST_RE = re.compile(r"^\W*(?:\w+\W+){0,4}?(?:find|which|where)\b.{0,40}\bsess", re.I)
NOISE_OPENERS = ("This session is being continued", "Caveat:", "[Request interrupted")

STOP = set("""
a an the and or of to in on at for from by with about into over as is was were be
been being it its this that these those there here which what who whom whose
where when why how i me my we us our you your he she they them his her their
find found finding show give get pull load open bring look check search see
session sessions sesh sessoin convo conversation chat thread one ones agent claude
can could would should will please pls just also again regarding related re
had has have having did do does done doing worked working work was supposed
mentioned mention talked talking discuss discussed thing stuff some any all
up out yeah ok okay hey btw so then like really
""".split())
RECENT_WORDS = {"just", "recent", "recently", "latest", "last", "today", "earlier",
                "yesterday", "now", "currently", "ongoing", "open"}


# --------------------------------------------------------------------------- index

def _text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        out = []
        for b in content:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "text":
                out.append(b.get("text", ""))
            elif b.get("type") == "tool_result":
                out.append(_text(b.get("content")))
            elif b.get("type") == "tool_use":
                out.append(json.dumps(b.get("input", {}))[:600])
        return "\n".join(out)
    return ""


def _clean(t):
    t = re.sub(r"<(system-reminder|command-[a-z]+|local-command-[a-z]+)>.*?</\1>", " ", t, flags=re.S)
    t = re.sub(r"<[^>]{1,40}>", " ", t)
    return re.sub(r"\s+", " ", t).strip()


def index_one(path):
    cwd = sid = None
    first_ts = last_ts = None
    opener = ""
    users, blob = [], []
    keys, prs, branches = set(), set(), set()
    size = 0
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if '"type":"user"' not in line and '"type":"assistant"' not in line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if o.get("isSidechain"):
                continue
            cwd = o.get("cwd") or cwd
            sid = o.get("sessionId") or sid
            ts = o.get("timestamp")
            if ts:
                first_ts = first_ts or ts
                last_ts = ts
            msg = o.get("message") or {}
            raw = _text(msg.get("content"))
            if not raw:
                continue
            for m in KEY_RE.finditer(raw):
                keys.add(f"{m.group(1)}-{m.group(2)}")
            for m in PR_RE.finditer(raw):
                prs.add(f"{m.group(1)}/{m.group(2)}#{m.group(3)}".lower())
            for m in BRANCH_RE.finditer(raw):
                branches.add(m.group(1).strip("'\""))
            t = _clean(raw)
            if not t:
                continue
            is_human = o["type"] == "user" and isinstance(msg.get("content"), str) or (
                o["type"] == "user" and isinstance(msg.get("content"), list)
                and any(isinstance(b, dict) and b.get("type") == "text" for b in msg["content"]))
            if is_human:
                # "Yep" makes a useless title; the first real sentence does not.
                if (not opener or len(opener) < 15) and not t.startswith(NOISE_OPENERS):
                    opener = t[:300] if not opener or len(t) >= 15 else opener
                users.append(t[:300])
            if size < BLOB_CAP:
                piece = t[:1500] if is_human else t[:500]
                blob.append(piece)
                size += len(piece)
    if len(users) > USER_KEEP:
        users = users[: USER_KEEP // 2] + users[-USER_KEEP // 2:]
    return {
        "sid": sid or os.path.basename(path)[:-6],
        "cwd": cwd or "",
        "first": first_ts, "last": last_ts,
        "opener": opener,
        "users": users,
        "keys": sorted(keys), "prs": sorted(prs), "branches": sorted(branches),
        "blob": " ".join(blob).lower(),
    }


def load_index():
    try:
        with open(CACHE) as fh:
            idx = json.load(fh)
        if idx.get("v") != INDEX_VERSION:
            idx = {"v": INDEX_VERSION, "files": {}}
    except (OSError, ValueError):
        idx = {"v": INDEX_VERSION, "files": {}}
    files = idx["files"]
    seen = set()
    changed = False
    for path in glob.glob(os.path.join(PROJECTS, "*", "*.jsonl")):
        try:
            st = os.stat(path)
        except OSError:
            continue
        if not st.st_size:
            continue
        seen.add(path)
        stamp = [st.st_size, int(st.st_mtime)]
        e = files.get(path)
        if e and e.get("stamp") == stamp:
            continue
        try:
            e = index_one(path)
        except OSError:
            continue
        e["stamp"] = stamp
        e["mtime"] = int(st.st_mtime)
        files[path] = e
        changed = True
    for p in list(files):
        if p not in seen:
            del files[p]
            changed = True
    if changed:
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)
        tmp = CACHE + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(idx, fh)
        os.replace(tmp, CACHE)
    return [e for e in files.values()
            if e["opener"] and not e["opener"].startswith(FINDER_OPENER)]


# --------------------------------------------------------------------------- query

def parse_query(q):
    keys = {f"{m.group(1).upper()}-{int(m.group(2))}" for m in LOOSE_KEY_RE.finditer(q)
            if not m.group(1).isdigit() and m.group(1).lower() not in ("pr", "v", "pull")}
    prs = {f"{m.group(1)}/{m.group(2)}#{m.group(3)}".lower() for m in PR_RE.finditer(q)}
    pr_nums = set(re.findall(r"(?:#|\bpr\s*#?\s*|/pull/)(\d{2,6})\b", q, flags=re.I))
    q2 = PR_RE.sub(" ", q)
    words = [w for w in re.findall(r"[a-z0-9][a-z0-9._-]*", q2.lower())]
    recent = any(w in RECENT_WORDS for w in words)
    terms = [w for w in words if w not in STOP and len(w) > 1 and not w.isdigit()]
    phrases = [" ".join(terms[i:i + 2]) for i in range(len(terms) - 1)]
    return {"keys": keys, "prs": prs, "pr_nums": pr_nums, "terms": terms,
            "phrases": phrases, "recent": recent}


def score(e, q, now):
    s = 0.0
    head = (e["opener"] + " " + " ".join(e["branches"])).lower()
    users = " ".join(e["users"]).lower()
    blob = e["blob"]
    for k in q["keys"]:
        if k in e["keys"]:
            s += 12 if k.lower() in head or k in e["opener"] else 8
    for p in q["prs"]:
        if p in e["prs"]:
            s += 15
    for n in q["pr_nums"]:
        if any(p.endswith("#" + n) for p in e["prs"]):
            s += 6
    for t in q["terms"]:
        if t in head:
            s += 4
        if t in users:
            s += 2
        c = blob.count(t)
        if c:
            s += 1 + math.log(c)
    for p in q["phrases"]:
        if p in blob:
            s += 3
    if FIND_REQUEST_RE.match(e["opener"]) and len(e["users"]) <= 6:
        s *= 0.2
    age_days = max(0.0, (now - e["mtime"]) / 86400)
    s += (6 if q["recent"] else 1.5) / (1 + age_days)
    return s


def card(e, i, q):
    hits = [u for u in e["users"] if any(t in u.lower() for t in q["terms"])][:4]
    others = [u for u in e["users"] if u not in hits][:3]
    when = time.strftime("%b %d %H:%M", time.localtime(e["mtime"]))
    return "\n".join(filter(None, [
        f"[{i}] last active {when} · dir {os.path.basename(e['cwd']) or '?'}",
        f"  opened with: {e['opener'][:220]}",
        e["keys"] and f"  tickets: {', '.join(e['keys'][:12])}",
        e["prs"] and f"  PRs: {', '.join(e['prs'][:8])}",
        e["branches"] and f"  branches: {', '.join(e['branches'][:6])}",
        *[f"  user said: {u[:200]}" for u in hits + others],
    ]))


def rerank(query, cands, q, model):
    now = time.strftime("%Y-%m-%d %H:%M")
    prompt = f"""{FINDER_OPENER}. Bi is looking for one of his past Claude Code sessions and
described it the way he talks to an agent. It is now {now}.

His words: "{query}"

Candidates (a keyword shortlist; it may contain none, one or several right answers):

""" + "\n\n".join(card(e, i, q) for i, e in enumerate(cands)) + """

Pick the sessions he means, best first, at most 5. Only include ones that plausibly
match: the topic, ticket, person, PR or timeframe he gave. If he asked for several
("find them"), include each. Prefer the session that did the work over one that
only mentioned it in passing, and never pick a session that was itself just a
search for a session.

Reply with ONLY a JSON array, no prose: [{"i": <index>, "why": "<under 12 words>"}]"""
    try:
        r = subprocess.run(
            ["claude", "-p", prompt, "--model", model, "--no-session-persistence",
             "--output-format", "text", "--setting-sources", "user"],
            capture_output=True, text=True, timeout=60, cwd=os.path.expanduser("~"))
        m = re.search(r"\[.*\]", r.stdout, flags=re.S)
        picks = json.loads(m.group(0)) if m else None
        out = []
        for p in picks or []:
            i = p.get("i")
            if isinstance(i, int) and 0 <= i < len(cands) and cands[i] not in [o[0] for o in out]:
                out.append((cands[i], str(p.get("why", ""))[:80]))
        return out if picks is not None else None
    except (OSError, subprocess.SubprocessError, ValueError):
        return None


def live_sids():
    try:
        ps = subprocess.run(["ps", "-axo", "command="], capture_output=True, text=True).stdout
    except OSError:
        return set()
    return set(re.findall(r"--resume\s+([0-9a-f-]{36})", ps))


def row(e, why, live):
    return {
        "sid": e["sid"], "cwd": e["cwd"],
        "when": time.strftime("%b %d %H:%M", time.localtime(e["mtime"])),
        "dir": os.path.basename(e["cwd"]),
        "title": e["opener"][:110],
        "why": why,
        "tickets": e["keys"][:6],
        "live": e["sid"] in live,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("query", nargs="*")
    ap.add_argument("--recent", action="store_true", help="newest sessions, no query")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--no-llm", action="store_true")
    ap.add_argument("--limit", type=int, default=5)
    ap.add_argument("--model", default="haiku")
    a = ap.parse_args()
    # Launched from Hammerspoon, PATH has no ~/.local/bin, where claude lives.
    os.environ["PATH"] = os.pathsep.join([os.path.expanduser("~/.local/bin"), "/opt/homebrew/bin",
                                          os.environ.get("PATH", "/usr/bin:/bin")])
    query = " ".join(a.query).strip()

    entries = load_index()
    now = time.time()
    live = live_sids()
    if a.recent or not query:
        res = [row(e, "", live) for e in sorted(entries, key=lambda e: -e["mtime"])[:max(a.limit, 15)]]
    else:
        q = parse_query(query)
        ranked = sorted(entries, key=lambda e: -score(e, q, now))
        cands = ranked[:SHORTLIST]
        picks = None if a.no_llm else rerank(query, cands, q, a.model)
        if picks is None:
            picks = [(e, "keyword match") for e in cands[:a.limit]]
        res = [row(e, why, live) for e, why in picks[:a.limit]]

    if a.json:
        print(json.dumps(res))
        return
    if not res:
        print("no matching session", file=sys.stderr)
        sys.exit(1)
    for i, r in enumerate(res, 1):
        print(f"{i}. {r['when']}  {r['dir']}{'  (open now)' if r['live'] else ''}")
        print(f"   {r['title']}")
        if r["why"]:
            print(f"   ↳ {r['why']}")
        print(f"   cd {r['cwd']} && claude --resume {r['sid']}")


if __name__ == "__main__":
    main()
