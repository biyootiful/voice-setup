#!/bin/zsh
# Secret access for agents. The point is that an agent should never have to ask
# "where do we get the access token?" twice — and should never see a secret
# travel through a prompt, a transcript, or a file on disk.
#
# Two halves:
#   • the VALUE lives in the macOS keychain, under the service name agent/<name>
#   • the PROVENANCE (where it came from, who owns it) lives in the index below,
#     and in ~/.config/voice-setup/org-knowledge.md
#
# Security boundary, deliberately asymmetric:
#   • agents READ    — `get`, `has`, `list`
#   • humans WRITE   — `need` prints the command for YOU to run
# An agent never receives a secret value as text it could echo, log, or commit.
# Only the agent/ prefix is reachable, so the rest of your keychain (iCloud,
# wifi, browser passwords) is not exposed to an agent or to a prompt injection.

set -u
INDEX="$HOME/.config/voice-setup/secrets-index.txt"
PREFIX="agent/"
mkdir -p "$(dirname "$INDEX")"; [[ -f "$INDEX" ]] || : > "$INDEX"

die() { print -u2 -- "$@"; exit 1; }

usage() {
  cat <<'USAGE'
agent-secret.sh <command>

  list                      names + provenance of every registered secret (never values)
  has   <name>              exit 0 if the value is in the keychain, 1 if not
  get   <name>              print the value on stdout — use as "$(agent-secret.sh get x)",
                            never echo it, never write it to a file
  need  <name> "<how to get it>" [owner]
                            register a secret you need but do not have, and print the
                            command for the HUMAN to run. Does not block.

Agents: call `list` before asking anyone for a credential. If what you need is
registered, `get` it. If it is not, call `need` and keep working on something else.
USAGE
}

cmd="${1:-}"; shift 2>/dev/null || true

case "$cmd" in
  list)
    if [[ ! -s "$INDEX" ]]; then
      print -- "(no secrets registered yet)"
      exit 0
    fi
    printf '%-26s %-9s %s\n' "NAME" "IN KEYCHAIN" "WHERE IT COMES FROM"
    while IFS='|' read -r name prov owner; do
      [[ -z "$name" ]] && continue
      if security find-generic-password -s "${PREFIX}${name}" -w >/dev/null 2>&1; then
        state="yes"
      else
        state="MISSING"
      fi
      printf '%-26s %-9s %s%s\n' "$name" "$state" "$prov" "${owner:+  (owner: $owner)}"
    done < "$INDEX"
    ;;

  has)
    [[ $# -ge 1 ]] || die "usage: agent-secret.sh has <name>"
    security find-generic-password -s "${PREFIX}$1" -w >/dev/null 2>&1
    ;;

  get)
    [[ $# -ge 1 ]] || die "usage: agent-secret.sh get <name>"
    v="$(security find-generic-password -s "${PREFIX}$1" -w 2>/dev/null)" || {
      print -u2 -- "NOT IN KEYCHAIN: $1"
      print -u2 -- "Register what you know about it, then carry on with other work:"
      print -u2 -- "  agent-secret.sh need $1 \"<how to get it>\" [owner]"
      exit 1
    }
    printf '%s' "$v"
    ;;

  need)
    [[ $# -ge 2 ]] || die "usage: agent-secret.sh need <name> \"<how to get it>\" [owner]"
    name="$1"; prov="$2"; owner="${3:-}"
    grep -q "^${name}|" "$INDEX" 2>/dev/null \
      || print -- "${name}|${prov}|${owner}" >> "$INDEX"
    cat <<EOF
Registered "$name" as needed. It is NOT in the keychain yet.

  where it comes from : $prov
  owner               : ${owner:-unknown}

A HUMAN must add the value — run this yourself so the secret never passes
through the agent, a prompt, or a transcript:

  security add-generic-password -a agent -s ${PREFIX}${name} -w -U

(-w with no argument prompts for the value without echoing it to the terminal.)

Agent: do not wait for this. Note it in your NEEDS YOU block and keep working.
EOF
    exit 1
    ;;

  ""|-h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
