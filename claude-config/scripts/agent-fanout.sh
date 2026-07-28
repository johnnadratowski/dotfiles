#!/bin/bash
# Fleet orchestration backing script for the /agent-fanout skill.
#
# Subcommands:
#   status                          Read-only fleet snapshot (incl. CTX% per agent).
#   merge-down [targeting]          Canned: tell peers to run `/base-merge down`.
#   send [targeting] --stdin <<BODY Message a targeted set (reuses agent-send.sh).
#   restart --yes [--clean] [targ.]  Kill idle agents' claude, relaunch `claude --continue`
#                                    (or a FRESH session with --clean, discarding history).
#   compact --yes [--threshold N]   Inject `/compact` into idle agents at/above N% context.
#
# Targeting (all but status): --role feature|review|test|coordinator|all (default all) ·
#   --only name1,name2 (explicit set) · --exclude a,b · --threshold N (compact) · --dry-run.
# CTX% finds each agent's transcript via recorded transcript_path/cwd sidecars (tmux only as
# an optional fallback); window = $WORKFLOW_CTX_WINDOW or a model default (opus/sonnet-4.x→1M).
# Self is ALWAYS excluded. Roles derive from the agent name (matches resolve_role).
#
# SAFETY: `restart` is destructive (kills the live claude in each pane). It requires
# --yes AND only acts on IDLE agents (skips BUSY / copy-mode). The /agent-fanout SKILL
# passes --yes ONLY after explicit user confirmation in that turn — never blanket-run it.

set -u
reg="$HOME/.claude/running-agents"
here="$(cd "$(dirname "$0")" && pwd)"
SEND="$here/agent-send.sh"
# Load WORKFLOW_BASE_BRANCH (default main) for the merge-down body + behind-count.
# shellcheck disable=SC1090
[ -r "$here/_config.sh" ] && . "$here/_config.sh"
# shellcheck disable=SC1090
[ -r "$here/_fleet.sh" ] && . "$here/_fleet.sh"   # fleet_self_token/_tmux_ok/_alive/_find_self
BASE="${WORKFLOW_BASE_BRANCH:-main}"

# Delegates to fleet_resolve_role() in _fleet.sh (the single source of the name→role
# patterns) so status/targeting can never classify an agent differently from the role
# context it was booted with (e.g. "x-print" must NOT read as review).
role_of() { fleet_resolve_role "$1"; }
# Identity/liveness via the shared helper (tmux-optional); fall back inline if unsourced.
self_name() { fleet_find_self "$reg" 2>/dev/null; }
# Busy via the canonical predicate (fleet_busy, _fleet.sh); inline fallback only if unsourced.
is_busy()  {
  if command -v fleet_busy >/dev/null 2>&1; then fleet_busy "$1"
  else local m="$HOME/.claude/agent-busy/$1"; [ -f "$m" ] && [ -n "$(find "$m" -mmin "-${WORKFLOW_BUSY_STALE_MIN:-30}" 2>/dev/null)" ]; fi
}
# Errored = a StopFailure marker (mark-error.sh; cleared on recovery). Not time-windowed —
# a stuck/errored agent keeps showing ERR until it recovers or dies.
is_errored() { [ -f "$HOME/.claude/agent-error/$1" ]; }
pane_in_mode() { [ "$(tmux display-message -p -t "$1" '#{pane_in_mode}' 2>/dev/null || echo 0)" = "1" ]; }
# A pane is "at a shell" (ready for a relaunch) when its foreground process is a shell,
# not claude/node. Used to avoid sending the relaunch into a dying claude / its SessionEnd
# survey (which would eat the keystrokes — DX-jn-8-025).
pane_is_shell() { case "$(tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null)" in bash|zsh|fish|sh|-bash|-zsh|-fish|-sh) return 0;; *) return 1;; esac; }
alive() { fleet_alive "$1" "$2"; }

