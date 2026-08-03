#!/bin/bash
# team-boot.sh — bring the team up on existing lanes.
#
# THIS IS THE RECOVERY PATH, and it exists because re-adoption is impossible.
# A relaunched lead CANNOT reclaim a surviving teammate: `--continue` forks a new
# session id (new, empty team), and `--resume <sid>` reuses the id, lands in the
# ORIGINAL team whose config still lists the teammate at its pane — and still
# reports "No agent named 'feature-N' is reachable". Membership is rebuilt
# in-process at lead startup. Verified both ways against a live teammate.
#
# So recovery is not reconstruction, it is respawn: kill whatever is squatting a
# lane, start the lead, and have the lead spawn teammates fresh. No work is lost,
# because the work lives in the lane on disk, not in the team.
#
#   boot [--with-team [N]] [--fresh] [--debug] [--session NAME]
#                           start the lead in lane 0 (tmux window of its own); --with-team then
#                           asks the LEAD to staff N lanes (default: all of them); --fresh starts
#                           a NEW conversation instead of resuming; --debug passes --debug to
#                           claude, so the harness prints why it skips things it was configured
#                           to do; --session picks (and CREATES if absent) the tmux session
#                           the fleet lives in, so two fleets can occupy two terminal windows
#                           instead of interleaving windows in one. Default: $WORKFLOW_FLEET_SESSION,
#                           else `main`.
#   spawn-prompt <lane>   print the exact prompt to hand the lead for one teammate
#   status       what is actually alive, verified against processes not config
#   down         stop every agent occupying a lane (idle-gated)
#
# We deliberately do NOT spawn teammates ourselves, and `--with-team` does not change
# that — it types a REQUEST into the lead's pane and lets the lead do the spawning.
# Teammates must be created BY the lead (that is what puts them in its in-process
# team); a teammate we launched by hand would run fine and be unaddressable — the
# exact failure this script exists to avoid. What --with-team removes is the manual
# copy-paste between `boot` and a staffed fleet, not the constraint.

set -u

# Lane dir via the ONE resolver (fleet_lanes_dir, _fleet.sh); literal is the no-_fleet.sh
# fallback. Same delegation pattern as lanes.sh — the duplication this avoids is exactly
# what produced three drifting copies of the role patterns.
if [ -r "$HOME/.claude/scripts/_fleet.sh" ]; then
  # shellcheck disable=SC1091
  . "$HOME/.claude/scripts/_fleet.sh"
fi
# The no-_fleet.sh fallback DERIVES the directory; it never names a project. This file lives
# in dotfiles and travels to any repo, so a hardcoded `goals-onchain-worktrees` meant every
# other product's fleet resolved to one particular product's lanes — silently, since the path
# exists on this machine. Same derivation as fleet_lanes_dir: the main clone's basename plus
# `-worktrees`, taken from the shared git common dir so it is worktree-invariant.
command -v fleet_not_a_lane >/dev/null 2>&1 ||
  fleet_not_a_lane() { case "${1:-}" in agent-*|.*|'') return 0 ;; *) return 1 ;; esac; }
_derive_lanes_dir() {
  local common parent base
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [ -n "$common" ] || return 1
  parent="$(dirname "$common")"; base="$(basename "$parent")"
  case "$base" in ''|'/'|'.') return 1 ;; esac
  printf '%s/%s-worktrees' "$(dirname "$parent")" "$base"
}
# _derive_lanes_dir is the NO-_fleet.sh path only. With _fleet.sh present, fleet_lanes_dir
# already honours WORKFLOW_LANES_DIR and runs the byte-identical `git rev-parse`, so a
# `|| _derive_lanes_dir` fallback there could never fire — an unfalsifiable branch reading as a
# safety net that is not one.
if command -v fleet_lanes_dir >/dev/null 2>&1; then
  LANES_DIR="$(fleet_lanes_dir 2>/dev/null || true)"
else
  LANES_DIR="${WORKFLOW_LANES_DIR:-$(_derive_lanes_dir 2>/dev/null || true)}"
fi

