#!/bin/bash
# Shared fleet identity/liveness helpers (DX-jn-8-019). Source-only.
#
# The fleet keys each agent by an IDENTITY TOKEN so it works with OR without tmux:
#   - inside tmux  → the token is $TMUX_PANE (e.g. "%3")
#   - headless     → the token is "cwd:<absolute-cwd>" (one agent per worktree here)
# The registry file ~/.claude/running-agents/<name>.<pid> stores this token; self-id
# matches it; liveness is pid-based, with a tmux pane-check only when the token is a pane.
#
# This makes tmux OPTIONAL: registration, self-identification, mailbox delivery/drain,
# busy-marking and status all work headless. Only live remote-drive (send-keys nudge,
# restart, compact, rename) needs tmux — callers gate those on fleet_tmux_ok and skip
# gracefully when it's absent.

# Identity token for THIS process.
fleet_self_token() {
  if [ -n "${TMUX_PANE:-}" ]; then printf '%s' "$TMUX_PANE"; else printf 'cwd:%s' "$PWD"; fi
}

# True when tmux can actually be driven (inside a pane AND the binary exists).
fleet_tmux_ok() { [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; }

# fleet_alive <pid> <token> — pid must be alive; if the token is a tmux pane, the pane
# must still exist (best-effort — a missing tmux binary doesn't fail a pane token, since
# we can't disprove liveness without it).
fleet_alive() {
  kill -0 "$1" 2>/dev/null || return 1
  case "$2" in
    %*) command -v tmux >/dev/null 2>&1 && ! tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx "$2" && return 1 ;;
  esac
  return 0
}

# fleet_find_self <registry-dir> — echo the name whose registry entry matches our token.
fleet_find_self() {
  local d="$1" tok f; tok="$(fleet_self_token)"
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    [ "$(cat "$f" 2>/dev/null)" = "$tok" ] && { basename "$f" | sed 's/\.[0-9]*$//'; return 0; }
  done
  return 1
}

# fleet_busy <name> — a fresh busy marker (~/.claude/agent-busy/<name>, touched within
# WORKFLOW_BUSY_STALE_MIN minutes) means the agent is mid-turn. THE canonical predicate
# (DX-jn-cc-010/014).
#
# WHY THE WINDOW IS 30 MINUTES, NOT 5. The marker is touched at UserPromptSubmit and again
# at every PreToolUse — but a SINGLE long-running tool call touches it once and then runs
# for as long as it runs. A 5-minute window therefore reported a working agent as IDLE
# during any routine long call (a test sweep, a build, a poll loop), which is exactly when
# inbox-watcher.sh would re-nudge it; the nudge lands in the pane's input buffer, loses to
# the Stop-drain, and replays as a "message file gone" no-op that costs the recipient a
# turn each. That storm is what the busy check exists to prevent, so the window has to
# exceed the longest ordinary tool call, not the longest ordinary *turn*.
#
# The window only matters when an agent dies mid-turn WITHOUT clearing its marker — Stop
# (drain-inbox.sh), StopFailure (mark-error.sh) and SessionEnd (unregister-agent.sh) all
# clear it, so that means a hard crash. Cost of that case: peers stage messages without a
# live nudge for up to the window, and the agent's own Stop-drain delivers them when it
# returns. Cheaper than the duplicate storm, and it errs toward "busy" — the safe
# direction for every idle-GATED destructive action (restart, compact, fleet-layout down).
# The one place that costs something is crash RECOVERY: agent-fanout's restart/compact skip
# BUSY with no override, so a stale marker now blocks them for 30 min instead of 5. The
# escape is `rm ~/.claude/agent-busy/<name>` (documented in the agent-fanout skill).
#
# WORKFLOW_BUSY_STALE_MIN is an ENVIRONMENT override. **Invariant: no config file carries
# this value** — not `workflow.config`, not `workflow.config.local` (the house style points
# at `.local` for per-machine values, which is exactly the trap). `_config.test.sh` enforces
# it, and enforcing the ban on the VALUE is deliberate: only some of the six readers run in
# a shell that has loaded a config file, so a config value moves some and leaves the rest on
# the literal, and "busy" silently means two things depending on who asks. Which scripts load
# which file is a list that already grew once (statusline-role.sh sources both directly), and
# such lists go stale — "no config file carries this" does not. An environment export reaches
# every reader; a single literal default at every site cannot split.
#
# To change the default, edit EVERY occurrence of the literal — there are 7 across 6 files
# (this one, five inline fallbacks, and inbox-watcher.sh's startup banner, which reports the
# window and would otherwise lie). `_config.test.sh` asserts they all agree, so a missed one
# turns the suite red rather than shipping a silent disagreement.
#
# agent-fanout.sh, agent-send.sh, inbox-watcher.sh and statusline-fleet.sh all DELEGATE here
# (DX-jn-cc-011). Each keeps an inline copy only as a FALLBACK for a clone with no _fleet.sh, and
# each guards with `if command -v fleet_busy` — never `&& fleet_busy || inline`, in which the
# inline copy would run on every not-busy answer and the compound would be `fleet_busy OR inline`
# (two live predicates, biased toward "busy" — the direction that strands nudges). An undefined
# function would instead fail OPEN (busy reads as idle → duplicate nudges), which is why the
# fallback exists at all.
#
# NOTE the failure direction: an unreadable marker dir or a failed find reads as IDLE — right for
# status display, fail-OPEN for a kill gate. fleet-layout.sh's _down_busy wraps this with
# fail-closed unknown handling; use that (not this) to gate anything destructive.
fleet_busy() {
  local m="$HOME/.claude/agent-busy/$1"
  [ -f "$m" ] && [ -n "$(find "$m" -mmin "-${WORKFLOW_BUSY_STALE_MIN:-30}" 2>/dev/null)" ]
}

