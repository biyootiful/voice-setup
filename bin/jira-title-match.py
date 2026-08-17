#!/usr/bin/env python3
"""Match Jira ticket TITLES against git branch names.

Called by jira-git-facts.sh for keys that came back NO_TRACE by key. Roughly 59%
of branches in some repos carry no Jira key at all (`dark-mode`,
`search-v2`, `invoice-flow`), so key matching alone is
blind to a lot of real, shipped work. Titles are the only other join available.

This is deliberately a WEAKER signal than the key match and is reported
separately — never as a deploy verdict. Measured precision on a real board was
roughly 3-4 correct out of 6 matches, so the output is "candidate, go verify",
not "this is deployed".

Two match directions, because branch names come in two shapes:
  A  a long Jira-generated branch (KEY-kebab-of-title) explains the whole ticket
     title. Catches work that shipped under a SIBLING ticket's branch, which is
     the one case where a branch carrying a different key still matters.
  B  a short hand-made branch is fully explained by the ticket title
     (`invoice-flow` vs "Invoice Flow: reconcile tabs + ..."). Needs
     more guards, since two generic words match almost anything.

Guards that matter (each one removed a real false positive during testing):
  * a branch matching MORE THAN ONE ticket is dropped as ambiguous — in testing,
    two-word branches matched four different tickets each
  * direction B requires at least one RARE matched word (document frequency across
    the ticket set), so a word common to the whole board can't carry a match
  * direction B rejects branches that already carry someone else's key — that branch
    is already attributed, and a 2-word overlap is coincidence
  * pure-boilerplate branch names (release/build/sync/test/backup...) are ignored

Usage:
  jira-title-match.py --titles <key\\ttitle tsv> --branches <repo\\tbranch\\tstate tsv> \\
                      --keys KEY-1 KEY-2 ...
Prints one line per match: "KEY | TITLE_MATCH:<state> | <detail>"
"""
import argparse, collections, re, sys

STOP = {'the','a','an','and','or','for','to','of','in','on','is','not','with','be',
        'when','it','its','are','but','from','by','as','at','via'}
# words that describe git bookkeeping rather than a feature
JUNK = {'test','fix','fixes','build','release','mr','branch','sync','develop','main',
        'origin','cherry','pick','cherrypick','improvements','update','updates','changes',
        'minor','wip','poc','tmp','temp','backup','hotfix','revert','lint','qc','qa','head'}
RARE_DF = 0.08          # a "rare" word appears in <=8% of ticket titles
PREFIX_RE = re.compile(r'^(feature|bugfix|hotfix|chore|fix|release|no-jira|nojira)[/_-]', re.I)
KEY_IN_NAME = re.compile(r'(^|[^A-Za-z0-9])([A-Za-z][A-Za-z0-9]+-\d+)')


def words(s):
    return [t for t in re.sub(r'[^a-z0-9]+', ' ', s.lower()).split() if t]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--titles', required=True)
    ap.add_argument('--branches', required=True)
    ap.add_argument('--keys', nargs='*', default=[])
    a = ap.parse_args()

    want = {k.upper() for k in a.keys}
    if not want:
        return

    titles = {}
    for line in open(a.titles, encoding='utf-8', errors='replace'):
        parts = line.rstrip('\n').split('\t')
        if len(parts) < 2:
            continue
        titles[parts[0].strip().upper()] = parts[1].strip()

    # document frequency is computed over ALL tickets, not just the wanted ones —
    # that is what makes "rare" mean rare on this board
    tickets = [(k, t, set(words(t)) - STOP) for k, t in titles.items()]
    df = collections.Counter()
    for _, _, toks in tickets:
        df.update(toks)
    n = max(len(tickets), 1)

    branches = []
    for line in open(a.branches, encoding='utf-8', errors='replace'):
        parts = line.rstrip('\n').split('\t')
        if len(parts) < 3:
            continue
        repo, name, state = parts[0], parts[1], parts[2]
        m = KEY_IN_NAME.search(name)
        own = m.group(2).upper() if m else None
        stripped = PREFIX_RE.sub('', name)
        stripped = re.sub(r'^[A-Za-z][A-Za-z0-9]+[-_]\d+[-_/]?', '', stripped)
        bt = set(words(stripped)) - STOP
        if not bt or bt <= JUNK:
            continue
        branches.append((repo, name, state, bt, own))

    # branch -> the tickets it could name
    cand = collections.defaultdict(list)
    for repo, name, state, bt, own in branches:
        for key, title, tt in tickets:
            if not tt or own == key:
                continue
            inter = tt & bt
            if not inter:
                continue
            cov_t = len(inter) / len(tt)
            cov_b = len(inter) / len(bt)
            rare = any(df[w] / n <= RARE_DF for w in inter)
            dir_a = cov_t >= 0.8 and len(tt) >= 4
            dir_b = cov_b >= 1.0 and len(bt) >= 2 and rare and own is None
            if dir_a or dir_b:
                cand[(repo, name, state)].append((key, 'A' if dir_a else 'B', inter))

    out = collections.defaultdict(list)
    for (repo, name, state), hits in cand.items():
        if len(hits) != 1:      # ambiguous -> not a signal
            continue
        key, direction, inter = hits[0]
        if key not in want:
            continue
        shared = ' '.join(sorted(inter))
        out[key].append(f"{repo}:{name} [{state}] (dir {direction}, shared words: {shared})")

    for key in sorted(out):
        for d in out[key]:
            state = re.search(r'\[(\w+)\]', d)
            print(f"{key} | TITLE_MATCH:{state.group(1) if state else '?'} | {d}")


if __name__ == '__main__':
    main()
