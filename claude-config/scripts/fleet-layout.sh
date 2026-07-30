#!/bin/bash
# fleet-layout.sh — the single owner of the fleet's tmux window names and pane topology.
#
#   fleet-layout.sh single       [--dry-run]   # laptop: one window per feature agent, in `main`
#   fleet-layout.sh dual         [--dry-run]   # ordinary 2nd monitor: 2 agents per window, x2
#   fleet-layout.sh wide         [--dry-run]   # double-wide: all 4 agents in one 2x2 window
#   fleet-layout.sh attach       [--dry-run]   # open an iTerm window on the 2nd monitor and
#                                              #   move the feature windows into their own session
#   fleet-layout.sh balance      [--dry-run]   # re-split each cell 60/40 after a resize
#   fleet-layout.sh name-windows [--dry-run]   # label every window from its resident agents
#   fleet-layout.sh subagents    [--dry-run]   # restack a lead's subagent panes below its own
#
# THIS SCRIPT NEVER STARTS OR STOPS AN AGENT. It only moves and labels panes, which is what
# makes every verb safe to re-run. `boot` and `down` used to live here and do exactly that;
# they enumerated the fleet from a worktrees manifest the lanes migration stopped maintaining,
# so both had been failing with "manifest missing or unreadable" on every call. They now live
# in `.claude/scripts/team-boot.sh`, which enumerates the lane directory — a lane is on disk by
# definition, so there is no manifest to go stale.
#
# `wide` and `dual` are the external-monitor modes: their windows live in a DEDICATED tmux
# session so they are not tabs in the laptop's window. `single` brings them home.
#
# An agent's identity is its tmux PANE ID, and `join-pane` MOVES a pane rather than
# recreating it, so pane ids survive every restructure here — mail delivery and liveness
# (which target %N) keep working with no agent restart. That is the whole reason this
# script can exist.
#
# NEVER let this script spawn a second tmux server: pane ids restart at %0 and collide,
# `list-panes -a` goes blind across servers, the fleet tooling prunes live agents from the
# registry, and send-keys types into unrelated panes. FLEET_TMUX_SOCKET exists ONLY for
# fleet-layout.test.sh's scratch server.
#
# `name-windows` is called by register-agent.sh so window labels stay
# automatic. It derives each name from ALL of a window's resident agents, so it converges
# to the same answer no matter which agent invokes it — that is what makes co-tenant
# agents unable to clobber each other's window label.

set -uo pipefail

# Route every tmux call (including the ones inside _fleet.sh) through the scratch socket
# when the test harness sets one. Defining the function *before* sourcing _fleet.sh is what
# makes its internal `tmux list-panes -a` liveness probe hit the right server.
tmux() {
  if [ -n "${FLEET_TMUX_SOCKET:-}" ]; then command tmux -L "$FLEET_TMUX_SOCKET" "$@"
  else command tmux "$@"; fi
}

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_fleet.sh
. "$_here/_fleet.sh"
# Load the project's workflow.config[.local] so the knobs below (manifest path, cell command,
# home session) work from config with zero ceremony in ANY project — not only when exported.
# Guarded: absence is not an error. _config.sh is env-wins (it snapshots exported WORKFLOW_*
# values and re-applies them after sourcing), so a per-invocation env override still wins.
# _config.sh is PROJECT content and lives in the CONSUMING REPO (.claude/scripts/_config.sh) —
# never beside this file. Once this script moved to ~/.claude/scripts (dotfiles-owned), the old
# script-relative lookup resolved to ~/.claude/scripts/_config.sh, which does not exist, so the
# load silently did nothing and every project knob fell back to its default.
#
# Measured consequence: WORKFLOW_CELL_COMMAND — set to "monocle" in this repo's workflow.config —
# read as EMPTY, so the companion pane was never seeded, for the lead's window and for every
# feature agent's cell alike. `[ -r ... ] &&` made the failure silent by construction.
#
# Same resolution register-agent.sh already uses: CLAUDE_PROJECT_DIR, else the repo root, and
# only then the script-relative path as a last resort for a clone that keeps them together.
_cfg_root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD")}"
for _cfg in "$_cfg_root/.claude/scripts/_config.sh" "$_here/_config.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_cfg" ] && { . "$_cfg"; break; }
done

DRY_RUN=0
TAB="$(printf '\t')"

# The fleet's home session (laptop), and the dedicated session that BOTH external-monitor
# layouts (`wide` and `dual`) move their feature windows into.
#
# A DEDICATED session, not a grouped one: grouped sessions share the window list by
# construction, so the feature windows would remain tabs in the laptop's window. move-window
# relocates a window between sessions on one server without changing pane ids, so the registry,
# send-keys delivery, and list-panes liveness are all untouched. (DX-jn-cc-002)
FL_HOME_SESSION="${WORKFLOW_FLEET_HOME_SESSION:-main}"
# The command the cell's top-right companion pane runs (DX-jn-cc-014). EMPTY BY DEFAULT: typing
# a command into a consuming project's pane is an ACTION, and send-keys succeeds at the tmux
# layer even when the receiving shell errors — so a default keystroke for a tool the machine
# lacks would print `command not found` in every agent's pane AND be invisible to boot's report.
# A project that wants one sets WORKFLOW_CELL_COMMAND in its workflow.config (e.g. "monocle").
FL_CELL_COMMAND="${WORKFLOW_CELL_COMMAND:-}"
FL_EXT_SESSION="${WORKFLOW_FLEET_EXT_SESSION:-${WORKFLOW_FLEET_WIDE_SESSION:-wide}}"
FL_PLACEHOLDER='__fl_placeholder'

# Mutating tmux verb. Under --dry-run it is printed, never executed.
_rw() {
  if [ "$DRY_RUN" = "1" ]; then printf 'tmux %s\n' "$*"; else tmux "$@"; fi
}

# Physical path, or empty when the directory is gone (a dead worktree's stale sidecar).
# .cwd is written from $PWD (logical) while tmux reports the resolved path, so both sides
# are normalized before they are ever compared.
_abs() { (cd "$1" 2>/dev/null && pwd -P); }

# Honors the ~/.claude/agents/<name>.role override exactly like agent-identity.sh and
# statusline-role.sh do, then falls back to the canonical name classifier.
_role_of() {
  local f="$HOME/.claude/agents/$1.role" r=""
  [ -f "$f" ] && r="$(tr -dc 'A-Za-z0-9_-' < "$f")"
  [ -n "$r" ] && { printf '%s' "$r"; return; }
  fleet_resolve_role "$1"
}

_plural() {
  case "$1" in
    feature) printf 'features' ;; review) printf 'reviews' ;;
    test)    printf 'tests'    ;; coordinator) printf 'coordinators' ;;
    *)       printf '%ss' "$1" ;;
  esac
}

# ---------------------------------------------------------------------------- inventory