# fleet_turn_open <name> — is the target's turn OPEN (started, not yet ended)?
# Marker present, ANY AGE. This is the predicate for "may I type into this pane",
# and it is deliberately STRICTER than fleet_busy.
#
# fleet_busy applies a staleness window so a stuck marker cannot suppress a restart
# forever — correct for restart/compact, whose whole purpose is recovering a wedged
# agent. It is WRONG for the keystroke nudge, and the failure is not theoretical:
# an agent parked on an AskUserQuestion / permission prompt / plan approval is
# MID-TURN, so nothing re-touches its marker while it waits for a human. Past
# WORKFLOW_BUSY_STALE_MIN it reads as idle, the nudge fires, and
# `send-keys … Enter` lands on the OPEN SELECTOR — submitting an answer nobody
# chose. Observed in this fleet.
#
# A healthy live agent has NO marker between turns (Stop clears it), so a marker
# that exists means the turn genuinely never ended — and "blocked on a human" is by
# far its commonest cause. Same reasoning the Monocle hold marker already documents:
# a human can take hours, so it applies no staleness test either.
#
# Fails CLOSED. Worst case a message waits for the target's Stop-drain, which is
# durable and always delivers — trading a cheap failure (latency) to avoid an
# expensive one (an unintended answer, an auto-approved permission or plan).
fleet_turn_open() {
  [ -f "$HOME/.claude/agent-busy/$1" ]
}

# fleet_resolve_role <name> — canonical agent-name → role classifier
# (coordinator|test|review|feature). THE single source of these name patterns;
# register-agent.sh's resolve_role() and agent-fanout.sh's role_of() delegate here so
# status/targeting/role-context can never classify an agent differently. Pure pattern
# match — callers that ALSO honor a per-agent ~/.claude/agents/<name>.role override
# (register-agent.sh, agent-rename.sh, statusline-role.sh) apply that override first and
# only fall back to this.
# `team-lead` is the ONLY name Claude Code will let the lead answer to — it is a
# hardcoded constant there, so this is the canonical spelling, not a preference. The
# legacy `cc` / `*-cc` / `coordinator` spellings still MATCH (old sessions, old
# per-agent .role overrides, historical ids) but they all RESOLVE to `team-lead`, so
# there is exactly one role name downstream and one role doc: agent-roles/team-lead.md.
fleet_resolve_role() {
  case "$1" in
    team-lead|*-team-lead|team-lead-*) echo team-lead ;;
    cc|coordinator|*-cc|*-coordinator|*-coordinator-*|coordinator-*) echo team-lead ;;
    test|*-test|*-test-*|test-*)                                       echo test ;;
    review|pr|*-pr|*-pr-*|pr-*|*-review|*-review-*|review-*)           echo review ;;
    *)                                                                 echo feature ;;
  esac
}