# LAST RESORT: a machine-local pointer, because `boot` is normally run from $HOME.
#
# Every resolution above needs a repo to stand in, and the one verb that matters most is
# invoked from outside one — which the old hardcoded project path quietly covered up. The
# pointer restores that convenience without putting any product's name in a file that ships to
# every machine: it is written the first time we DO resolve from inside a repo, and it lives in
# ~/.claude (machine-local runtime state, beside fleet-layout-mode), never in dotfiles.
#
# WRITTEN ONLY WHEN IT EXISTS, and never from library mode. The derivation answers for whatever
# repo you happen to be standing in — run any verb from an unrelated clone and it yields
# `<that repo>-worktrees`, which does not exist — so an unguarded write would record that as the
# fleet's lanes directory and every later invocation from outside a repo would read it back.
_LANES_PTR="$HOME/.claude/fleet-lanes-dir"
if [ -n "$LANES_DIR" ] && [ -d "$LANES_DIR" ] && [ -z "${TEAM_BOOT_LIB:-}" ]; then
  [ "$(cat "$_LANES_PTR" 2>/dev/null || true)" = "$LANES_DIR" ] ||
    printf '%s\n' "$LANES_DIR" > "$_LANES_PTR" 2>/dev/null || true
elif [ -z "$LANES_DIR" ] && [ -r "$_LANES_PTR" ]; then
  LANES_DIR="$(cat "$_LANES_PTR" 2>/dev/null || true)"
  [ -d "$LANES_DIR" ] || LANES_DIR=""
fi
SESSION="${WORKFLOW_FLEET_SESSION:-main}"
LEAD_LANE="team-lead"

die() { echo "team-boot: $*" >&2; exit 1; }

# An UNRESOLVED lanes dir is fatal, not empty. `"$LANES_DIR"/*/` with an empty value globs
# `/*/` — every top-level directory on the machine — which `status` would print as a fleet and
# `down` would walk. Library mode is exempt: the test suite supplies its own scratch dir, and a
# `die` at source time would take the harness with it.
[ -n "${TEAM_BOOT_LIB:-}" ] || [ -n "$LANES_DIR" ] ||
  die "cannot resolve the lanes directory — run this inside the repo, or set WORKFLOW_LANES_DIR"
# RESOLVED IS NOT ENOUGH — the directory has to be there. A resolved-but-absent path makes
# "$LANES_DIR"/*/ expand to the literal glob, so every verb enumerates nothing: `status` prints
# an empty fleet and `down` reports success having stopped nothing, while the fleet is up. An
# empty enumeration vacuously satisfies a destructive verb's success contract.
[ -n "${TEAM_BOOT_LIB:-}" ] || [ -d "$LANES_DIR" ] ||
  die "lanes directory does not exist: $LANES_DIR — wrong repo, or the lanes were never created"
lane_path() { printf '%s/%s' "$LANES_DIR" "$1"; }

# Who is alive in a lane — by PROCESS CWD, never by team config. The team config survives a
# kill -9 and keeps listing members no lead can address, so it is a hint, not a registry.
#
# Delegates to fleet_agent_in_dir (_fleet.sh), which is the single process-first primitive
# shared with lanes.sh. It lived here first, as a local `claude_pids` + cwd match written to
# replace a pgrep pair that missed every shim-launched agent — including the lead, so `down`
# reported "not running" for a live fleet. Moving it to _fleet.sh is what stops lanes.sh from
# carrying a second, subtly different answer to the same question.
#
# The literal fallback covers a clone with no _fleet.sh, guarded on the function existing —
# never `f || fallback`, which would run the fallback on every legitimate "nobody home".
alive_in() {
  local want; want="$(cd "$(lane_path "$1")" 2>/dev/null && pwd -P)" || return 1
  if command -v fleet_agent_in_dir >/dev/null 2>&1; then
    fleet_agent_in_dir "$want" ${CLAUDE_PIDS:-}
  else
    local pid cwd
    for pid in $(ps ax -o pid= -o command= 2>/dev/null | awk '/claude/{print $1}'); do
      [ "$pid" = "$$" ] && continue
      cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | grep '^n' | cut -c2-)"
      [ "$cwd" = "$want" ] && { printf '%s' "$pid"; return 0; }
    done
    return 1
  fi
}