# name \t token \t abs-cwd \t role   — one line per LIVE agent.
# Scoped to the registry: .cwd sidecars outlive their agents, so globbing *.cwd would let
# a dead agent claim live panes.
live_agents() {
  local f base name pid token cwd acwd _la_claude_pids
  for f in "$HOME"/.claude/running-agents/*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"; pid="${base##*.}"; name="${base%.*}"
    token="$(cat "$f" 2>/dev/null)"
    [ -n "$token" ] || continue
    fleet_alive "$pid" "$token" || continue
    # LIVE process cwd first; the recorded sidecar only as a fallback.
    #
    # The sidecar is written once, at SessionStart — and a teammate boots in the LEAD's
    # worktree and only moves itself afterwards with EnterWorktree. So the sidecar says
    # `team-lead` for every teammate, forever. Measured on a real 4-agent fleet: all four
    # sidecars read `team-lead` while all four processes were correctly in their own lanes.
    #
    # Attribution then saw five agents sharing one cwd, hit its ambiguity rule ("matches two
    # live agents with the same cwd — leaving it alone"), and refused to move anything. Every
    # layout verb was a silent no-op for teammates: it reported success and rearranged nothing.
    #
    # The process's cwd is ground truth and it FOLLOWS the agent, which the sidecar cannot.
    #
    # ONLY for a pid that is actually a claude process. A registry entry can name a pid that
    # has died and been RECYCLED by something unrelated, and that stranger's cwd would then be
    # read as the agent's — attributing panes by where some other program happens to be
    # working. Checking membership costs one process-table sweep for the whole loop.
    cwd=""
    if command -v fleet_pid_cwd >/dev/null 2>&1; then
      [ -n "${_la_claude_pids+x}" ] || _la_claude_pids=" $(fleet_claude_pids | tr '\n' ' ')"
      case "$_la_claude_pids" in *" $pid "*) cwd="$(fleet_pid_cwd "$pid")" ;; esac
    fi
    [ -n "$cwd" ] || cwd="$(cat "$HOME/.claude/agents/$name.cwd" 2>/dev/null)"
    [ -n "$cwd" ] || continue
    acwd="$(_abs "$cwd")"
    [ -n "$acwd" ] || continue
    printf '%s\t%s\t%s\t%s\n' "$name" "$token" "$acwd" "$(_role_of "$name")"
  done
}

# pane_id \t session \t window_id \t abs-path
_pane_rows() {
  tmux list-panes -a -F "#{pane_id}${TAB}#{session_name}${TAB}#{window_id}${TAB}#{pane_current_path}" 2>/dev/null \
  | while IFS="$TAB" read -r pid sess win path; do
      printf '%s\t%s\t%s\t%s\n' "$pid" "$sess" "$win" "$(_abs "$path")"
    done
}

# The ONE tri-state skip-marker primitive: marked | unmarked | unknown. The full-list
# form is the only one whose EXIT STATUS distinguishes "unset" from "query failed" —
# with -v, tmux exits 1 for BOTH an unset user option and a missing pane (verified on
# tmux 3.7b, 2026-07-10). POLICY lives at the call sites: attribution (_is_skipped)
# maps unknown→unmarked (worst case a recoverable pane move); down's kill gate maps
# unknown→refuse (a user protection silently defeated by a flaked query is the
# _teardown_ext fail-open class verbatim).
_skip_state() {
  local out
  if ! out="$(tmux show-options -p -t "$1" 2>/dev/null)"; then printf 'unknown'; return; fi
  if printf '%s\n' "$out" | grep -q '^@fleet-layout-skip[[:space:]]'; then printf 'marked'
  else printf 'unmarked'; fi
}
_is_skipped() { [ "$(_skip_state "$1")" = marked ]; }

# Widths come from list-panes, never `display-message -t <pane>`: list-panes is unambiguous
# about which pane it is reporting on.
_pane_width() { tmux list-panes -a -F "#{pane_id} #{pane_width}" 2>/dev/null | awk -v p="$1" '$1==p{print $2; exit}'; }
_win_of()     { tmux list-panes -a -F "#{pane_id} #{window_id}"  2>/dev/null | awk -v p="$1" '$1==p{print $2; exit}'; }
_sess_of_win(){ tmux list-windows -a -F "#{window_id} #{session_name}" 2>/dev/null | awk -v w="$1" '$1==w{print $2; exit}'; }

# name \t claude-pane \t "comp1 comp2 …"
#
# claude pane  = the registry token, verbatim — authoritative, never inferred.
# companion    = a live pane that (1) sits at the agent's cwd or a SUBDIRECTORY of it,
#                (2) is not any live agent's token, (3) shares the claude pane's session,
#                (4) carries no @fleet-layout-skip marker.
#
# (1) is a boundary-aware prefix, never a bare string prefix: the worktrees are siblings, so
# `…/myproject` is a literal prefix of `…/myproject-2`. Longest cwd wins; an exact
# tie means two live agents share a cwd, and the pane is given to NEITHER — joining it twice
# would leave a half-built cell.
attribute_panes() {
  local agents panes name token acwd sess claude_sess
  agents="$(live_agents)"
  panes="$(_pane_rows)"
  [ -n "$agents" ] || return 0

  while IFS="$TAB" read -r name token acwd _role; do
    [ -n "$name" ] || continue
    claude_sess="$(printf '%s\n' "$panes" | awk -F"$TAB" -v p="$token" '$1==p{print $2; exit}')"
    local comps=""
    while IFS="$TAB" read -r pid psess _pwin ppath; do
      [ -n "$pid" ] || continue
      [ "$psess" = "$claude_sess" ] || continue
      printf '%s\n' "$agents" | cut -f2 | grep -qx "$pid" && continue   # another agent's claude pane
      [ -n "$ppath" ] || continue

      # longest boundary-aware match across all live agents
      local best_name="" best_len=0 ambiguous=0 a_name a_cwd len
      while IFS="$TAB" read -r a_name _a_tok a_cwd _a_role; do
        case "$ppath" in
          "$a_cwd"|"$a_cwd"/*) ;;
          *) continue ;;
        esac
        len="${#a_cwd}"
        if [ "$len" -gt "$best_len" ]; then best_len="$len"; best_name="$a_name"; ambiguous=0
        elif [ "$len" -eq "$best_len" ] && [ "$a_name" != "$best_name" ]; then ambiguous=1
        fi
      done <<EOF
$agents
EOF
      [ "$ambiguous" = "1" ] && {
        printf 'fleet-layout: WARNING: pane %s at %s matches two live agents with the same cwd — leaving it alone\n' \
          "$pid" "$ppath" >&2; continue; }
      [ "$best_name" = "$name" ] || continue
      _is_skipped "$pid" && continue
      comps="${comps:+$comps }$pid"
    done <<EOF
$panes
EOF
    printf '%s\t%s\t%s\n' "$name" "$token" "$comps"
  done <<EOF
$agents
EOF
}

# ---------------------------------------------------------------------------- naming

# The window label for a set of resident agent names. Pure — this is the whole naming rule.
window_name_from_names() {
  [ "$#" -eq 0 ] && { printf ''; return; }
  [ "$#" -eq 1 ] && { printf '%s' "$1"; return; }
  local n roles count
  roles="$(for n in "$@"; do _role_of "$n"; done | sort -u)"
  count="$(printf '%s\n' "$roles" | grep -c .)"
  if [ "$count" -eq 1 ]; then _plural "$roles"
  else printf '%s' "$roles" | tr '\n' '-' | sed 's/-$//'
  fi
}

# The lowest agent-number in a window, used only to order same-named windows deterministically.
_min_agent_num() {
  local n lowest=9999 num
  for n in "$@"; do
    num="$(printf '%s' "$(fleet_agent_id "$n")" | grep -oE '[0-9]+$' || echo 0)"
    [ -n "$num" ] || num=0
    [ "$num" -lt "$lowest" ] && lowest="$num"
  done
  printf '%s' "$lowest"
}

# Label every window that hosts at least one live agent. Windows with none are left alone.
#
# When two windows derive the SAME name — `dual` puts two feature agents in each of two windows,
# so both derive `features` — they are suffixed `-1`, `-2` by ascending lowest-agent-number. No
# window-option marker: a marker would survive `single` breaking the window apart and mislabel
# the remnant. Derivation stays a pure function of who lives there.
name_windows() {
  local agents panes wins win names cur target rows base rank dups
  agents="$(live_agents)"; panes="$(_pane_rows)"
  [ -n "$agents" ] || return 0
  wins="$(printf '%s\n' "$panes" | cut -f3 | sort -u)"

  rows=""
  for win in $wins; do
    names=""
    while IFS="$TAB" read -r name token _acwd _role; do
      [ -n "$name" ] || continue
      printf '%s\n' "$panes" | awk -F"$TAB" -v p="$token" -v w="$win" '$1==p && $3==w{found=1} END{exit !found}' \
        && names="${names:+$names }$name"
    done <<EOF
$agents
EOF
    [ -n "$names" ] || continue
    # shellcheck disable=SC2086
    base="$(window_name_from_names $names)"
    [ -n "$base" ] || continue
    # shellcheck disable=SC2086
    rows="${rows}${win}${TAB}$(_min_agent_num $names)${TAB}${base}
"
  done
  [ -n "$rows" ] || return 0

  while IFS="$TAB" read -r win _num base; do
    [ -n "$win" ] || continue
    dups="$(printf '%s' "$rows" | awk -F"$TAB" -v b="$base" '$3==b' | grep -c .)"
    if [ "$dups" -gt 1 ]; then
      # Keyed sort: primary = lowest agent number, tiebreak = window id. `sort -n` alone would
      # rely on the implicit last-resort full-line compare; being explicit keeps the suffixes
      # from flapping if that ever changes.
      rank="$(printf '%s' "$rows" | awk -F"$TAB" -v b="$base" '$3==b{print $2"\t"$1}' \
              | sort -k1,1n -k2,2 | grep -n "	${win}\$" | cut -d: -f1)"
      target="${base}-${rank}"
    else
      target="$base"
    fi
    cur="$(tmux display-message -p -t "$win" '#{window_name}' 2>/dev/null)"
    [ "$cur" = "$target" ] && continue          # idempotent: already correct
    _rw set-window-option -t "$win" automatic-rename off
    _rw rename-window -t "$win" "$target"
  done <<EOF
$rows
EOF

  # Then put them in the canonical order: cc, features, review/test, everything else — UNLESS
  # label-only was requested. The settle-recheck (register-agent.sh, DX-jn-cc-018) re-invokes
  # this a few seconds post-restart to converge LABELS after a transient auto-name; reordering
  # from that possibly-half-settled registry is exactly what demotes cc to last, so it passes
  # --label-only and leaves ordering to the boot-time / layout-verb name-windows.
  if [ "${FL_LABEL_ONLY:-0}" != 1 ]; then
    _order_windows "$FL_HOME_SESSION"
    _order_windows "$FL_EXT_SESSION"
  fi
}

# Sort key for a window, given the live agents resident in it. Lower sorts first:
#   0            the coordinator (cc)
#   100+f<n>     feature agents, by lowest agent number  (f1, f2, … and the merged features*)
#   200          review / test
#   300+index    no live agents — unrelated windows, keeping their relative order at the end
_window_rank() {   # <current-index> <agent-name…>
  local idx="$1"; shift
  [ "$#" -eq 0 ] && { printf '%s' $(( 300 + idx )); return; }
  local n role has_feature=0
  for n in "$@"; do
    role="$(_role_of "$n")"
    # `team-lead` is canonical. `coordinator` is still accepted because _role_of returns a
    # per-agent ~/.claude/agents/<name>.role override VERBATIM, and overrides written before
    # the rename still say it — matching only the new spelling silently demoted lane 0 from
    # rank 0 to rank 200, i.e. its window stopped sorting first.
    { [ "$role" = "team-lead" ] || [ "$role" = "coordinator" ]; } && { printf '0'; return; }
    [ "$role" = "feature" ] && has_feature=1
  done
  if [ "$has_feature" = "1" ]; then printf '%s' $(( 100 + $(_min_agent_num "$@") ))
  else printf '200'
  fi
}

# Reorder a session's windows into: cc, feature agents (f1..fN), review/test, everything else.
# Idempotent — computes the desired order and does nothing when it already matches, so it is
# safe to call from name_windows on every SessionStart. (DX-jn-cc-003)
_order_windows() {
  local sess="$1" agents panes win names idx rows desired current park
  _session_exists "$sess" || return 0
  agents="$(live_agents)"; panes="$(_pane_rows)"

  rows=""; idx=0
  for win in $(tmux list-windows -t "$sess" -F '#{window_id}' 2>/dev/null); do
    names=""
    while IFS="$TAB" read -r name token _acwd _role; do
      [ -n "$name" ] || continue
      printf '%s\n' "$panes" | awk -F"$TAB" -v p="$token" -v w="$win" '$1==p && $3==w{found=1} END{exit !found}' \
        && names="${names:+$names }$name"
    done <<EOF
$agents
EOF
    # shellcheck disable=SC2086
    rows="${rows}$(printf '%06d' "$(_window_rank "$idx" $names)")${TAB}${idx}${TAB}${win}
"
    idx=$(( idx + 1 ))
  done
  [ -n "$rows" ] || return 0

  # Never reorder the HOME session from a snapshot that has a live coordinator but placed it in
  # NO window. A transient registration gap (cc mid-`claude --continue`, or a pane whose
  # $TMUX_PANE was momentarily unset → the registry token is a cwd-fallback, not a real pane id)
  # leaves cc's window with zero resident agents, which _window_rank ranks 300+ and sorts LAST.
  # Hold the current order until the registry settles rather than demote the coordinator. Scoped
  # to the home session: cc never lives in the external (feature-grid) session, where a missing
  # coordinator is EXPECTED and must not block the feature windows from ordering. (Fixes the
  # settle-recheck reorder introduced with DX-jn-cc-018 — see register-agent.sh.)
  if [ "$sess" = "$FL_HOME_SESSION" ] \
     && printf '%s\n' "$agents" | awk -F"$TAB" '$4=="coordinator"{f=1} END{exit !f}' \
     && ! printf '%s\n' "$rows" | awk -F"$TAB" '$1=="000000"{f=1} END{exit !f}'; then
    return 0
  fi

  desired="$(printf '%s' "$rows" | sort -t"$TAB" -k1,1 -k2,2n | cut -f3 | tr '\n' ' ')"
  current="$(tmux list-windows -t "$sess" -F '#{window_id}' 2>/dev/null | tr '\n' ' ')"
  [ "$desired" = "$current" ] && return 0          # already in order — emit nothing

  # Park high, then renumber: move-window into an occupied index fails, so we stage the whole
  # session above any real index first and let `move-window -r` collapse it back to 1..N.
  # A failed park would strand windows at 900+ and every later run would re-fail (900 now
  # occupied) — on every SessionStart, forever. Collapse the indices back whatever happens.
  park=900
  for win in $desired; do
    _rw move-window -d -s "$win" -t "${sess}:${park}" || { _renumber "$sess"; return 1; }
    park=$(( park + 1 ))
  done
  _renumber "$sess"
}

# ---------------------------------------------------------------------------- layouts

_feature_agents() {   # names of live feature agents, ordered f1, f2, … by fleet_agent_id
  local name _tok _cwd role
  while IFS="$TAB" read -r name _tok _cwd role; do
    [ "$role" = "feature" ] && printf '%s\t%s\n' "$(fleet_agent_id "$name")" "$name"
  done <<EOF
$(live_agents)
EOF
}

# Attribution is snapshotted ONCE before any pane moves, and the whole build is driven from
# that snapshot. Re-deriving mid-build would be wrong, not just slow: once an agent's claude
# pane joins the seed's session, its companions are still in their ORIGINAL session and would
# fail the same-session check, silently dropping the cell's right column.
FL_ATTR=""
_snapshot_attr() { FL_ATTR="$(attribute_panes)"; }
_attr()      { if [ -n "$FL_ATTR" ]; then printf '%s\n' "$FL_ATTR"; else attribute_panes; fi; }
_claude_of() { _attr | awk -F"$TAB" -v n="$1" '$1==n{print $2}'; }
_comps_of()  { _attr | awk -F"$TAB" -v n="$1" '$1==n{print $3}'; }

_join_failed() {
  printf 'fleet-layout: join-pane %s -> %s FAILED — aborting before any further move.\n' "$1" "$2" >&2
  printf '             Panes already moved are left in place; no pane was killed. Re-run the\n' >&2
  printf '             same layout to converge, or run `single` to break the agents back out.\n' >&2
}

# claude pane on the left; companions stacked in a column to its right.
# Aborts on the FIRST failed join rather than sailing on and leaving a half-built cell.
build_cell() {
  local claude="$1"; shift
  [ "$#" -eq 0 ] && return 0
  local first="$1"; shift
  _rw join-pane -h -s "$first" -t "$claude" || { _join_failed "$first" "$claude"; return 1; }
  local prev="$first" comp
  for comp in "$@"; do
    _rw join-pane -v -s "$comp" -t "$prev" || { _join_failed "$comp" "$prev"; return 1; }
    prev="$comp"
  done
  _balance_cell "$claude" "$first" || true          # cosmetic; never fail the build on it
}

# Give the claude pane ~60% of ITS CELL.
#
# `resize-pane -x N%` is a percentage of the WINDOW, not of the cell. In an N-cell grid the
# cell is a fraction of the window, so the request always overshoots: on a 200-col window with
# two 100-col cells, `-x 60%` asks for 120 cols, clamps the companion column to 1, AND steals
# 22 cols from the neighbouring cell. Resize in absolute columns instead. (DX-jn-cc-002)
_balance_cell() {
  local claude="$1" comp="$2" cw fw cell target
  [ "$DRY_RUN" = "1" ] && { printf 'tmux resize-pane -t %s -x <60%%%% of cell, in columns>\n' "$claude"; return 0; }
  cw="$(_pane_width "$claude")"; fw="$(_pane_width "$comp")"
  case "${cw}:${fw}" in ''|*[!0-9:]*|:*|*:) return 0 ;; esac
  cell=$(( cw + fw + 1 ))                                   # +1 for the border between them
  target=$(( cell * 60 / 100 ))
  # Leave the split alone when either side would be unusably narrow.
  [ "$target" -ge 20 ] && [ $(( cell - target - 1 )) -ge 15 ] || return 0
  tmux resize-pane -t "$claude" -x "$target" 2>/dev/null || true
}

# Re-balance the cells this script builds. Run after a client attaches (the window resizes to
# it) or after the terminal changes size — the joins are already correct, only the ratio drifts.
#
# FEATURE agents only. The coordinator's and the review/test agents' windows are hand-arranged
# and were never assembled into a cell; resizing them would clobber the user's own layout.
balance_cells() {
  local name claude comps first
  [ -n "$FL_ATTR" ] || _snapshot_attr
  while IFS="$TAB" read -r name claude comps; do
    [ -n "$name" ] && [ -n "$comps" ] || continue
    [ "$(_role_of "$name")" = "feature" ] || continue
    first="${comps%% *}"
    _balance_cell "$claude" "$first"
  done <<EOF
$(_attr)
EOF
}

# Put the seed pane in a window named $win_name. Skipped when it is already there, which is
# what lets a re-run after a failed build converge instead of spawning a second window.
_seed_window() {
  local win_name="$1" seed="$2" cur
  cur="$(tmux display-message -p -t "$seed" '#{window_name}' 2>/dev/null)"
  [ "$cur" = "$win_name" ] && return 0
  _rw break-pane -d -s "$seed" -n "$win_name"
}

# HEURISTIC, not a guarantee. tmux refuses a split below its minimum pane size. The target
# window may not exist yet, and with the wide layout it ends up in another session on another
# monitor — so prefer the size of a client attached to the DEDICATED session when there is one,
# and fall back to the invoking window. When neither is knowable, skip rather than abort on a
# number that means nothing. The real safety net is abort-on-first-failed-join. (DX-jn-cc-002)
_precheck_room() {
  local cells="$1" w h need_w need_h dims
  [ "$DRY_RUN" = "1" ] && return 0
  dims="$(tmux list-clients -t "$FL_EXT_SESSION" -F '#{client_width} #{client_height}' 2>/dev/null | head -1)"
  if [ -n "$dims" ]; then
    w="${dims%% *}"; h="${dims##* }"
  else
    w="$(tmux display-message -p '#{window_width}'  2>/dev/null)"
    h="$(tmux display-message -p '#{window_height}' 2>/dev/null)"
  fi
  [ -n "$w" ] && [ -n "$h" ] || return 0
  need_w=$(( (cells > 1 ? 2 : 1) * 2 * 20 ))
  need_h=$(( (cells > 2 ? 2 : 1) * 2 * 6 ))
  if [ "$w" -lt "$need_w" ] || [ "$h" -lt "$need_h" ]; then
    printf 'fleet-layout: window is %sx%s but this layout needs at least %sx%s — aborting (nothing changed)\n' \
      "$w" "$h" "$need_w" "$need_h" >&2
    return 1
  fi
}

# Every pane belonging to the named agents' cells, claude first.
_desired_panes() {
  local name c
  for name in "$@"; do
    _claude_of "$name"
    # shellcheck disable=SC2086
    for c in $(_comps_of "$name"); do printf '%s\n' "$c"; done
  done
}

# True when the panes of window $1 are already exactly $2… — the idempotency guard. Without
# it a re-run re-joins panes that are already in place, reflowing or erroring.
_window_matches() {
  local win="$1"; shift
  local have want
  have="$(tmux list-panes -t "$win" -F '#{pane_id}' 2>/dev/null | sort | tr '\n' ' ')"
  want="$(printf '%s\n' "$@" | sort | tr '\n' ' ')"
  [ "$have" = "$want" ]
}

# <win-name> <agent…>  → 1 when already assembled, 0 to proceed, 2 to abort.
#
# The target window is resolved from the SEED PANE, never by name: tmux allows two windows to
# share a name, so a name lookup could compare against a foreign `features` window, fail to
# match, break out a second one, and do it again on every re-run — unbounded and never
# convergent. The seed's own window is unambiguous.
_assemble_prelude() {
  local win_name="$1"; shift
  local seed desired win
  seed="$(_claude_of "$1")"
  [ -n "$seed" ] || return 2
  desired="$(_desired_panes "$@")"
  win="$(tmux display-message -p -t "$seed" '#{window_id}' 2>/dev/null)"
  # shellcheck disable=SC2086
  if [ -n "$win" ] && _window_matches "$win" $desired; then return 1; fi
  _precheck_room "$#" || return 2
  return 0
}

_join() {   # _join <-h|-v> <src> <dst> — abort-on-failure wrapper
  _rw join-pane "$1" -s "$2" -t "$3" || { _join_failed "$2" "$3"; return 1; }
}

# ---------------------------------------------------------------------------- sessions

_session_exists() { tmux has-session -t "=$1" 2>/dev/null; }

# A tmux session must own at least one window, so a new one is born with a placeholder that we
# drop once the real window has moved in.
_ensure_session() {
  _session_exists "$1" && return 0
  _rw new-session -d -s "$1" -n "$FL_PLACEHOLDER" || return 1
}

# Drop the placeholder — but ONLY if it is the placeholder, holds exactly one pane, and that
# pane is not any live agent's registry token. The LAYOUT verbs never kill an agent; the
# only sanctioned agent-kill path in this file is the `down` verb's _down_kill_pane.
_drop_placeholder() {
  [ "$DRY_RUN" = "1" ] && return 0
  local sess="$1" win panes tok
  _session_exists "$sess" || return 0
  [ "$(tmux list-windows -t "$sess" -F '#{window_id}' 2>/dev/null | wc -l | tr -d ' ')" -gt 1 ] || return 0
  win="$(tmux list-windows -t "$sess" -F '#{window_id} #{window_name}' 2>/dev/null | awk -v p="$FL_PLACEHOLDER" '$2==p{print $1; exit}')"
  [ -n "$win" ] || return 0
  panes="$(tmux list-panes -t "$win" -F '#{pane_id}' 2>/dev/null)"
  [ "$(printf '%s\n' "$panes" | wc -l | tr -d ' ')" -eq 1 ] || return 0
  for tok in $(live_agents | cut -f2); do
    [ "$tok" = "$panes" ] && { printf 'fleet-layout: refusing to drop placeholder — it holds agent pane %s\n' "$tok" >&2; return 0; }
  done
  tmux kill-window -t "$win" 2>/dev/null || true
}

_renumber() { [ "$DRY_RUN" = "1" ] && return 0; _session_exists "$1" && tmux move-window -r -t "$1" 2>/dev/null || true; }

# Relocate a window (by id) into <session>, unlinking it from wherever it was.
_move_window_to() {
  local win="$1" sess="$2" cur
  cur="$(_sess_of_win "$win")"
  [ "$cur" = "$sess" ] && return 0
  _ensure_session "$sess" || return 1
  _rw move-window -s "$win" -t "${sess}:" || {
    printf 'fleet-layout: move-window %s -> %s failed; the window stays where it is (no pane lost)\n' "$win" "$sess" >&2
    return 1; }
  _drop_placeholder "$sess"
  _renumber "$sess"; _renumber "$cur"
}

# wide: up to four cells as a 2x2 — f1 top-left, f2 top-right, f3 bottom-left, f4 bottom-right.
_gather_grid() {
  local win_name="$1"; shift
  local agents=("$@") name seed n="$#"
  _assemble_prelude "$win_name" "${agents[@]}"
  case "$?" in 1) return 0 ;; 2) return 1 ;; esac

  seed="$(_claude_of "${agents[0]}")"
  _seed_window "$win_name" "$seed" || return 1
  [ "$n" -ge 2 ] && { _join -h "$(_claude_of "${agents[1]}")" "$seed" || return 1; }
  [ "$n" -ge 3 ] && { _join -v "$(_claude_of "${agents[2]}")" "$seed" || return 1; }
  [ "$n" -ge 4 ] && { _join -v "$(_claude_of "${agents[3]}")" "$(_claude_of "${agents[1]}")" || return 1; }

  for name in "${agents[@]}"; do
    # shellcheck disable=SC2086
    build_cell "$(_claude_of "$name")" $(_comps_of "$name") || return 1
  done
  return 0
}

# dual: two cells STACKED — the first agent's row above the second's. Not the grid's
# side-by-side `-h`; a dual window is one column of rows.
_gather_pair() {
  local win_name="$1" a1="$2" a2="${3:-}"
  local c1 c2
  # shellcheck disable=SC2086
  _assemble_prelude "$win_name" "$a1" ${a2:+$a2}
  case "$?" in 1) return 0 ;; 2) return 1 ;; esac

  c1="$(_claude_of "$a1")"
  _seed_window "$win_name" "$c1" || return 1
  if [ -n "$a2" ]; then
    c2="$(_claude_of "$a2")"
    _join -v "$c2" "$c1" || return 1
  fi
  # shellcheck disable=SC2086
  build_cell "$c1" $(_comps_of "$a1") || return 1
  # shellcheck disable=SC2086
  [ -n "$a2" ] && { build_cell "$c2" $(_comps_of "$a2") || return 1; }
  return 0
}

# _chunk_windows <per-window> <base> <bare-when-single> <gather-fn> <agent…>
#
# Split the agents into windows of <per-window> and hand each group to <gather-fn>.
#
# WHY THIS EXISTS: both layouts used to index their agents by hand — `wide` joined exactly
# indices 0..3 into one window and `dual` wired up `$1 $2` and `$3 $4`. A FIFTH agent was
# therefore not laid out at all: it was not an error and nothing was destroyed, it simply
# stayed wherever it was while the report claimed the layout had been applied. Chunking makes
# the count open-ended, so agents 5-8 get a second window, 9-12 a third.
#
# NAMING: with a single chunk `wide` keeps the bare `features` name it always had; from two
# chunks on, every window is numbered. `_window_rank` orders windows by their LOWEST resident
# agent number rather than by name, so the numbering is cosmetic and the order stays correct
# however many windows there are.
_chunk_windows() {
  local per="$1" base="$2" bare="$3" fn="$4"; shift 4
  local total="$#" idx=1 win group
  while [ "$#" -gt 0 ]; do
    group=(); while [ "${#group[@]}" -lt "$per" ] && [ "$#" -gt 0 ]; do group+=("$1"); shift; done
    if [ "$bare" = 1 ] && [ "$total" -le "$per" ]; then win="$base"; else win="$base-$idx"; fi
    "$fn" "$win" "${group[@]}" || return 1
    idx=$((idx + 1))
  done
  return 0
}

# ── remembered layout ────────────────────────────────────────────────────────────────────
# The chosen layout is MACHINE STATE, not project config: it depends on which monitor is
# plugged in right now, so it belongs in ~/.claude beside the other runtime state and never in
# a committed file. One line, one word.
#
# WHY: spawning an agent creates a pane, and a new pane lands wherever tmux puts it — so every
# spawn silently degraded whatever arrangement was chosen earlier, and the operator had to
# re-issue the layout by hand each time. `reapply` closes that loop: the lead runs it after a
# spawn and the fleet returns to the shape the human last asked for.
_layout_state() { printf '%s' "$HOME/.claude/fleet-layout-mode"; }

_layout_remember() {  # <mode>
  [ "$DRY_RUN" = 1 ] && return 0
  mkdir -p "$HOME/.claude" 2>/dev/null || return 0
  printf '%s\n' "$1" > "$(_layout_state)" 2>/dev/null || true
}

layout_reapply() {
  local f mode; f="$(_layout_state)"
  [ -r "$f" ] || { echo "fleet-layout: no remembered layout — run single|dual|wide once first"; return 0; }
  mode="$(tr -d '[:space:]' < "$f")"
  case "$mode" in
    single) echo "fleet-layout: reapplying remembered layout 'single'";  layout_single ;;
    dual)   echo "fleet-layout: reapplying remembered layout 'dual'";    layout_dual ;;
    wide)   echo "fleet-layout: reapplying remembered layout 'wide'";    layout_wide ;;
    # An unreadable or corrupt value must NOT silently pick a layout on its own: rearranging
    # the operator's screen is exactly the thing they asked to be deterministic.
    *) echo "fleet-layout: remembered layout '$mode' is not one of single|dual|wide — ignoring" >&2; return 1 ;;
  esac
}

layout_wide() {
  local feats
  _snapshot_attr
  feats="$(_feature_agents | sort | cut -f2)"
  [ -n "$feats" ] || { echo "fleet-layout: no live feature agents" >&2; return 1; }
  # shellcheck disable=SC2086
  set -- $feats
  _chunk_windows 4 features 1 _gather_grid "$@" || return 1
  _settle_external
}

# `wide` and `dual` both target the external monitor. Move their windows across ONLY when a
# client is already attached to that session — a detached session sizes its windows 80x24 and
# would crush the layout. `attach` spawns the client first for exactly this reason.
_settle_external() {
  # --dry-run must take the SAME branch the real run would, or its output is a lie: gate on
  # _can_spawn in both. (Previously dry-run always printed "spawn + move", even on a host with
  # no second monitor where the real run prints "windows stay in main".)
  local ready=0
  if _ext_has_client; then
    ready=1
  elif [ "$DRY_RUN" = "1" ] && _can_spawn; then
    _ensure_session "$FL_EXT_SESSION"; _spawn_ext_client; ready=1
  elif [ "$DRY_RUN" != "1" ] && _can_spawn && _ensure_session "$FL_EXT_SESSION" && _spawn_ext_client; then
    ready=1
  fi

  if [ "$ready" = "1" ]; then
    _move_features_to_ext || true
    _drop_placeholder "$FL_EXT_SESSION"
    _renumber "$FL_EXT_SESSION"
  elif [ "$DRY_RUN" != "1" ]; then
    printf 'fleet-layout: no second monitor available — the feature windows stay in session %s.\n' "$FL_HOME_SESSION" >&2
  fi
  name_windows
  _renumber "$FL_HOME_SESSION"
  balance_cells
}

layout_dual() {
  local feats n
  _snapshot_attr
  feats="$(_feature_agents | sort | cut -f2)"
  [ -n "$feats" ] || { echo "fleet-layout: no live feature agents" >&2; return 1; }
  # shellcheck disable=SC2086
  set -- $feats
  # Always numbered (bare=0): `dual` has never had a single-window form, and two agents in
  # `features-1` with none in `features-2` is the shape it already produced.
  _chunk_windows 2 features 0 _gather_pair "$@" || return 1
  _settle_external
}

# The user arranges these panes by hand, so this only breaks a feature agent back OUT of a
# window it co-tenants (undoing wide/dual). Review + test agents share a window by design
# and are never restructured. Then main-vertical gives claude-left + stacked-right for free.
layout_single() {
  local agents panes name token comps win_of others
  _snapshot_attr
  agents="$(live_agents)"; panes="$(_pane_rows)"
  while IFS="$TAB" read -r name token comps; do
    [ -n "$name" ] || continue
    [ "$(_role_of "$name")" = "feature" ] || continue
    win_of="$(printf '%s\n' "$panes" | awk -F"$TAB" -v p="$token" '$1==p{print $3; exit}')"
    others=0
    while IFS="$TAB" read -r o_name o_tok _c _r; do
      [ "$o_name" = "$name" ] && continue
      printf '%s\n' "$panes" | awk -F"$TAB" -v p="$o_tok" -v w="$win_of" '$1==p && $3==w{found=1} END{exit !found}' \
        && others=$((others + 1))
    done <<EOF
$agents
EOF
    [ "$others" -eq 0 ] && continue              # already alone — respect the hand layout
    _seed_window "$name" "$token" || return 1
    # shellcheck disable=SC2086
    build_cell "$token" $comps || return 1
    # No `select-layout main-vertical` here: build_cell already produces claude-left with the
    # companions stacked right, and main-vertical would overwrite the 60/40 split with tmux's
    # main-pane-width default. (DX-jn-cc-002)
  done <<EOF
$(_attr)
EOF
  # Every feature window comes home — including agents the loop above skipped because they were
  # already alone in their window (which is exactly the post-`single` state in the ext session).
  _move_features_home || true
  name_windows
  _renumber "$FL_HOME_SESSION"
  balance_cells          # the windows just resized from the external monitor to the laptop
  _teardown_ext          # close the iTerm window + drop the now-empty external session
}

# ---------------------------------------------------------------------------- attach

# The widest NON-main screen, as iTerm window bounds "L T R B".
# Cocoa frames are bottom-left-origin; iTerm bounds are {left, top, right, bottom} measured DOWN
# from the main screen's top. For a frame (x,y,w,h) and main height H: top = H-(y+h), bottom = H-y.
# Close the iTerm window `attach` opened, by id. Never touches a window we did not create.
_close_iterm_window() {
  [ -n "$1" ] || return 0
  [ "$DRY_RUN" = "1" ] && { printf 'osascript: close iTerm window id %s\n' "$1"; return 0; }
  command -v osascript >/dev/null 2>&1 || return 0
  osascript <<AS >/dev/null 2>&1
tell application "iTerm2"
  repeat with w in windows
    if (id of w as string) is "$1" then close w
  end repeat
end tell
AS
}

_second_screen_bounds() {
  osascript -l JavaScript -e 'ObjC.import("AppKit");
    var s = $.NSScreen.screens.js.map(function(x){var f=x.frame;
      return {x:f.origin.x, y:f.origin.y, w:f.size.width, h:f.size.height};});
    if (s.length < 2) { "" } else {
      var H = s[0].h, best = null;
      for (var i=1;i<s.length;i++) if (!best || s[i].w > best.w) best = s[i];
      [best.x, H-(best.y+best.h), best.x+best.w, H-best.y].join(" ")
    }' 2>/dev/null
}

# Spawn an iTerm window on the second monitor attached to the dedicated session, THEN move the
# grid into it — a detached session sizes its windows 80x24 and would crush the grid.
# Window ids hosting at least one live FEATURE agent. `wide` yields one; `dual` yields two.
_feature_windows() {
  local name tok role
  while IFS="$TAB" read -r name tok _cwd role; do
    [ "$role" = "feature" ] || continue
    _win_of "$tok"
  done <<EOF
$(live_agents)
EOF
}

# Spawn an iTerm window on the second monitor and make it a client of the external session.
#
# We do NOT pass a command or type into the window. `create window … command "…"` execs without
# a login shell and the session dies; `write text` is worse — the user's ~/.zshrc ends with
# `exec tmux -2 new-session -A -s main`, so a fresh interactive shell is ALREADY a tmux client
# of the home session, and the keystrokes would land in whichever pane that session has active
# (observed: they were typed into an agent's companion shell). Instead we let the rc attach the
# new window wherever it wants, spot the new client by its tty, and `switch-client` it across.
# Nothing is ever typed into a pane. (DX-jn-cc-002)
# True when we may open a real terminal window: never for the test harness's scratch server.
_can_spawn() { [ -z "${FLEET_TMUX_SOCKET:-}" ] && command -v osascript >/dev/null 2>&1; }

_spawn_ext_client() {
  local bounds res winid wintty i
  _can_spawn || { echo "fleet-layout: cannot open a terminal window here" >&2; return 1; }
  bounds="$(_second_screen_bounds)"

  if [ "$DRY_RUN" = "1" ]; then
    printf 'osascript: new iTerm window bounds={%s}; switch-client -> %s\n' "${bounds:-<main screen>}" "$FL_EXT_SESSION"
    return 0
  fi

  # Ask iTerm for the new window's tty DIRECTLY. Diffing `tmux list-clients` before/after would
  # race: a terminal the user opens concurrently would look like "the new client" and we would
  # switch THEIR session out from under them. We only ever switch the tty iTerm handed us.
  # shellcheck disable=SC2086
  set -- $bounds
  res="$(osascript <<AS 2>/dev/null
tell application "iTerm2"
  set newWin to (create window with default profile)
  $([ "$#" -eq 4 ] && printf 'set bounds of newWin to {%s, %s, %s, %s}' "$1" "$2" "$3" "$4")
  delay 0.4
  return (id of newWin as string) & " " & (tty of current session of newWin)
end tell
AS
)"
  # iTerm returns "<winid> <tty>". If the tty is missing, `${res##* }` collapses to the winid and
  # a bare non-empty check passes wrongly. Require two fields and a real device path.
  winid="${res%% *}"; wintty="${res##* }"
  case "$res" in *' '*) : ;; *) wintty="" ;; esac
  case "$wintty" in /dev/*) : ;; *) wintty="" ;; esac
  [ -n "$winid" ] && [ -n "$wintty" ] || {
    _close_iterm_window "$winid"
    echo "fleet-layout: iTerm did not report a usable window id + tty (got '$res')" >&2; return 1; }

  # The rc (`exec tmux -2 new-session -A -s main`) attaches it somewhere; wait for it to appear.
  for i in $(seq 1 20); do
    tmux list-clients -F '#{client_tty}' 2>/dev/null | grep -qx "$wintty" && break
    sleep 0.5
  done
  tmux list-clients -F '#{client_tty}' 2>/dev/null | grep -qx "$wintty" || {
    _close_iterm_window "$winid"
    echo "fleet-layout: the new iTerm window ($wintty) never became a tmux client" >&2; return 1; }

  tmux switch-client -c "$wintty" -t "$FL_EXT_SESSION" || {
    _close_iterm_window "$winid"; echo "fleet-layout: switch-client to $FL_EXT_SESSION failed" >&2; return 1; }
  tmux set-option -t "$FL_EXT_SESSION" @fl-iterm-window "$winid" 2>/dev/null || true
}

_ext_has_client() { tmux list-clients -t "$FL_EXT_SESSION" 2>/dev/null | grep -q .; }

# Tear the external session down once no feature agent lives there: close the iTerm window we
# opened, then drop the (now agent-free) session. REFUSES while any live agent's pane is still
# in it — the layout verbs never destroy an agent. _teardown_ext holds the file's single
# kill-session invocation (structurally pinned by the test suite's comment-stripped count).
# Every registry token, read straight off DISK. Deliberately NOT `live_agents`: that filters
# through fleet_alive -> `tmux list-panes -a`, so a transient tmux hiccup silently drops an
# agent from the list. For a destroy guard that is a fail-OPEN. Files do not race.
_registry_tokens() {
  local f line w had_noglob=''
  case $- in *f*) had_noglob=1 ;; esac
  for f in "$HOME"/.claude/running-agents/*; do
    [ -f "$f" ] || continue
    # Normalize PER LINE, not per file: whole-file tr merged a (corrupt) multi-line file
    # into one garbage word, silently dropping every token it contained — the old code
    # word-split and checked each. Within a line, strip CR/whitespace: a token that differs
    # by a byte from tmux's `%N` defeats every comparison below.
    while IFS= read -r line || [ -n "$line" ]; do
      # Strip CR ONLY — interior whitespace SEPARATES tokens (a '%3 %7' line carries two);
      # stripping it merged them into ONE shape-passing bogus token, unprotecting both.
      line="${line//$'\r'/}"
      # set -f: the unquoted split would otherwise PATHNAME-EXPAND a corrupted line's
      # glob metacharacters ('%*') against the invoking CWD, emitting filenames as tokens.
      set -f
      for w in $line; do
        case "$w" in %[0-9]*) printf '%s\n' "$w" ;; esac
      done
      # Restore the caller's state, don't blindly re-enable globbing.
      [ -n "$had_noglob" ] || set +f
    done < "$f" 2>/dev/null
  done
}

# Byte-exact membership test WITHOUT a pipeline: `printf | grep -qx` can die by SIGPIPE
# under pipefail when grep exits early on a huge list, reporting non-match despite a match.
# -F: the token is data, never a pattern (a shape-passing `%1.` must not x-match `%12`).
_has_line() {
  grep -qxF -- "$2" <<EOF
$1
EOF
}

_teardown_ext() {
  # The external session is env-overridable. If it were ever set to the home session, this
  # function would kill `main` and every agent in it. Refuse, whatever the config says.
  [ -n "$FL_EXT_SESSION" ] && [ "$FL_EXT_SESSION" != "$FL_HOME_SESSION" ] || {
    printf 'fleet-layout: refusing to tear down %s — it is the home session\n' "$FL_EXT_SESSION" >&2
    return 0; }
  _session_exists "$FL_EXT_SESSION" || return 0

  # Shell option state is a guard input: under inherited noglob (`set -f`, e.g. via an
  # exported SHELLOPTS), the registry readdir globs below never expand — the registry
  # reads as EMPTY and the unreadable-entry scan goes vacuous, failing this guard OPEN.
  case $- in *f*)
    printf 'fleet-layout: noglob shell state blinds the registry scan — refusing to tear down %s\n' "$FL_EXT_SESSION" >&2
    return 0 ;;
  esac

  # The file's single kill-session lives at the bottom of this function, and what it can
  # destroy is a running agent's process. It refuses unless it can POSITIVELY establish
  # that no registry pane lives here.
  #
  # The decision is made from the SESSION'S OWN PANE LIST first, not from a registry ->
  # display-message lookup. An adversarial review killed an agent through the lookup three ways:
  # a wrong-but-non-empty session name, a `list-panes -a` reply that omitted the pane, and a
  # CRLF-corrupted token. The pane list is the data we already hold; use it.
  local panes tok sess rc f all
  [ -d "$HOME/.claude/running-agents" ] || {
    printf 'fleet-layout: registry directory missing — refusing to tear down %s\n' "$FL_EXT_SESSION" >&2
    return 0; }
  # Same epistemic state as a missing directory, one level down: an entry we cannot READ is
  # UNKNOWN content — it may name a pane in this very session — so refuse. Readable-but-garbage
  # is different (KNOWN non-agent data; _registry_tokens drops it). Without this scan an
  # unreadable file made tr fail silently, the token vanished, and the agent it named went
  # unprotected. A dir-shaped or dangling-symlink entry is the same unknown; only an unmatched
  # glob (empty registry) passes through.
  for f in "$HOME"/.claude/running-agents/*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    [ -f "$f" ] && [ -r "$f" ] || {
      printf 'fleet-layout: registry entry %s is not a readable file — refusing to tear down %s\n' "$f" "$FL_EXT_SESSION" >&2
      return 0; }
  done
  tmux display-message -p '#{pid}' >/dev/null 2>&1 || {
    printf 'fleet-layout: tmux is not answering — refusing to tear down %s\n' "$FL_EXT_SESSION" >&2
    return 0; }
  panes="$(tmux list-panes -s -t "=$FL_EXT_SESSION" -F '#{pane_id}' 2>/dev/null)"
  [ -n "$panes" ] || {
    printf 'fleet-layout: cannot enumerate %s — refusing to tear it down\n' "$FL_EXT_SESSION" >&2
    return 0; }

  for tok in $(_registry_tokens); do
    # (1) Direct: is this agent among the panes the session itself reports?
    _has_line "$panes" "$tok" && {
      printf 'fleet-layout: %s still hosts agent pane %s — leaving the session up\n' "$FL_EXT_SESSION" "$tok" >&2
      return 0; }

    # (2) Corroborate. EXIT STATUS is the oracle for "does this pane exist", not emptiness:
    # tmux errors on an unknown pane. A pane that resolves but reports no session, or reports
    # a session while claiming not to be in ext, means tmux is contradicting itself — refuse.
    sess="$(tmux display-message -p -t "$tok" '#{session_name}' 2>/dev/null)"; rc=$?
    if [ "$rc" -eq 0 ]; then
      # A whitespace-only reply is "no session" wearing padding — the -n test alone passes it,
      # and it then reads as "agent is elsewhere". Blank it; legit names with spaces are trimmed
      # by neither branch (only the all-whitespace case collapses).
      case "$sess" in *[![:space:]]*) : ;; *) sess="" ;; esac
      [ -n "$sess" ] || {
        printf 'fleet-layout: pane %s resolves but reports no session — refusing to tear down %s\n' "$tok" "$FL_EXT_SESSION" >&2
        return 0; }
      [ "$sess" = "$FL_EXT_SESSION" ] && {
        printf 'fleet-layout: %s still hosts agent pane %s — leaving the session up\n' "$FL_EXT_SESSION" "$tok" >&2
        return 0; }
    else
      # rc != 0 says the pane does not exist — but a lone negative from display-message is the
      # one place this guard would accept a failure as proof of death. Corroborate server-wide:
      # genuinely-dead panes are absent from `list-panes -a` too (anti-vacuity: cleanup after a
      # dead agent still proceeds); present means tmux is contradicting itself — refuse.
      # An EMPTY -a reply is tmux contradicting itself BY CONSTRUCTION: ext's own pane
      # list already enumerated non-empty above, and -a is a superset of -s. Treating it
      # as "absent everywhere" would re-admit the original blank-reply kill.
      all="$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null)"
      [ -n "$all" ] || {
        printf 'fleet-layout: cannot enumerate the server pane list — refusing to tear down %s\n' "$FL_EXT_SESSION" >&2
        return 0; }
      if _has_line "$all" "$tok"; then
        printf 'fleet-layout: pane %s exists server-wide but its session is unresolvable — refusing to tear down %s\n' "$tok" "$FL_EXT_SESSION" >&2
        return 0
      fi
    fi
  done

  _close_iterm_window "$(tmux show-options -t "$FL_EXT_SESSION" -v @fl-iterm-window 2>/dev/null)"
  # Routed through _rw so the dry-run print is _rw's verb-generic printf — a hand-rolled
  # printf here is EXECUTABLE source and broke the test suite's invocation count (rev-a R2).
  _rw kill-session -t "=$FL_EXT_SESSION" 2>/dev/null || true
}

# Move every feature window into the external session. Safe to call repeatedly.
_move_features_to_ext() {
  local win rc=0
  for win in $(_feature_windows | sort -u); do
    _move_window_to "$win" "$FL_EXT_SESSION" || rc=1
  done
  return "$rc"
}

# …and back to the laptop. Must cover EVERY feature window, not just the ones `single`
# restructured: an agent already alone in its window is skipped by the rebuild loop, so a
# per-agent move there would strand it in the external session. (DX-jn-cc-002)
_move_features_home() {
  local win rc=0
  for win in $(_feature_windows | sort -u); do
    _move_window_to "$win" "$FL_HOME_SESSION" || rc=1
  done
  return "$rc"
}

# Put the feature agents on the second monitor: ensure the session, attach a client to it, then
# move the windows across. Order matters — a DETACHED session sizes its windows 80x24, which
# would crush the grid, so the client comes first.
# Re-open / re-attach the external monitor window for an already-built wide|dual layout.
attach_external() {
  _snapshot_attr
  [ -n "$(_feature_windows)" ] || { echo "fleet-layout: no feature windows; run \`wide\` or \`dual\` first" >&2; return 1; }
  _settle_external
}

# ----------------------------------------------------------------------- subagents
# Restack a lead's SUBAGENT panes (reviewer / tester / planner …) directly beneath the
# lead's own claude pane.
#
# Why this verb exists: with `teammateMode: "tmux"`, an Agent-tool spawn is materialised as a
# real pane, and the harness places it wherever tmux's current layout puts a new pane — in
# practice appended into the cell's RIGHT column, under the monocle companion. Five reviewers
# and testers land on top of a 40%-wide column and the whole window becomes unreadable. They
# belong under the lead, in the left column: they are work the lead is waiting on, so reading
# them top-to-bottom next to the lead's own transcript is the arrangement that matches how
# they are used.
#
# WHICH PANES. The team config is authoritative — Claude Code records each member's
# `tmuxPaneId` and `agentType` there, so we neither guess from pane titles (an agent can set
# its own) nor parse `ps` (a pane's claude is a grandchild of the pane's own pid). Every
# config under ~/.claude/teams/ is scanned and self-located: a config is OURS if one of its
# non-lead members sits on a pane that currently exists. That means no session id is needed,
# and a crashed lead's stale config contributes nothing, because its recorded panes are gone.
#
# TARGET is $TMUX_PANE — the invoking lead's own pane. The lead is what runs this verb, so its
# pane is known exactly rather than inferred, and a subagent can never be its own target.
# A team member that has ENTERED A LANE is not a subagent — it is a teammate, and its pane
# belongs in that lane's own window, not stacked under the lead.
#
# The team config cannot tell them apart: both are members, `agentType` is whatever the lead
# named at spawn (often nothing), and the config's recorded `cwd` is the LEAD's for every member
# because it is written at spawn, before EnterWorktree. The discriminator that actually holds is
# WHERE THE PANE IS NOW, compared against the lead:
#
#   same cwd as the lead  → it never moved → subagent → stack it under the lead
#   different cwd         → it entered a lane → teammate → leave it in its own window
#
# NOT "is it inside the lanes directory" — which was the first attempt and silently matched
# everything, because THE LEAD'S OWN WORKTREE IS A LANE (lane 0). Every subagent sits in it, so
# the test was true for exactly the panes it was meant to select, and `subagents` reported "no
# live subagent panes to place" while one sat in the window.
#
# A teammate that has not entered its lane yet also reads as a subagent and gets stacked. That
# is the safe direction: it is squatting the lead's tree, where lane-guard is refusing its
# writes, so surfacing it under the lead is exactly where you want to see it.
_pane_shares_lead_cwd() {   # <pane_id> <lead-cwd> -> 0 when the pane never left the lead's tree
  local p; p="$(tmux display-message -p -t "$1" '#{pane_current_path}' 2>/dev/null)"
  p="$(_abs "$p")"; [ -n "$p" ] || return 1
  [ "$p" = "$2" ]
}

_subagent_panes() {   # <lead-cwd> -> "<pane_id>\t<agent-name>\t<agent-type>" per live subagent pane
  local leadcwd="$1" live c
  live="$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null)" || return 1
  [ -n "$live" ] || return 1
  for c in "$HOME"/.claude/teams/*/config.json; do
    [ -r "$c" ] || continue
    python3 - "$c" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for m in d.get('members', []):
    pane = m.get('tmuxPaneId') or ''
    # 'leader' is the lead's sentinel, not a pane id; skip the lead and anything unplaced.
    if not pane.startswith('%'):
        continue
    if (m.get('agentType') or '') == 'team-lead':
        continue
    print('%s\t%s\t%s' % (pane, m.get('name', '?'), m.get('agentType') or '?'))
PY
  done | sort -u | while IFS="$TAB" read -r pane name atype; do
    [ -n "$pane" ] || continue
    _has_line "$live" "$pane" || continue          # recorded but gone — a dead teammate's leftover
    _pane_shares_lead_cwd "$pane" "$leadcwd" || continue   # moved into a lane => teammate, leave it
    printf '%s\t%s\t%s\n' "$pane" "$name" "$atype"
  done
}