# --- Context usage (DX-jn-8-018) ----------------------------------------------
# Find an agent's live transcript WITHOUT requiring tmux. Precedence:
#   1) recorded transcript_path sidecar (direct)         2) recorded cwd → project dir
#   3) tmux pane_current_path → project dir (optional)   else: unknown.
_ctx_transcript() {  # name pane -> transcript path (empty if not resolvable)
  local name="$1" pane="$2" p cwd pd
  p="$(cat "$HOME/.claude/agents/$name.transcript" 2>/dev/null)"
  [ -n "$p" ] && [ -f "$p" ] && { echo "$p"; return; }
  cwd="$(cat "$HOME/.claude/agents/$name.cwd" 2>/dev/null)"
  if [ -z "$cwd" ] && [ -n "$pane" ] && command -v tmux >/dev/null 2>&1; then
    cwd="$(tmux display -p -t "$pane" '#{pane_current_path}' 2>/dev/null)"
  fi
  [ -n "$cwd" ] || return
  pd="$HOME/.claude/projects/$(printf '%s' "$cwd" | tr -c 'A-Za-z0-9' '-')"
  [ -d "$pd" ] || return
  ls -t "$pd"/*.jsonl 2>/dev/null | head -1
}

# Echo "pct raw" (e.g. "25 253k") for the agent's main-loop context, or nothing.
# Window: $WORKFLOW_CTX_WINDOW if set, else model table (opus/sonnet-4.x → 1M, else 200k).
ctx_info() {  # name pane
  local path; path="$(_ctx_transcript "$1" "$2")"; [ -n "$path" ] && [ -f "$path" ] || return
  tail -n 1200 "$path" 2>/dev/null | python3 -c '
import sys, os, json
ctx = 0; model = None
for line in sys.stdin:
    try: o = json.loads(line)
    except Exception: continue
    if o.get("isSidechain"): continue          # skip subagent turns — main loop only
    u = (o.get("message") or {}).get("usage")
    if not u: continue
    ctx = (u.get("input_tokens",0) or 0) + (u.get("cache_creation_input_tokens",0) or 0) + (u.get("cache_read_input_tokens",0) or 0)
    model = (o.get("message") or {}).get("model") or model
if not ctx: sys.exit(0)
env = os.environ.get("WORKFLOW_CTX_WINDOW","").strip()
if env.isdigit() and int(env) > 0:
    win = int(env)
else:
    m = (model or "").lower()
    # Window detection, most-explicit first. The previous rule was `"opus-4" in m or
    # "sonnet-4" in m`, which is version-PINNED: every new model silently fell through to
    # 200k and reported a nonsense percentage (a 1M-window Opus 5 session at 714k tokens
    # displayed as 357%). Anything version-pinned re-breaks on the next release, so:
    #   1. an explicit window marker in the id ("[1m]", "-1m") — the id often states it
    #   2. else a family + major-version test, so opus/sonnet 4 AND ANYTHING NEWER get 1M
    #   3. else the conservative 200k default
    import re as _re
    if "1m" in _re.findall(r"\[([^\]]*)\]", m) or m.endswith("-1m") or "[1m]" in m:
        win = 1000000
    else:
        _fam = _re.search(r"(opus|sonnet)[-_]?(\d+)", m)
        win = 1000000 if (_fam and int(_fam.group(2)) >= 4) else 200000
pct = round(100 * ctx / win)
raw = "%dk" % round(ctx/1000) if ctx >= 1000 else str(ctx)
print("%d %s" % (pct, raw))
'
}

# "⚠"/"🔴" flag for a percentage (empty below 80).
ctx_flag() { if [ "${1:-0}" -ge 90 ] 2>/dev/null; then printf '🔴'; elif [ "${1:-0}" -ge 80 ] 2>/dev/null; then printf '⚠'; fi; }

enumerate() {  # args: role only_csv exclude_csv -> "name pid pane" per live peer (deduped, minus self)
  local want_role="$1" only="$2" excl="$3" self; self="$(self_name)"; shopt -s nullglob
  local seen=" "
  for f in "$reg"/*; do
    [ -f "$f" ] || continue
    local bn name pid pane; bn="$(basename "$f")"; name="${bn%.*}"; pid="${bn##*.}"; pane="$(cat "$f" 2>/dev/null)"
    # Dedupe check first, but mark "seen" only AFTER the liveness check passes —
    # otherwise a stale twin entry (dead pid globbing first) consumes the name and
    # hides the live agent from every fan-out (same pattern as agent-broadcast.sh).
    case "$seen" in *" $name "*) continue;; esac
    [ "$name" = "$self" ] && continue
    alive "$pid" "$pane" || continue
    seen="$seen$name "
    case ",$excl," in *",$name,"*) continue;; esac
    [ -n "$only" ] && { case ",$only," in *",$name,"*) ;; *) continue;; esac; }
    [ "$want_role" != all ] && [ "$(role_of "$name")" != "$want_role" ] && continue
    printf '%s %s %s\n' "$name" "$pid" "$pane"
  done
}

ROLE=all; ONLY=""; EXCL=""; DRY=0; YES=0; STDIN=0; THRESH=80; CLEAN=0
parse() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --role) shift; ROLE="${1:-all}";;
      --only) shift; ONLY="${1:-}";;
      --exclude) shift; EXCL="${1:-}";;
      --threshold) shift; THRESH="${1:-80}";;
      --dry-run) DRY=1;;
      --yes) YES=1;;
      --clean) CLEAN=1;;
      --stdin) STDIN=1;;
      *) echo "unknown argument: $1" >&2; exit 2;;
    esac; shift
  done
}

cmd="${1:-status}"; shift || true
parse "$@"

case "$cmd" in
  status)
    self="$(self_name)"; basesha="$(git rev-parse --short "$BASE" 2>/dev/null || echo '?')"; shopt -s nullglob
    printf '%-14s %-11s %-9s %-24s %-7s %s\n' NAME ROLE STATE BRANCH CTX PANE
    # Pre-scan: names with at least one LIVE registry entry, so a stale twin
    # (dead pid globbing first) neither shadows nor duplicates the live row.
    live_names=" "
    for f in "$reg"/*; do
      [ -f "$f" ] || continue
      bn="$(basename "$f")"; n="${bn%.*}"; p="${bn##*.}"; pa="$(cat "$f" 2>/dev/null)"
      alive "$p" "$pa" && live_names="$live_names$n "
    done
    seen=" "
    for f in "$reg"/*; do
      [ -f "$f" ] || continue
      bn="$(basename "$f")"; name="${bn%.*}"; pid="${bn##*.}"; pane="$(cat "$f" 2>/dev/null)"
      case "$seen" in *" $name "*) continue;; esac
      st=live
      if ! alive "$pid" "$pane"; then
        case "$live_names" in *" $name "*) continue;; esac   # live twin exists — skip the stale row
        st=STALE
      fi
      seen="$seen$name "
      # errored takes precedence over busy/idle (busy is cleared by mark-error.sh on StopFailure).
      errnote=""
      if is_errored "$name"; then st="$st/ERR"; errnote="  ⚠ $(head -c 24 "$HOME/.claude/agent-error/$name" 2>/dev/null | tr -d '\n')"
      elif is_busy "$name"; then st="$st/BUSY"
      else st="$st/idle"; fi
      br="$(cat "$HOME/.claude/agents/$name" 2>/dev/null || echo '?')"
      behind="$(git rev-list --count "${br}..${BASE}" 2>/dev/null || echo '?')"
      ci="$(ctx_info "$name" "$pane")"; if [ -n "$ci" ]; then ctxd="$(ctx_flag "${ci%% *}")${ci%% *}%"; else ctxd='—'; fi
      printf '%-14s %-11s %-9s %-24s %-7s %s%s%s\n' "$name" "$(role_of "$name")" "$st" "$br (behind $behind)" "$ctxd" "$pane" "$([ "$name" = "$self" ] && echo '  <- you')" "$errnote"
    done
    echo "local $BASE @ $basesha   (CTX = main-loop context vs window; ⚠≥80% 🔴≥90%; window via WORKFLOW_CTX_WINDOW or model default)"
    ;;

  merge-down|send)
    if [ "$cmd" = merge-down ]; then
      body="Fleet sync: local \`$BASE\` advanced. Please run \`/base-merge down\` to pick it up; if the down-merge conflicts, resolve it normally. Reply when done (or if blocked)."
    else
      [ "$STDIN" = 1 ] || { echo "send: pass --stdin and pipe the body via heredoc" >&2; exit 2; }
      body="$(cat)"
    fi
    targets="$(enumerate "$ROLE" "$ONLY" "$EXCL")"
    [ -n "$targets" ] || { echo "no live peers match (role=$ROLE only=$ONLY exclude=$EXCL)"; exit 1; }
    echo "recipients:"; echo "$targets" | awk '{print "  - "$1}'
    if [ "$DRY" = 1 ]; then echo "(dry-run — nothing sent)"; exit 0; fi
    echo "$targets" | while read -r name pid pane; do
      err="$(printf '%s' "$body" | "$SEND" "$name" --stdin 2>&1 >/dev/null)" \
        && echo "  sent -> $name" \
        || echo "  FAILED -> $name${err:+ — $(printf '%s' "$err" | head -1)}"
    done
    ;;

  resume-errored|nudge-errored)
    # Nudge agents that StopFailured (error marker present, e.g. an Anthropic rate-limit)
    # to continue — the common rate-limit case. They're stopped at their prompt but ALIVE,
    # so a direct tmux nudge resumes them (no inbox/drain — a stopped agent won't drain).
    # Targets ONLY errored agents (narrow, safe set); honours --role/--only/--exclude.
    # Custom continue-text via --stdin, else a sensible default. (DX — rate-limit ergonomics.)
    if ! fleet_tmux_ok 2>/dev/null; then
      echo "resume-errored needs tmux (drives panes via send-keys) — unavailable, skipping." >&2; exit 0
    fi
    if [ "$STDIN" = 1 ]; then body="$(cat)"; else
      body="Continue — the API rate limit should have cleared. Resume where you left off."
    fi
    errored=""
    while read -r name pid pane; do
      [ -n "$name" ] || continue
      is_errored "$name" && errored="${errored}${name} ${pid} ${pane}"$'\n'
    done <<< "$(enumerate "$ROLE" "$ONLY" "$EXCL")"
    errored="$(printf '%s' "$errored" | sed '/^[[:space:]]*$/d')"
    [ -n "$errored" ] || { echo "no errored agents (no fresh ~/.claude/agent-error/* among live peers matching role=$ROLE only=$ONLY exclude=$EXCL)"; exit 0; }
    echo "errored agents to nudge:"; printf '%s\n' "$errored" | awk '{print "  - "$1" (pane "$3") ⚠ "}'
    if [ "$DRY" = 1 ]; then echo "(dry-run — nothing nudged)"; exit 0; fi
    printf '%s\n' "$errored" | while read -r name pid pane; do
      [ -n "$pane" ] || continue
      if pane_in_mode "$pane"; then echo "  SKIP $name — pane in copy-mode"; continue; fi
      tmux send-keys -t "$pane" -l "$body"; tmux send-keys -t "$pane" Enter
      echo "  nudged $name (pane $pane) — continue"
    done
    ;;

  restart)
    if ! fleet_tmux_ok 2>/dev/null; then
      echo "restart needs tmux (it drives panes via send-keys) — tmux unavailable, skipping. Restart the agent manually." >&2; exit 0
    fi
    targets="$(enumerate "$ROLE" "$ONLY" "$EXCL")"
    [ -n "$targets" ] || { echo "no live peers match (role=$ROLE only=$ONLY exclude=$EXCL)"; exit 1; }
    echo "restart candidates:"; echo "$targets" | awk '{print "  - "$1" (pane "$3")"}'
    if [ "$DRY" = 1 ]; then echo "(dry-run — nothing restarted)"; exit 0; fi
    if [ "$YES" != 1 ]; then
      echo "REFUSING: restart needs --yes (the /agent-fanout skill passes it only after you confirm)." >&2; exit 3
    fi
    echo "$targets" | while read -r name pid pane; do
      if is_busy "$name"; then echo "  SKIP $name — BUSY (mid-turn)"; continue; fi
      if pane_in_mode "$pane"; then echo "  SKIP $name — pane in copy-mode"; continue; fi
      echo "  restarting $name (pid $pid, pane $pane) ..."
      tmux send-keys -t "$pane" C-c; sleep 1; tmux send-keys -t "$pane" C-c
      for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
      if kill -0 "$pid" 2>/dev/null; then echo "    claude didn't exit on C-c; sending kill"; kill "$pid" 2>/dev/null; sleep 1; fi
      # Settle to a shell before relaunching. Killing claude pops its SessionEnd survey
      # ("How is Claude doing this session?"); relaunching before the shell is ready lets
      # that survey eat the keystrokes so `claude --continue` never runs (DX-jn-8-025 —
      # observed leaving agents at a bare shell, unregistered). Wait for the shell,
      # dismissing any lingering modal. (feedbackSurveyRate=0 in settings removes the
      # survey at the source; this is the belt-and-suspenders for any startup/exit modal.)
      for _ in $(seq 1 20); do pane_is_shell "$pane" && break; tmux send-keys -t "$pane" Escape 2>/dev/null; sleep 0.5; done
      pane_is_shell "$pane" || echo "    WARN — pane $pane not at a shell after kill; relaunch may not land"
      # Relaunch + verify re-registration, retrying up to 3x. --name sets the session name
      # at launch, which settles it before the hook's settle-recheck runs, so the /rename
      # keystroke fallback is never reached (DX-jn-8-024). NEVER re-send while claude is
      # already running (the pane isn't a shell) — that would type into claude's prompt.
      # --clean drops --continue: the agent comes back with a FRESH conversation instead of
      # resuming. Use it when the point of the restart is to shed stale in-context state —
      # e.g. after a workflow change, where resuming would carry the old assumptions forward
      # and defeat the restart. It DISCARDS that agent's conversation history, so the skill
      # confirms it separately from an ordinary restart.
      # Note --name is still passed on the clean path too (it names the session at launch).
      ok=""
      for attempt in 1 2 3; do
        if pane_is_shell "$pane"; then
          if [ "$CLEAN" = 1 ]; then
            tmux send-keys -t "$pane" -l "claude --name \"$name\""
          else
            tmux send-keys -t "$pane" -l "claude --continue --name \"$name\""
          fi
          tmux send-keys -t "$pane" Enter
        fi
        for _ in $(seq 1 20); do
          nf="$(ls "$reg/$name".* 2>/dev/null | head -1)"
          if [ -n "$nf" ] && [ "${nf##*.}" != "$pid" ] && [ "$(cat "$nf" 2>/dev/null)" = "$pane" ]; then ok=1; break; fi
          sleep 1
        done
        [ -n "$ok" ] && break
        echo "    (attempt $attempt/3) $name not re-registered yet; retrying"
      done
      [ -n "$ok" ] && echo "    OK — $name back as $(basename "$nf")" || echo "    WARN — $name not re-registered after 3 attempts; check pane $pane"
    done
    ;;

  compact)
    if ! fleet_tmux_ok 2>/dev/null; then
      echo "compact needs tmux (it injects /compact via send-keys) — tmux unavailable, skipping. (A tmux-free compact would need the command-mailbox model; see DX-jn-8-019.)" >&2; exit 0
    fi
    targets="$(enumerate "$ROLE" "$ONLY" "$EXCL")"
    [ -n "$targets" ] || { echo "no live peers match (role=$ROLE only=$ONLY exclude=$EXCL)"; exit 1; }
    # Keep only agents at/above the context threshold; annotate each with pct + raw.
    cand=""
    while read -r name pid pane; do
      [ -n "$name" ] || continue
      ci="$(ctx_info "$name" "$pane")"
      if [ -z "$ci" ]; then echo "  skip $name — context unknown"; continue; fi
      pct="${ci%% *}"; raw="${ci#* }"
      if [ "$pct" -lt "$THRESH" ] 2>/dev/null; then echo "  skip $name — ${pct}% < ${THRESH}%"; continue; fi
      cand="$cand$name $pid $pane $pct $raw"$'\n'
    done <<EOF
$targets
EOF
    [ -n "$cand" ] || { echo "no agents at/above ${THRESH}% context."; exit 0; }
    echo "compact candidates (≥${THRESH}%):"; printf '%s' "$cand" | awk 'NF{print "  - "$1"  "$4"% ("$5")  pane "$3}'
    if [ "$DRY" = 1 ]; then echo "(dry-run — nothing compacted)"; exit 0; fi
    if [ "$YES" != 1 ]; then
      echo "REFUSING: compact needs --yes (the /agent-fanout skill passes it only after you confirm)." >&2; exit 3
    fi
    printf '%s' "$cand" | while read -r name pid pane pct raw; do
      [ -n "$name" ] || continue
      if is_busy "$name"; then echo "  SKIP $name — BUSY (mid-turn)"; continue; fi
      if pane_in_mode "$pane"; then echo "  SKIP $name — pane in copy-mode"; continue; fi
      tmux send-keys -t "$pane" -l "/compact"; tmux send-keys -t "$pane" Enter
      echo "  /compact -> $name (${pct}%)"
    done
    ;;

  *) echo "usage: agent-fanout.sh {status|merge-down|send|restart|compact|resume-errored} [--role R] [--only a,b] [--exclude a,b] [--threshold N] [--dry-run] [--yes]" >&2; exit 2;;
esac