# The LANE table belongs to lanes.sh — it owns lanes, and duplicating the enumeration here is
# how the two drifted into disagreeing: this one read the process table while `lanes.sh list`
# read the registry, so the same fleet could be "running" in one and "-" in the other. What
# this verb adds on top is the team-config caveat below, which is genuinely about TEAMS rather
# than lanes and has nowhere else to live.
# lanes.sh is PROJECT content and this script is not — it lives in dotfiles and travels to any
# repo, while lanes.sh encodes one product's hosts, ports and dev stack. So it can never be
# resolved as a sibling of $0; that assumption broke `status` the moment this file moved out of
# the repo, silently degrading it to the team-config caveat with no lane table at all.
#
# Resolution order, most specific first. Every candidate is a lane or a repo checkout, never a
# neighbour of this script.
resolve_lanes_sh() {
  local c
  for c in \
    "${WORKFLOW_LANES_SH:-}" \
    "${CLAUDE_PROJECT_DIR:-}/.claude/scripts/lanes.sh" \
    "$(/usr/bin/git rev-parse --show-toplevel 2>/dev/null)/.claude/scripts/lanes.sh" \
    "$LANES_DIR/$LEAD_LANE/.claude/scripts/lanes.sh"
  do
    case "$c" in ''|/.claude/*) continue ;; esac
    [ -r "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

cmd_status() {
  local lanes_sh; lanes_sh="$(resolve_lanes_sh || true)"
  if [ -n "$lanes_sh" ]; then
    bash "$lanes_sh" list
  else
    printf 'team-boot: no lanes.sh found (tried WORKFLOW_LANES_SH, CLAUDE_PROJECT_DIR, the\n'  >&2
    printf '           enclosing repo, and %s) — cannot show the lane table\n' "$LANES_DIR/$LEAD_LANE" >&2
  fi
  echo
  echo "team configs on disk (NOT proof of liveness — a crashed lead leaves these behind):"
  local c
  for c in "$HOME"/.claude/teams/*/config.json; do
    [ -f "$c" ] || continue
    /opt/homebrew/bin/python3 -c "
import json,sys
d=json.load(open('$c'))
names=[m['name'] for m in d['members']]
print('  %-22s %s' % (d['name'], ', '.join(names)))
" 2>/dev/null || echo "  $(dirname "$c")"
  done
}

# Ask the LEAD to spawn the team, once it is actually up.
#
# The lead does the spawning, always — that is what puts a teammate in its in-process team, and
# a teammate launched any other way runs fine and is permanently unaddressable. So this types a
# REQUEST into the lead's pane rather than launching anything itself. The constraint is
# preserved; only the manual copy-paste goes away.
#
# WAITS FOR THE LEAD FIRST. Keystrokes sent while claude is still starting land in the terminal
# before the TUI is reading, and are simply lost — the pane looks fine and no team appears. So
# poll for the process, then let the TUI settle.
_boot_request_team() {  # <lead-pane>
  local pane="$1" want="$WITH_TEAM_N" lanes=() d name
  for d in "$LANES_DIR"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    fleet_not_a_lane "$name" && continue
    [ "$name" = "$LEAD_LANE" ] && continue
    lanes+=("$name")
  done
  [ "${#lanes[@]}" -gt 0 ] || { echo "  no feature lanes to staff — create one with lanes.sh first" >&2; return 1; }

  # Default to every lane; cap at what exists rather than inventing lanes that do not.
  [ -n "$want" ] || want="${#lanes[@]}"
  case "$want" in ''|*[!0-9]*) die "--with-team takes a number (got '$want')" ;; esac
  [ "$want" -ge 1 ] || die "--with-team needs at least 1"
  if [ "$want" -gt "${#lanes[@]}" ]; then
    echo "  only ${#lanes[@]} feature lane(s) exist — staffing ${#lanes[@]} instead of $want" >&2
    want="${#lanes[@]}"
  fi

  printf '  waiting for the lead to come up'
  local i=0 up=""
  while [ "$i" -lt 60 ]; do
    if alive_in "$LEAD_LANE" >/dev/null 2>&1; then up=1; break; fi
    printf '.'; sleep 1; i=$((i + 1))
  done
  echo
  [ -n "$up" ] || { echo "  lead did not come up within 60s — not sending the spawn request" >&2; return 1; }
  sleep "${WORKFLOW_TEAM_SETTLE_SECONDS:-5}"      # let the TUI finish starting before typing

  local list="" n=0
  while [ "$n" -lt "$want" ]; do list="$list${list:+, }${lanes[$n]}"; n=$((n + 1)); done

  local req="Boot the team: spawn ${want} teammate(s) — ${list} — one per lane. For each, use the exact prompt from \`bash ~/.claude/scripts/team-boot.sh spawn-prompt <lane>\`, whose first instruction is EnterWorktree into that lane. Do not launch them any other way. Report each one's lane and branch once it confirms."
  tmux send-keys -t "$pane" -l "$req"
  tmux send-keys -t "$pane" Enter
  echo "  asked the lead to staff $want lane(s): $list"
}