# The lead's own window, sized so the chat is actually readable.
#
# NOT `select-layout even-vertical`, which was the first attempt: it reflows EVERY pane in the
# window to equal height, so the lead's chat ends up the same size as a shell it never looks at.
# Targeted resizes instead — the chat keeps a fixed share and the companions divide the rest.
#
# This runs even when there are no subagents, because the sizing drifts on its own: breaking the
# team's panes out into their own windows (`single`) left the lead's chat at 62 columns of a
# 208-column window, since tmux keeps the surviving panes' geometry rather than reflowing.
FL_LEAD_WIDTH_PCT="${WORKFLOW_LEAD_WIDTH_PCT:-60}"
FL_LEAD_HEIGHT_PCT="${WORKFLOW_LEAD_HEIGHT_PCT:-65}"
_normalize_lead_window() {  # <lead-pane>
  local p="$1" win w h
  win="$(_win_of "$p")"; [ -n "$win" ] || return 0
  w="$(tmux display-message -p -t "$win" '#{window_width}'  2>/dev/null)"
  h="$(tmux display-message -p -t "$win" '#{window_height}' 2>/dev/null)"
  case "$w" in ''|*[!0-9]*) return 0 ;; esac
  case "$h" in ''|*[!0-9]*) return 0 ;; esac
  # Width first: it decides the left column. Only widen when there IS another column, otherwise
  # tmux clamps and the call is noise.
  if [ "$(tmux list-panes -t "$win" -F x 2>/dev/null | wc -l | tr -d ' ')" -gt 1 ]; then
    _rw resize-pane -t "$p" -x "$(( w * FL_LEAD_WIDTH_PCT / 100 ))" 2>/dev/null || true
    _rw resize-pane -t "$p" -y "$(( h * FL_LEAD_HEIGHT_PCT / 100 ))" 2>/dev/null || true
  fi
  _seed_companion "$win" "$p"
}