# fleet_agent_id <name> — the agent's short fleet id: cc | f<N> | pr<N> | test<N>. Used for
# fleet attribution (e.g. the `agent:<id>` Linear labels the /todo skill applies; formerly the
# per-worktree segment of file-ledger TODO ids). Role from fleet_resolve_role; instance number
# = the trailing digits of the name, defaulting to 1 when the role has instances but the name
# carries none (pr → pr1). Coordinator is singular → no number (cc). Output is always
# [a-z0-9]+ (id-segment safe, no dashes).
#
# UNIQUENESS is convention-dependent (unlike the numeric lane, which was structurally unique per
# worktree): the id must be distinct across an engineer's CONCURRENT worktrees, since it's the
# per-(area,NS,agentid) sequence's collision guard. So **same-role agents MUST have distinct
# trailing numbers** (feature-1/feature-2, pr-1/pr-2) — two review agents both named without a
# number would both resolve to pr1. A fleet that can't guarantee this should set
# WORKFLOW_TODO_AGENT to the numeric lane (structurally unique) or leave it to fall back there.
fleet_agent_id() {
  local name="$1" role num
  role="$(fleet_resolve_role "$name")"
  num="$(printf '%s' "$name" | grep -oE '[0-9]+$' 2>/dev/null || true)"
  case "$role" in
    team-lead)   printf '0' ;;   # lane 0, singular — no instance number
    feature)     printf 'f%s'    "${num:-1}" ;;
    review)      printf 'pr%s'   "${num:-1}" ;;
    test)        printf 'test%s' "${num:-1}" ;;
    *)           printf 'f%s'    "${num:-1}" ;;  # unreachable (role is exhaustive) — id-safe default
  esac
}

# fleet_lanes_dir — echo the lane container directory. THE single resolver, so
# lanes.sh and fleet-layout.sh cannot disagree about where lanes live (the same
# duplication that produced three drifting copies of the role patterns).
#
# WORKFLOW_LANES_DIR (env, or workflow.config[.local]) wins. Otherwise it derives from
# the MAIN CLONE's basename + "-worktrees", via the shared git common dir — so it is
# worktree-invariant by construction. A linked worktree's own toplevel basename differs
# per worktree and would fork the default from every lane.
#
# Return status is a CONTRACT, matching fleet_manifest_path: resolvable → 0 + the path
# on stdout; unresolvable (not a repo, degenerate basename) → non-zero + NO output.
# Callers that mutate treat a failed resolution as a loud refusal.
fleet_lanes_dir() {
  if [ -n "${WORKFLOW_LANES_DIR:-}" ]; then
    printf '%s' "$WORKFLOW_LANES_DIR"; return 0
  fi
  local common parent base
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [ -n "$common" ] || return 1
  parent="$(dirname "$common")"
  base="$(basename "$parent")"
  case "$base" in ''|'/'|'.') return 1 ;; esac
  printf '%s/%s-worktrees' "$(dirname "$parent")" "$base"
}

# fleet_manifest_path — echo the machine-local worktrees-manifest path (DX-jn-cc-014).
# THE single resolver: fleet-layout's boot/down, statusline-role's lane fallback, and any
# consuming project's config all route through here rather than hardcoding a path (one
# identity, one pipeline).
#
# WORKFLOW_WORKTREES_MANIFEST (env, or workflow.config[.local]) wins. Otherwise the default
# derives from the MAIN CLONE's basename via the shared git common dir — worktree-invariant
# by construction, since a linked worktree's own toplevel basename differs per worktree and
# would fork the default (myproject → ~/.config/myproject-worktrees.json, from every worktree).
#
# Return status is a CONTRACT: resolvable → 0 + the path on stdout; unresolvable (not a repo,
# degenerate basename) → non-zero + NO output. Callers that mutate (boot/down) treat a failed
# resolution as the same loud refusal as a missing manifest; display-only callers (statusline)
# degrade silently. NOTE: in a bare repo the common dir has no worktree parent, so the
# derivation names the bare dir's parent — harmless here (no fleet runs from a bare repo).
fleet_manifest_path() {
  if [ -n "${WORKFLOW_WORKTREES_MANIFEST:-}" ]; then
    printf '%s' "$WORKFLOW_WORKTREES_MANIFEST"; return 0
  fi
  local common base
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [ -n "$common" ] || return 1
  base="$(basename "$(dirname "$common")")"
  case "$base" in ''|'/'|'.') return 1 ;; esac
  printf '%s' "$HOME/.config/${base}-worktrees.json"
}