# Does this lane have a conversation to come back to?
#
# Claude Code files transcripts under ~/.claude/projects/<cwd>/<session>.jsonl, with every
# non-alphanumeric character of the cwd mapped to '-' (so /Users/john/.claude/jobs becomes
# -Users-john--claude-jobs — the doubled dash is the dot). Presence of any .jsonl there is
# what makes `--continue` safe: with none, it exits immediately.
lane_has_transcript() {  # <lane-path>
  local d f
  d="$HOME/.claude/projects/$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')"
  for f in "$d"/*.jsonl; do [ -f "$f" ] && return 0; done
  return 1
}

cmd_boot() {
  WITH_TEAM=""; WITH_TEAM_N=""; FRESH=""; DEBUG=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --with-team) WITH_TEAM=1; case "${2:-}" in ""|-*) ;; *) WITH_TEAM_N="$2"; shift ;; esac ;;
      --fresh) FRESH=1 ;;
      --debug) DEBUG=1 ;;
      # Which tmux session the fleet lives in. One fleet per session means one terminal
      # window per fleet — a second `boot --session goals-b` gives a wholly separate set of
      # windows you can put on another monitor, instead of both fleets interleaving their
      # windows in `main`.
      --session) SESSION="${2:-}"; [ -n "$SESSION" ] || die "--session needs a name"; shift ;;
      *) die "unknown flag: $1" ;;
    esac; shift
  done
  local p; p="$(lane_path "$LEAD_LANE")"
  [ -d "$p" ] || die "no lead lane at $p — create it with lanes.sh first"
  local pid
  if pid="$(alive_in "$LEAD_LANE")"; then
    die "lead already running in $LEAD_LANE (pid $pid) — nothing to boot"
  fi
  command -v tmux >/dev/null 2>&1 || die "tmux required"
  # CREATE THE SESSION IF IT IS NOT THERE, rather than refusing.
  #
  # This used to `die "tmux session not found"`, which made `boot` unusable as the FIRST
  # thing you run: the only way to get a fleet was to already have a tmux session named
  # `main`, so a fresh terminal — or any session name that is not the default — was a hard
  # stop with a message that told you nothing about how to fix it.
  #
  # Detached (`new-session -d`), because boot may be running from inside tmux already; the
  # caller attaches (or switches) when it wants to look. Creating it is idempotent — the
  # has-session check short-circuits whenever the session is there, including the common
  # case of booting into the session you are sitting in.
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux new-session -d -s "$SESSION" 2>/dev/null ||
      die "could not create tmux session '$SESSION'"
    echo "created tmux session '$SESSION'"
  fi

  # WHERE THE LEAD LANDS — a pane id, never a window NAME.
  #
  # This used to create the window and then look its pane up again as "$SESSION:$LEAD_LANE".
  # That is a name target, and `/shutdown` leaves the outgoing lead's window alive at a shell
  # STILL NAMED team-lead — so by the next boot two windows carry the name and tmux resolves
  # the lowest index, the stale one. The claude command was typed into the OLD window, where
  # cwd is wherever that shell was ($HOME, not the lane), while the window just created sat
  # empty. A lead outside its own worktree is not cosmetic: lane-guard and every git op are
  # then pointed at the wrong tree.
  #
  # So: reuse the pane boot was invoked from when it is already in the fleet session — that is
  # the window the user is looking at, it is usually the stale team-lead window itself, and
  # reusing it is what stops a new one accreting on every boot. Otherwise create a window and
  # take the pane id STRAIGHT FROM new-window, which is exact and immune to duplicate names.
  local pane reuse=""
  if [ -z "$WITH_TEAM" ] && [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] &&
     [ "$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)" = "$SESSION" ]; then
    # --with-team is excluded deliberately: _boot_request_team polls IN THE FOREGROUND for the
    # lead to come up, and a lead launched into this very pane cannot start until this script
    # exits. Reusing the pane there would deadlock, so that flag keeps its own window.
    pane="$TMUX_PANE"; reuse=1
    tmux rename-window -t "$pane" "$LEAD_LANE"
  else
    # A window of its own, named for the lane. fleet-layout owns arrangement after this.
    pane="$(tmux new-window -t "$SESSION" -n "$LEAD_LANE" -c "$p" -P -F '#{pane_id}')" ||
      die "could not create the lead window in session '$SESSION'"
    [ -n "$pane" ] || die "tmux new-window returned no pane id"
  fi
  # PERMISSIONS: start in `auto`, with bypass AVAILABLE but not engaged.
  #
  #   --permission-mode auto                  how the session starts
  #   --allow-dangerously-skip-permissions    makes bypass reachable (you can switch into it)
  #
  # This was `--dangerously-skip-permissions`, which does not offer bypass — it IMPOSES it, for
  # the whole session. And per the agent-teams docs, "teammates start with the lead's permission
  # settings: if the lead runs with --dangerously-skip-permissions, all teammates do too", so one
  # flag on lane 0 silently put the ENTIRE fleet in bypass. `permissions.defaultMode: "auto"` in
  # settings.json could never take effect, because a CLI flag outranks it.
  #
  # The reuse path prefixes a `cd`: new-window gets the lane via -c, but a pane we adopt is
  # sitting wherever its shell was left, and the lead's cwd IS its lane identity — alive_in
  # and every other fleet lookup match agents by process cwd.
  local launch="claude --teammate-mode tmux --permission-mode auto --allow-dangerously-skip-permissions --name $LEAD_LANE"
  # CONTINUITY: a relaunched lead resumes ITS OWN conversation. Without this a shutdown/boot
  # cycle read as amnesia — the lead came back knowing nothing of the work it had just been
  # doing, which is the whole reason the cycle exists.
  #
  # `--continue` forking a new session id (header) is not an objection HERE. That fork costs
  # the team, and the team is rebuilt in-process at startup anyway: teammates are respawned,
  # never re-adopted. What it buys is the lead's context, which otherwise dies with the process.
  #
  # Guarded, because a first boot into a freshly-created lane has no transcript, and there
  # `claude --continue` exits on the spot — leaving an empty pane where the lead should be.
  #
  # --fresh is the deliberate opt-out: a context worth abandoning (wedged, poisoned, or simply
  # a new line of work) is a real state, and the alternative was deleting transcripts by hand.
  if [ -z "$FRESH" ] && lane_has_transcript "$p"; then launch="$launch --continue"; fi
  # --debug makes the harness print its own reasoning to the pane — the only way to see WHY it
  # declines to do something it was configured to do. Passed straight through rather than
  # interpreted here: what it turns on is the harness's business, not this script's.
  [ -n "$DEBUG" ] && launch="$launch --debug"
  [ -n "$reuse" ] && launch="cd $(printf '%q' "$p") && $launch"

  # WINDOW SHAPE BEFORE THE PROCESS. fleet-layout owns pane topology — this asks it to build the
  # lead's window (companion column, sizing, seed) rather than reproducing any of that here.
  #
  # BEFORE the launch keystrokes, deliberately: the split resizes the pane, and a TUI that
  # starts at its final size never has to reflow. It also means the companion exists from the
  # first frame instead of appearing whenever someone remembered to run a layout verb.
  #
  # Non-fatal in every direction. A machine with no fleet-layout.sh, or a split that fails, gets
  # a bare-pane lead — which is exactly what every boot produced before this line existed.
  #
  # Resolution mirrors resolve_lanes_sh: an explicit override wins, then the installed copy,
  # then a sibling of THIS FILE — never of $0, which is "bash" whenever this script is sourced.
  local layout_sh="${WORKFLOW_FLEET_LAYOUT_SH:-}"
  [ -n "$layout_sh" ] || layout_sh="$HOME/.claude/scripts/fleet-layout.sh"
  [ -x "$layout_sh" ] || layout_sh="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fleet-layout.sh"
  if [ -x "$layout_sh" ]; then
    # CLAUDE_PROJECT_DIR is passed because fleet-layout loads the PROJECT's workflow.config to
    # learn what the companion runs (WORKFLOW_CELL_COMMAND), and it resolves that from the repo
    # root of its own cwd. boot is typically run from somewhere else entirely, where the lookup
    # finds nothing and the companion silently comes up as a bare shell. The lane IS the project.
    CLAUDE_PROJECT_DIR="$p" "$layout_sh" lead-window --pane="$pane" --cwd="$p" ||
      echo "  (lead-window failed — continuing with a bare pane)"
  fi

  tmux send-keys -t "$pane" -l "$launch"
  tmux send-keys -t "$pane" Enter
  echo "lead booting in $pane ($SESSION:$LEAD_LANE${reuse:+, reused}), cwd $p"

  if [ -n "$WITH_TEAM" ]; then
    _boot_request_team "$pane"
    return
  fi

  echo
  echo "Next: attach and have the LEAD spawn each teammate — do not launch them yourself."
  local d name
  for d in "$LANES_DIR"/*/; do
    name="$(basename "$d")"
    fleet_not_a_lane "$name" && continue
    [ "$name" = "$LEAD_LANE" ] && continue
    echo "  team-boot.sh spawn-prompt $name"
  done
}