# Is <pane> sitting at a bare shell prompt — i.e. running nothing of its own?
_pane_is_shell() {
  case "$(tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null)" in
    bash|zsh|fish|sh|-bash|-zsh|-fish|-sh) return 0 ;;
    *) return 1 ;;
  esac
}

# Start WORKFLOW_CELL_COMMAND in the window's TOP-RIGHT pane, if that pane is idle.
#
# `build_cell` already does this for a feature agent's cell, but the LEAD's window is not a cell
# — nothing ever built it — so its companion sat at a bare prompt while every feature agent got
# its tool. Same treatment, same command, one place that decides what a companion runs.
#
# ONLY WHEN IDLE, and that is the whole safety story: keying into a pane is an ACTION, and
# send-keys succeeds at the tmux layer even when the receiving program has no idea what to do
# with the text. A pane already running something (an editor, a log tail, a shell mid-command)
# is left strictly alone — a missing companion is a small annoyance, typing into a live process
# is not.
_seed_companion() {  # <window> <lead-pane>
  [ -n "$FL_CELL_COMMAND" ] || return 0          # empty by default; nothing to seed
  local win="$1" lead="$2" top_right
  # Top-right = the pane in a different column from the lead (greatest left), highest up
  # (smallest top). Ties break on the topmost, which is what "top right" means visually.
  top_right="$(tmux list-panes -t "$win" -F '#{pane_id} #{pane_left} #{pane_top}' 2>/dev/null \
    | awk -v lead="$lead" '$1!=lead { if ($2>bl || ($2==bl && $3<bt)) { bl=$2; bt=$3; id=$1 } } END{ if (id) print id }')"
  [ -n "$top_right" ] || return 0
  _pane_is_shell "$top_right" || return 0        # busy with something real — hands off
  _rw send-keys -t "$top_right" -l "$FL_CELL_COMMAND"
  _rw send-keys -t "$top_right" Enter
  echo "  companion    started '$FL_CELL_COMMAND' in $top_right (was an idle shell)"
}

layout_subagents() {
  fleet_tmux_ok || { echo "fleet-layout subagents: not inside tmux — nothing to place" >&2; return 0; }
  local target="$TMUX_PANE" leadcwd rows n=0
  leadcwd="$(_abs "$(tmux display-message -p -t "$target" '#{pane_current_path}' 2>/dev/null)")"
  rows="$(_subagent_panes "$leadcwd")" || true
  if [ -z "$rows" ]; then
    echo "fleet-layout subagents: no live subagent panes to place"
    _normalize_lead_window "$target"       # sizing drifts with or without subagents
    return 0
  fi
  local pane name atype
  while IFS="$TAB" read -r pane name atype; do
    [ -n "$pane" ] || continue
    # Never move our own pane, and never move the pane we are stacking onto.
    [ "$pane" = "$target" ] && { printf '  %-14s %s\n' "$name" "SKIPPED (that is the lead's own pane)"; continue; }
    printf '  %-14s %s\n' "$name" "$atype → below the lead's pane ($target)"
    # -v stacks BELOW the target, keeping it inside the left column rather than the cell's
    # right-hand companion stack. Failure is reported and does not abort the rest: a pane that
    # will not move is cosmetic, and half-placed beats aborted.
    _rw join-pane -v -s "$pane" -t "$target" || printf '  %-14s %s\n' "$name" "join failed (left where it was)"
    n=$((n + 1))
  done <<EOF
$rows
EOF
  _normalize_lead_window "$target"
  echo "fleet-layout subagents: placed $n"
}