# The prompt is generated rather than improvised because the FIRST instruction has to
# be EnterWorktree. A teammate has no cwd parameter: it boots in the lead's worktree
# on the lead's branch and works there until it moves itself. lane-guard.sh blocks
# writes in the meantime, but a teammate that never enters is simply stuck — so the
# instruction leads, and it is unambiguous.
cmd_spawn_prompt() {
  local name="${1:-}"; [ -n "$name" ] || die "spawn-prompt needs a lane name"
  local p; p="$(lane_path "$name")"
  [ -d "$p" ] || die "no lane at $p"
  cat <<EOF
--- hand this to the lead, verbatim, as the spawn prompt for '$name' ---
You are teammate \`$name\`, working lane $name.

FIRST, before anything else: call EnterWorktree with
  path: "$p"
Do NOT pass a name — that worktree already exists, on branch $name. Until you have
entered it you are standing in the lead's tree and every write will be refused by
the lane-guard hook.

Confirm with a single command: pwd && git rev-parse --abbrev-ref HEAD
Expect: $p and branch $name.

THEN RESUME — you are re-occupying a lane, not starting one. A teammate is spawned fresh
every time (no \`--continue\` exists for you: the lead creates you through the Agent tool,
and a CLI relaunch would put you outside its team and make you unaddressable). Your
continuity is on disk instead. Read it, in this order:

  cat .claude/current-work        # <ID>\\t<url> per Linear issue left In Progress — may be empty
  git log --oneline -5            # what you last landed on this branch
  git status --short              # what you left uncommitted

If current-work names an issue, pick it up through the /todo skill — it is already In
Progress, and its plan is the issue's \`## Plan\` comment, so resume that plan rather than
drafting a new one. If it is empty, you were idle; say so.

If you ever stop and wait on a person, say so where it is visible: write one line naming the
decision to \`.claude/needs-input\` (gitignored) at the same moment you ask, and \`rm\` it once
you have the answer. The agent panel puts a ❓ on your row when that file exists — the harness
itself has no waiting-for-input state, so this is the only signal there is.

Report with SendMessage to \`team-lead\`: your lane, your branch, and either the issue you
are resuming or "no work in flight" — then stand by. **Your plain output is not visible to
the lead** — a report you merely print is a report nobody receives, which is exactly how
two teammates came up looking like they had ignored this instruction.
--- end ---
EOF
}

# Is this agent mid-turn? FAIL-CLOSED: anything we cannot determine reads as BUSY, because
# the caller is about to kill a process. Ported from fleet-layout.sh's `_down_busy` when
# `down` moved here — the plain `[ -f ]` check this replaces failed OPEN on an unreadable
# marker dir, i.e. it read a working agent as idle in exactly the case it knew least.
#
# Marker presence is deliberately NOT age-windowed here (fleet_busy's staleness window is
# for restart/compact, whose purpose is recovering a wedged agent). An agent parked on a
# permission prompt or a plan approval is mid-turn with a marker nobody re-touches, and
# killing it would discard a human's pending decision.
down_busy() {
  local dir="$HOME/.claude/agent-busy" m="$HOME/.claude/agent-busy/$1"
  [ -e "$dir" ] || return 1                         # nobody was ever marked → idle
  { [ -r "$dir" ] && [ -x "$dir" ]; } || return 0   # dir unreadable → UNKNOWN → busy
  [ -e "$m" ]
}

# The "stopped" claim is EARNED by observation, not by kill's exit status. `kill` returning 0
# means the signal was delivered, not that the process exited — and a claude mid-tool-call can
# take seconds to unwind. Anything we cannot prove dead is reported as still running.
#
# DOWN_VERIFY_TRIES is a test seam, not a knob: the default 20 tries x 0.5s is the real
# grace period, and only the test suite lowers it so the "refuses to claim a survivor is
# dead" case does not cost 10s per assertion.
down_verify_dead() {  # <pid>
  local i=0 tries="${DOWN_VERIFY_TRIES:-20}"
  while [ "$i" -lt "$tries" ]; do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.5; i=$((i + 1))
  done
  kill -0 "$1" 2>/dev/null && return 1
  return 0
}

cmd_down() {
  local force="" dry=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --force)   force=1 ;;
      --dry-run) dry=1 ;;
      *) die "unknown flag: $1" ;;
    esac; shift
  done

  # SELF IS NEVER A TARGET. The lead occupies lane 0, so an unguarded sweep over
  # "$LANES_DIR"/*/ kills the process running this script — `down` would take itself out
  # partway through and leave the rest of the fleet up. fleet-layout's down had this
  # backstop; the version that moved here did not.
  local self_pid=""
  self_pid="$(alive_in "$LEAD_LANE" 2>/dev/null || true)"

  local d name pid rc=0
  for d in "$LANES_DIR"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    fleet_not_a_lane "$name" && continue
    pid="$(alive_in "$name")" || { echo "  $name: not running"; continue; }

    if [ -n "$self_pid" ] && [ "$pid" = "$self_pid" ]; then
      echo "  $name: SKIPPED (that is me — pid $pid)"; continue
    fi
    if [ -z "$force" ] && down_busy "$name"; then
      echo "  $name: BUSY (pid $pid) — skipped; --force to stop anyway"; continue
    fi
    if [ -n "$dry" ]; then
      echo "  $name: would stop (pid $pid)"; continue
    fi

    kill "$pid" 2>/dev/null || { echo "  $name: FAILED — could not signal pid $pid"; rc=1; continue; }
    if down_verify_dead "$pid"; then
      echo "  $name: stopped (pid $pid)"
    else
      echo "  $name: FAILED — pid $pid still alive after SIGTERM; NOT claiming it is down"; rc=1
    fi
  done
  return "$rc"
}

# Sourcing this file as a library (TEAM_BOOT_LIB=1) defines the functions without running a
# verb, so the test suite can drive cmd_down and its guards directly. Without it, `. team-boot.sh`
# would execute `status` — and a test that has to shell out for every case cannot stub alive_in,
# which is exactly the seam the down guards need to be testable at all. Same pattern as lanes.sh.
[ "${TEAM_BOOT_LIB:-}" = 1 ] && return 0

case "${1:-status}" in
  status)       shift || true; cmd_status ;;
  boot)         shift || true; cmd_boot "$@" ;;
  spawn-prompt) shift; cmd_spawn_prompt "$@" ;;
  down)         shift; cmd_down "$@" ;;
  *) cat >&2 <<EOF
usage: team-boot.sh <verb>
  status                 what is alive, verified by process cwd (not team config)
  boot [--session NAME]  start the lead; the tmux session is created if it does not exist
  boot [--with-team [N]] start the lead in lane 0. --with-team then ASKS THE LEAD to spawn
                         teammates (N lanes, default all) — the lead must do the spawning or
                         they are unaddressable
  spawn-prompt <lane>    the exact prompt to hand the lead for one teammate
  down [--force] [--dry-run]
                         stop agents occupying lanes. Skips BUSY (fail-closed: anything
                         indeterminate counts as busy) and never targets itself. The
                         "stopped" claim is verified by observation, not by kill's exit.
EOF
    exit 2 ;;
esac