# ---------------------------------------------------------------------------- main

[ -n "${FLEET_LAYOUT_LIB:-}" ] && return 0

USAGE="usage: fleet-layout.sh <single|dual|wide|attach|balance|name-windows|subagents|reapply> [--dry-run] [--label-only (name-windows)]"
verb=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --label-only) FL_LABEL_ONLY=1 ;;   # name-windows: relabel only, skip _order_windows (settle-recheck)
    single|dual|wide|attach|balance|name-windows|subagents|reapply)
      [ -z "$verb" ] || { echo "$USAGE" >&2; exit 2; }
      verb="$arg" ;;
    *) echo "$USAGE" >&2; exit 2 ;;
  esac
done
[ -n "$verb" ] || { echo "$USAGE" >&2; exit 2; }

# BOOT AND DOWN USED TO LIVE HERE, and their removal is why this dispatcher is so much
# simpler. Both enumerated the fleet from the machine-local worktrees manifest, which the
# lanes migration stopped maintaining — so both had been exiting 1 with "manifest missing or
# unreadable" for every invocation. Their replacements are lanes-native, in
# `.claude/scripts/team-boot.sh` (`boot`, `status`, `spawn-prompt`, `down`), which enumerates
# the lane directory itself; a lane is on disk by definition, so there is no manifest to go
# stale. `down`'s guards travelled with it: fail-closed busy, never-target-self, and a death
# claim earned by observation rather than by kill's exit status.
#
# What is left here is what this file is actually for: pane and window topology. It never
# starts or stops an agent, which is also why every verb below is safe to re-run.

# Layout verbs restructure nothing when there is no tmux, so exit 0 is the honest answer.
# (This used to fork three ways: down and boot both had to REFUSE here, because for a
# start/stop verb "nothing to do, exit 0" reads as "the fleet is up" / "the fleet is down"
# while the opposite is true. Neither verb lives here now, so the fork is gone with them.)
if ! fleet_tmux_ok; then
  echo "fleet-layout: not inside tmux — nothing to do" >&2; exit 0
fi

# A misconfigured external session that equals the home session would make `single` tear down
# `main` — every agent with it. Refuse before any verb runs.
[ -n "$FL_HOME_SESSION" ] && [ -n "$FL_EXT_SESSION" ] && [ "$FL_HOME_SESSION" != "$FL_EXT_SESSION" ] || {
  echo "fleet-layout: home session ('$FL_HOME_SESSION') and external session ('$FL_EXT_SESSION') must both be set and differ" >&2
  exit 2; }

if [ "$verb" != "name-windows" ]; then
  # A window sizes to the clients actually viewing it. Without this, attaching the laptop
  # alongside the double-wide clamps every window to the laptop's width.
  _rw set-window-option -g aggressive-resize on
  # Moving an agent's last pane out of its window destroys that window, leaving holes in the
  # index (1, 5, 7, 8 …). Renumber automatically instead. (DX-jn-cc-002)
  _rw set-option -g renumber-windows on
fi

case "$verb" in
  name-windows) name_windows ;;
  balance)      balance_cells ;;
  single)       layout_single && _layout_remember single ;;
  dual)         layout_dual && _layout_remember dual ;;
  wide)         layout_wide && _layout_remember wide ;;
  attach)       attach_external ;;
  subagents)    layout_subagents ;;
  reapply)      layout_reapply ;;
esac
