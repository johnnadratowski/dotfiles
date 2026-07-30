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
#   fleet-layout.sh boot         [--dry-run]   # bring the fleet up from cold: create windows
#                                              #   for dead manifest agents + launch claude
#   fleet-layout.sh down [--dry-run] [--force] # stop every fleet agent and remove its panes
#                                              #   (path-keyed, idle-gated, fail-closed guards)
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
# `name-windows` is called by register-agent.sh and agent-rename.sh so window labels stay
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
# shellcheck source=_config.sh
[ -r "$_here/_config.sh" ] && . "$_here/_config.sh"

DRY_RUN=0
FORCE=0                                        # set by the dispatcher's --force (down only)
FLEET_DOWN_SETTLE="${FLEET_DOWN_SETTLE:-5}"    # seconds to wait for SessionEnd unregistration
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
  local f base name pid token cwd acwd
  for f in "$HOME"/.claude/running-agents/*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"; pid="${base##*.}"; name="${base%.*}"
    token="$(cat "$f" 2>/dev/null)"
    [ -n "$token" ] || continue
    fleet_alive "$pid" "$token" || continue
    cwd="$(cat "$HOME/.claude/agents/$name.cwd" 2>/dev/null)"
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

layout_wide() {
  local feats
  _snapshot_attr
  feats="$(_feature_agents | sort | cut -f2)"
  [ -n "$feats" ] || { echo "fleet-layout: no live feature agents" >&2; return 1; }
  # shellcheck disable=SC2086
  set -- $feats
  _gather_grid features "$@" || return 1
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
  n="$#"
  [ "$n" -ge 1 ] && { _gather_pair features-1 "$1" ${2:+"$2"} || return 1; }
  [ "$n" -ge 3 ] && { _gather_pair features-2 "$3" ${4:+"$4"} || return 1; }
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

# ---------------------------------------------------------------------------- boot
# (DX-jn-cc-007) Bring the fleet up from cold: enumerate agent worktrees from the
# machine-local manifest, skip live agents (and self), sweep dead same-name registry
# entries, create missing windows in canonical order, and type the launch command ONLY
# into panes THIS RUN created (captured from its own `new-window -P`) — never into a
# pre-existing pane, whose state is unknown. Resume prompts are answered by the human.

# The manifest path comes from the ONE resolver (fleet_manifest_path, _fleet.sh) — never a
# hardcoded per-project filename. Unresolvable → empty, and the `-r` guard below refuses loudly.
BOOT_MANIFEST="$(fleet_manifest_path 2>/dev/null || true)"

# agent \t active \t path — one line per manifest entry carrying an `agent` field.
# LOUD failure model: a corrupt/missing/unreadable manifest, or python3 unavailable,
# exits non-zero. It must never degrade to "0 agents, exit 0" — an operator recovering
# from a crash would read that as "fleet already up". (_config.sh's fail-soft manifest
# idiom is the parser here, NOT the failure model.)
_boot_manifest_agents() {
  [ -r "$BOOT_MANIFEST" ] || { echo "fleet-layout boot: manifest $BOOT_MANIFEST missing or unreadable" >&2; return 1; }
  python3 - "$BOOT_MANIFEST" <<'PY' || { echo "fleet-layout boot: cannot parse manifest $BOOT_MANIFEST (invalid JSON, or python3 unavailable)" >&2; return 1; }
import json, sys
d = json.load(open(sys.argv[1]))
for w in d.get('worktrees', []):
    a = w.get('agent')
    if not a:
        continue
    print(f"{a}\t{'1' if w.get('active', True) else '0'}\t{w.get('path', '')}")
PY
}

# Validate every entry BEFORE any filesystem use: the agent name feeds a same-name rm
# glob in the sweep and the path feeds new-window -c, so garbage fails the whole RUN
# loudly — only a path missing on disk is a per-agent warn+skip (handled in the loop).
_boot_validate() {
  local agent active path bad=0
  while IFS="$TAB" read -r agent active path; do
    case "$agent" in
      ''|*[!A-Za-z0-9_-]*) echo "fleet-layout boot: invalid agent name '$agent' in manifest (allowed: A-Za-z0-9_-)" >&2; bad=1 ;;
    esac
    case "$path" in
      /*) : ;;
      *) echo "fleet-layout boot: non-absolute path '$path' for agent '$agent' in manifest" >&2; bad=1 ;;
    esac
  done
  return "$bad"
}

# `claude --continue` when the worktree has prior sessions, else plain `claude`.
# Project dir munge = nonalnum→'-' (same rule as agent-fanout.sh / register-agent.sh).
_boot_claude_cmd() {
  local pd f
  pd="$HOME/.claude/projects/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '-')"
  for f in "$pd"/*.jsonl; do
    [ -e "$f" ] && { printf 'claude --continue'; return; }
    break
  done
  printf 'claude'
}

# Does <agent> have a LIVE registration? Full fleet_alive (pid + pane when the token is
# a pane) — the skip check is deliberately STRICTER than the sweep below.
_boot_agent_live() {
  local name="$1" f base pid token
  for f in "$HOME"/.claude/running-agents/"$name".*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"; pid="${base##*.}"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    token="$(cat "$f" 2>/dev/null)"
    [ -n "$token" ] || continue
    fleet_alive "$pid" "$token" && return 0
  done
  return 1
}

# Sweep <agent>'s dead registry entries — pid-only, deliberately NARROWER than the skip
# check: a live-pid/dead-pane entry is left for the registration-time prune to settle,
# because sweeping a live pid is the riskier error. Same-name entries only; the general
# stale sweep belongs to register-agent.sh.
_boot_sweep_dead() {
  local name="$1" f base pid
  for f in "$HOME"/.claude/running-agents/"$name".*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"; pid="${base##*.}"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null && continue
    if [ "$DRY_RUN" = 1 ]; then echo "(dry-run) would sweep dead registry entry $base"
    else rm -f "$f"; fi
  done
}

# A blind reply must not read as "no window" — that is a LAUNCH decision, and reading blindness as
# absence is how a second claude gets launched into a worktree. rc 0 = the window exists; rc 1 = it
# does not; rc 2 = we could not see (callers must not launch). Same discipline as _panes_at_path.
_boot_window_exists() {
  local wins
  wins="$(tmux list-windows -t "$FL_HOME_SESSION" -F '#{window_name}' 2>/dev/null)" || return 2
  [ -n "$wins" ] || return 2
  printf '%s\n' "$wins" | grep -qx "$1"
}

_boot_report() { printf '  %-14s %s\n' "$1" "$2"; }

# The cell (DX-jn-cc-012): claude full-height left, right column stacked — the configured
# companion command (WORKFLOW_CELL_COMMAND) top-right, shell at the prompt bottom-right.
# Called ONLY from boot's launch branch, so every pane it splits or keys into was created by
# THIS run. Sizes are set at creation time (-l 40%, then the v-split's even default —
# _balance_cell's steady-state ratio): balance_cells needs attribution, which needs a
# registration that doesn't exist until the booted claude's SessionStart fires. A failure
# DEGRADES (report + return 1, the claude launch already happened and matters more than its
# companions); a failed v-split leaves the single right pane at the prompt with no companion —
# a bare shell is the safe degraded state.
#
# WORKFLOW_CELL_COMMAND EMPTY (the default) → the cell is still built, both right panes just sit
# at a shell prompt and NOTHING is keyed. The success return is DELIBERATE (a helper's return
# status is a contract): with no keystroke there is no last-command status to leak, so we return
# 0 explicitly rather than inheriting whatever the last conditional evaluated to.
_boot_cell() {
  local agent="$1" pane="$2" path="$3" right bottom
  if [ "$DRY_RUN" = 1 ]; then
    _rw split-window -d -h -l '40%' -P -F '#{pane_id}' -t "$pane" -c "$path"
    _rw split-window -d -v -P -F '#{pane_id}' -t '<right-pane>' -c "$path"
    [ -n "$FL_CELL_COMMAND" ] && _rw send-keys -t '<right-pane>' "$FL_CELL_COMMAND" C-m
    return 0
  fi
  if ! right="$(tmux split-window -d -h -l '40%' -P -F '#{pane_id}' -t "$pane" -c "$path")" || [ -z "$right" ]; then
    _boot_report "$agent" "cell DEGRADED (h-split errored — claude pane intact)"; return 1
  fi
  if ! bottom="$(tmux split-window -d -v -P -F '#{pane_id}' -t "$right" -c "$path")" || [ -z "$bottom" ]; then
    _boot_report "$agent" "cell DEGRADED (v-split errored — right pane left at the prompt)"; return 1
  fi
  [ -n "$FL_CELL_COMMAND" ] || return 0        # no companion configured — bare shells, success
  if [ -n "${FLEET_BOOT_LAUNCH_RECORDER:-}" ]; then
    printf '%s\t%s\n' "$agent" "$FL_CELL_COMMAND" >> "$FLEET_BOOT_LAUNCH_RECORDER"
  elif ! tmux send-keys -t "$right" "$FL_CELL_COMMAND" C-m; then
    _boot_report "$agent" "cell DEGRADED ($FL_CELL_COMMAND keystroke errored — top-right pane at the prompt)"; return 1
  fi
}

# Refocus the invoking window (DX-jn-cc-013): windows are created -d, but the end-of-run
# name_windows reordering can leave another window selected — the operator who typed
# `boot` gets their own window back. Cosmetic in the _balance_cell sense: headless, an
# unresolvable pane, or a failed select-window all degrade silently, never tainting rc.
_boot_refocus() {
  [ -n "${TMUX_PANE:-}" ] || return 0
  local win
  win="$(tmux display-message -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null)" || return 0
  [ -n "$win" ] || return 0
  _rw select-window -t "$win" || true
}

# Resolve the session boot creates its windows in, and REBIND FL_HOME_SESSION to it — one
# session identity for the whole run, never a boot-local second variable (DX-jn-cc-014). Four
# sites on boot's path read FL_HOME_SESSION: the two new-window calls, _boot_window_exists (the
# duplicate-launch guard), and name_windows → _order_windows. A partial rebind would blind the
# guard and silently no-op the ordering in exactly the projects this exists to serve.
#
# The CONFIGURED session wins when it exists on the server; otherwise fall back to the invoking
# client's own session (a generic project's default session is `0`, not `main` — `main` is one
# machine's zshrc convention). Boot NEVER creates a session. The persisted identity
# (WORKFLOW_FLEET_HOME_SESSION in workflow.config.local, written by base-initialize/base-setup)
# is the primary mechanism — this is the backstop for repos that never ran either.
_boot_resolve_session() {
  _session_exists "$FL_HOME_SESSION" && return 0
  local cur
  cur="$(tmux display-message -p -t "${TMUX_PANE:-}" '#{session_name}' 2>/dev/null || true)"
  [ -n "$cur" ] || { echo "fleet-layout boot: session '$FL_HOME_SESSION' not found and no current session to fall back to; refusing" >&2; return 2; }
  echo "fleet-layout boot: session '$FL_HOME_SESSION' not found — using current session '$cur'. Persist WORKFLOW_FLEET_HOME_SESSION=\"$cur\" in .claude/workflow.config.local — in the MAIN CLONE and in each agent worktree (or re-seed them) — or name-windows ordering and the layout verbs will keep targeting '$FL_HOME_SESSION'." >&2
  FL_HOME_SESSION="$cur"
  # The preamble's home!=ext guard ran against the CONFIGURED value, before this resolution — so
  # re-assert it. Without this a rebind could walk around a guard the preamble already cleared,
  # and `single` would later tear down the session holding every agent.
  [ "$FL_HOME_SESSION" != "$FL_EXT_SESSION" ] || {
    echo "fleet-layout boot: resolved home session '$FL_HOME_SESSION' equals the external session; refusing" >&2; return 2; }
  return 0
}

boot_fleet() {
  local rows self toplevel launched=0 rc=0
  _boot_resolve_session || return $?
  rows="$(_boot_manifest_agents)" || return 1
  [ -n "$rows" ] || { echo "fleet-layout boot: manifest has no agent entries — nothing to boot" >&2; return 1; }
  printf '%s\n' "$rows" | _boot_validate || return 1
  self="$(fleet_find_self "$HOME/.claude/running-agents" 2>/dev/null || true)"
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"

  local agent active path apath cmd pane live_row occ occ_rc occ_first wex
  # Canonical order: agents by trailing number (the fleet_agent_id instance number);
  # number-less names sort last. The manifest's own order is not a contract.
  while IFS="$TAB" read -r agent active path; do
    if [ "$active" = 0 ]; then _boot_report "$agent" "held (active: false)"; continue; fi
    if [ "$agent" = "$self" ] || { [ -n "$toplevel" ] && [ "$path" = "$toplevel" ]; }; then
      _boot_report "$agent" "skipped (self)"; continue
    fi
    _boot_sweep_dead "$agent"
    if _boot_agent_live "$agent"; then _boot_report "$agent" "live"; continue; fi
    # cwd corroboration (DX-jn-cc-010): a live registration at this WORKTREE counts as
    # live regardless of name — transient auto-names (pre-DX-jn-cc-006 worktrees) blind
    # the name-keyed check above, and a re-run then double-launched (observed 2026-07-10).
    apath="$(_abs "$path")"
    if [ -n "$apath" ] && live_row="$(_live_reg_at_path "$apath")"; then
      _boot_report "$agent" "live (as ${live_row%%"$TAB"*} — transient name)"; continue
    fi
    if [ ! -d "$path" ]; then _boot_report "$agent" "missing-path ($path)"; continue; fi
    # rc 0 = the window exists (leave it); rc 1 = it does not; rc 2 = WE COULD NOT SEE. A blind
    # reply must never fall through to the launch below — that is how a second claude lands in a
    # worktree. (The bare `if` here tested only zero-vs-nonzero, so a guarded rc 2 was still read as
    # "no window" — the guard was inert until this call site learned to read it.)
    _boot_window_exists "$agent"; wex=$?
    if [ "$wex" = 0 ]; then
      _boot_report "$agent" "window-exists (left untouched — launch manually or close it)"; continue
    elif [ "$wex" = 2 ]; then
      _boot_report "$agent" "REFUSED (cannot list windows — not launching blind)"; rc=1; continue
    fi
    # Occupancy by path, name-independent — the direct plug for the double-launch hazard.
    # rc 2 (blind pane list inside tmux) is a contradiction: REFUSE to launch, never read
    # blindness as "unoccupied".
    if [ -n "$apath" ]; then
      occ="$(_panes_at_path "$apath")"; occ_rc=$?
      if [ "$occ_rc" = 0 ]; then
        occ_first="$(printf '%s\n' "$occ" | head -1)"
        _boot_report "$agent" "occupied (pane ${occ_first%%"$TAB"*}, window ${occ_first#*"$TAB"}, at this worktree — left untouched)"; continue
      elif [ "$occ_rc" = 2 ]; then
        _boot_report "$agent" "REFUSED (cannot enumerate panes — not launching blind)"; rc=1; continue
      fi
    fi
    cmd="$(_boot_claude_cmd "$path")"
    if [ "$DRY_RUN" = 1 ]; then
      _rw new-window -d -P -F '#{pane_id}' -t "$FL_HOME_SESSION" -n "$agent" -c "$path"
      _rw send-keys -t '<new-pane>' "$cmd" C-m
      _boot_report "$agent" "booted ($cmd) [dry-run]"
      _boot_cell "$agent" '<new-pane>' "$path"
      launched=1
    else
      if ! pane="$(tmux new-window -d -P -F '#{pane_id}' -t "$FL_HOME_SESSION" -n "$agent" -c "$path")" || [ -z "$pane" ]; then
        _boot_report "$agent" "FAILED (new-window)"; rc=1; continue
      fi
      if [ -n "${FLEET_BOOT_LAUNCH_RECORDER:-}" ]; then
        printf '%s\t%s\n' "$agent" "$cmd" >> "$FLEET_BOOT_LAUNCH_RECORDER"
      else
        tmux send-keys -t "$pane" "$cmd" C-m
      fi
      _boot_report "$agent" "booted ($cmd)"
      _boot_cell "$agent" "$pane" "$path" || rc=1
      launched=1
    fi
  done < <(printf '%s\n' "$rows" | while IFS="$TAB" read -r a act p; do
             num="$(printf '%s' "$a" | grep -oE '[0-9]+$' || true)"
             printf '%09d\t%s\t%s\t%s\n' "${num:-999999999}" "$a" "$act" "$p"
           done | sort -n | cut -f2-)

  # Window names/order converge as each agent's SessionStart registration fires
  # name-windows itself; this pass just settles whatever is already registered.
  name_windows || true
  _boot_refocus
  if [ "$launched" = 1 ]; then
    echo "Resume prompts (e.g. \"Resume from summary\") are answered by the HUMAN — check each new window; boot never types into a pane it did not just create."
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------- down
# (DX-jn-cc-010) The inverse of boot: stop every fleet agent and remove its panes —
# never touching worktrees, self, or non-agent panes. Targeting is keyed on the
# WORKTREE PATH, never the agent name: live registrations can carry transient
# auto-names (observed 2026-07-10), and a name-keyed down would miss all of them.
#
# Failure DIRECTION (inverse of _teardown_ext): a vacuous scan here kills nothing —
# the danger is the operator reading "fleet is down, exit 0" while agents still run.
# So every guard input fails CLOSED into a loud non-zero refusal, `downed` is EARNED
# by post-kill observation (the founding incident was a sandbox masking kill failures),
# and exit 0 means exactly: every non-self entry is downed-and-verified or probe-
# confirmed not running.

# name \t pid \t token for every LIVE registration (full fleet_alive). Sidecars are NOT
# consulted here — placement is _reg_cwd's job, with policy at the call sites.
_down_live_regs() {
  local f base name pid token
  for f in "$HOME"/.claude/running-agents/*; do
    [ -f "$f" ] || continue
    base="${f##*/}"; pid="${base##*.}"; name="${base%.*}"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    token="$(cat "$f" 2>/dev/null)"
    [ -n "$token" ] || continue
    fleet_alive "$pid" "$token" || continue
    printf '%s\t%s\t%s\n' "$name" "$pid" "$token"
  done
}

# _reg_cwd <name> — echo the agent's resolved sidecar cwd. rc 0 = resolved; rc 2 =
# can't-place (sidecar missing / empty / unreadable / unresolvable). Epistemics live
# here; POLICY lives at the call sites: boot soft-skips into its occupancy backstop,
# down refuses the whole run (the unplaceable agent could be self or a target).
_reg_cwd() {
  local cwd acwd f="$HOME/.claude/agents/$1.cwd"
  [ -f "$f" ] && [ -r "$f" ] || return 2
  cwd="$(cat "$f" 2>/dev/null)" || return 2
  [ -n "$cwd" ] || return 2
  acwd="$(_abs "$cwd")"
  [ -n "$acwd" ] || return 2
  printf '%s\n' "$acwd"
}

# Any LIVE registration whose sidecar resolves to <path>, regardless of name.
# rc 0 = match (echoes "name\ttoken"), rc 1 = none. Shared by boot's live check and
# down's matcher — one matching pipeline, per-caller failure policy (see _reg_cwd).
_live_reg_at_path() {
  local name pid token acwd
  while IFS="$TAB" read -r name pid token; do
    [ -n "$name" ] || continue
    acwd="$(_reg_cwd "$name")" || continue
    [ "$acwd" = "$1" ] && { printf '%s\t%s\n' "$name" "$token"; return 0; }
  done <<EOF
$(_down_live_regs)
EOF
  return 1
}

# Panes whose cwd is <path> or a subdirectory — boundary-aware ("$p"|"$p"/*): sibling
# worktrees share string prefixes (see attribute_panes). rc 0 = hit(s), echoed as
# "pane_id\twindow_name"; rc 1 = none; rc 2 = UNKNOWN — callers treat it as blindness,
# never as "unoccupied"/"not running".
#
# TWO ways to be blind, and BOTH are rc 2:
#   - the whole server pane list came back empty (self-contradictory inside tmux: our own
#     pane exists), and
#   - ANY pane's cwd field came back empty/unresolvable. A pane exists but we cannot say
#     WHERE it is, so we cannot say the queried path is unoccupied. This branch used to
#     `continue` — dropping that pane silently — which read field-level blindness as
#     "absent" while the list-level case was correctly read as "unknown". The same
#     empty-enumeration class, one level down: an unreadable FIELD is UNKNOWN, not absent.
#     It is reachable in practice: a pane's cwd is not populated the instant it is created,
#     so a freshly-split pane can appear with no path (this is what made the suite flaky).
#     Consequences of the old behavior: boot's occupancy backstop — the direct plug for the
#     double-launch hazard — would miss the pane and launch a SECOND claude into the
#     worktree; down's UNACCOUNTED probe would report "not running" for a live pane.
# Re-read ONE pane's cwd, briefly, for the transient not-yet-populated case (see _panes_at_path).
#   rc 0 + path  — settled.
#   rc 1         — the pane is GONE: it is absent from the server's pane list. That is ABSENCE, not
#                  blindness — it vanished between the snapshot and now — so callers treat it as an
#                  honest miss rather than a refusal. (Conflating the two would make every pane that
#                  closes mid-run a spurious refusal, the class this helper exists to remove.)
#   rc 2         — UNKNOWN: either the pane exists but still reports no location after retrying, or
#                  we could not see the pane list at all. Callers must fail closed.
#
# NOTE what does NOT work as the gone-vs-blind oracle: display-message's EXIT STATUS. It exits 0
# with EMPTY output for a pane that does not exist (verified, tmux 3.x) — it looks like an oracle
# and is not. Pane-LIST membership answers the question; but the list itself can be blind, and an
# empty -a reply is tmux contradicting itself by construction (our own pane is always in it), so it
# is UNKNOWN — never "absent everywhere". Reading a blind list as "the pane is gone" would drop the
# pane from _panes_at_path and let boot's occupancy backstop launch a SECOND claude into the
# worktree: the same unknown-is-not-absent bug this helper was written to fix, one level down.
_pane_path_settled() {
  local pid="$1" i=0 p all
  while [ "$i" -lt 10 ]; do
    p="$(tmux display-message -p -t "$pid" '#{pane_current_path}' 2>/dev/null)"
    [ -n "$p" ] && { printf '%s' "$p"; return 0; }
    all="$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null)"
    [ -n "$all" ] || return 2                              # blind list => UNKNOWN, never "gone"
    printf '%s\n' "$all" | grep -qx "$pid" || return 1    # genuinely absent => honest miss
    i=$((i+1)); sleep 0.05
  done
  return 2
}

_panes_at_path() {
  local rows pid win ppath hit=1
  rows="$(tmux list-panes -a -F "#{pane_id}${TAB}#{window_name}${TAB}#{pane_current_path}" 2>/dev/null)"
  [ -n "$rows" ] || return 2
  while IFS="$TAB" read -r pid win ppath; do
    [ -n "$pid" ] || continue
    # BLINDNESS is the EMPTY RAW FIELD: tmux knows the pane exists but reports no location — we
    # cannot say the queried path is unoccupied, so it is UNKNOWN (rc 2), never "absent".
    #
    # But an empty field is usually TRANSIENT: tmux does not populate pane_current_path the instant
    # a pane is created, and panes get created all the time (every split, every new window, by us
    # and by the user). Failing closed on the first empty read would refuse boot/down for the WHOLE
    # fleet whenever any unrelated pane happens to be a few milliseconds old. So re-query that one
    # pane before declaring blindness: transient => it resolves; genuinely unreadable => it doesn't.
    if [ -z "$ppath" ]; then
      ppath="$(_pane_path_settled "$pid")"
      case $? in
        0) : ;;                 # settled
        1) continue ;;          # the pane vanished between snapshot and re-read — honest miss
        *) return 2 ;;          # exists but unplaceable — UNKNOWN, fail closed
      esac
    fi
    ppath="$(_abs "$ppath")"
    # A path we CAN read but cannot canonicalize (the pane's cwd was deleted) is not blindness: we
    # know where the pane is, and it is not the worktree we asked about (which exists). Honest miss.
    [ -n "$ppath" ] || continue
    case "$ppath" in
      "$1"|"$1"/*) printf '%s\t%s\n' "$pid" "$win"; hit=0 ;;
    esac
  done <<EOF
$rows
EOF
  return "$hit"
}

# Busy gate for the KILL path: UNKNOWN fails toward BUSY (skip), per the destroy-guard
# discipline — fleet_busy (the canonical predicate in _fleet.sh) reads unknown as idle,
# which is right for status display and fail-open for a kill.
_down_busy() {
  local dir="$HOME/.claude/agent-busy" m="$HOME/.claude/agent-busy/$1"
  [ -e "$dir" ] || return 1                         # nobody has ever been marked → idle
  { [ -r "$dir" ] && [ -x "$dir" ]; } || return 0   # dir unreadable → UNKNOWN → busy
  if [ -e "$m" ] && ! find "$m" -mmin "-${WORKFLOW_BUSY_STALE_MIN:-30}" >/dev/null 2>&1; then return 0; fi  # query failed → busy
  fleet_busy "$1"
}

# THE file's only kill-pane (structurally pinned by the test suite). Terminal self
# backstop: whatever upstream logic concluded, our own pane is never a target.
_down_kill_pane() {
  if [ -n "${TMUX_PANE:-}" ] && [ "$1" = "$TMUX_PANE" ]; then
    printf 'fleet-layout down: refusing to kill own pane %s\n' "$1" >&2
    return 1
  fi
  _rw kill-pane -t "$1"
}

# The success claim is EARNED by observation: rc 0 = the pane is provably gone; rc 1 =
# alive or unknowable — both are FAILED, never `downed`. An empty server pane list is
# self-contradictory inside tmux and never corroborates death. NO exemptions here —
# the skip marker is a PRE-kill decision; it is mutable mid-run, so honoring it at
# verification time would reopen the masked-kill false success (rev-a R4/rev-b R3).
_down_verify_dead() {
  local all
  all="$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null)"
  [ -n "$all" ] || return 1
  _has_line "$all" "$1" && return 1
  return 0
}

# Surviving panes at <path> that are NOT sanctioned. Sanctioned survivors (exempt from
# the UNACCOUNTED probe ONLY — never from the kill verification above): our own pane,
# @fleet-layout-skip-marked panes, and panes at a cwd shared by >=2 snapshot agents
# (attribute_panes' attach-to-NEITHER ambiguity rule). A pane whose marker cannot be
# read counts as a HIT — over-reporting is the safe direction for an informational
# probe. Reads FL_DOWN_AMB (newline list of ambiguous cwds) from down_fleet's scope.
_down_probe_unsanctioned() {
  local hits prc pid win ppath amb exempt any=1
  hits="$(_panes_at_path "$1")"; prc=$?
  [ "$prc" = 0 ] || return "$prc"
  while IFS="$TAB" read -r pid win; do
    [ -n "$pid" ] || continue
    [ -n "${TMUX_PANE:-}" ] && [ "$pid" = "$TMUX_PANE" ] && continue
    [ "$(_skip_state "$pid")" = marked ] && continue
    ppath="$(tmux display-message -p -t "$pid" '#{pane_current_path}' 2>/dev/null)"
    ppath="$(_abs "$ppath")"
    exempt=0
    while IFS= read -r amb; do
      [ -n "$amb" ] || continue
      case "$ppath" in "$amb"|"$amb"/*) exempt=1 ;; esac
    done <<EOF2
${FL_DOWN_AMB:-}
EOF2
    [ "$exempt" = 1 ] && continue
    printf '%s\t%s\n' "$pid" "$win"; any=0
  done <<EOF
$hits
EOF
  return "$any"
}

_down_report() { printf '  %-14s %s\n' "$1" "$2"; }

down_fleet() {
  local bad=0 rows f
  # ---- global guards: every input fails CLOSED into a loud non-zero refusal ----
  case $- in *f*)
    echo "fleet-layout down: noglob shell state blinds the registry scan — refusing" >&2; return 1 ;;
  esac
  rows="$(_boot_manifest_agents)" || return 1
  [ -n "$rows" ] || {
    echo "fleet-layout down: manifest has no agent entries — refusing (an empty enumeration must never read as 'fleet is down')" >&2
    return 1; }
  printf '%s\n' "$rows" | _boot_validate || return 1
  # ---- per-agent filter (DX-jn-cc-014) ----
  # Applied AFTER the whole-manifest parse + validation, so a corrupt manifest still refuses even
  # when a filter is given. An UNKNOWN requested name is a loud refusal, never a silent no-match:
  # a filtered-to-empty set must not satisfy the exit contract vacuously ("subset is down, exit 0"
  # while the agent still runs — the caller, e.g. remove-worktree, would then delete its worktree).
  if [ -n "${DOWN_FILTER:-}" ]; then
    local want kept="" have
    for want in $DOWN_FILTER; do
      have="$(printf '%s\n' "$rows" | cut -f1 | grep -qxF -- "$want" && echo 1 || echo 0)"
      if [ "$have" = 0 ]; then
        echo "fleet-layout down: '$want' is not in the manifest — refusing (nothing was killed for it)" >&2
        bad=1; continue
      fi
      kept="${kept}$(printf '%s\n' "$rows" | awk -F"$TAB" -v a="$want" '$1==a')
"
    done
    rows="$(printf '%s' "$kept" | sed '/^$/d')"
    # An unknown name TAINTS the run (bad=1, set above) but must NOT spare the agents that DID
    # match: `down a bogus` downs `a` and still exits non-zero. Refusing everything here would
    # make the run's own error message a lie ("nothing killed for it" — while also killing nothing
    # for the valid names) and would send the operator hunting the wrong agent. Only a filter that
    # matched NOTHING refuses outright — the empty-enumeration guard, which must never read as
    # "that agent is down".
    [ -n "$rows" ] || {
      echo "fleet-layout down: no requested agent is in the manifest — refusing (nothing was killed)." >&2
      return 1; }
  fi
  [ -d "$HOME/.claude/running-agents" ] || {
    echo "fleet-layout down: registry directory missing — cannot enumerate the fleet; refusing" >&2; return 1; }
  for f in "$HOME"/.claude/running-agents/*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    [ -f "$f" ] && [ -r "$f" ] || {
      echo "fleet-layout down: registry entry $f is not a readable file — refusing" >&2; return 1; }
  done
  tmux display-message -p '#{pid}' >/dev/null 2>&1 || {
    echo "fleet-layout down: tmux is not answering — refusing" >&2; return 1; }
  local all_panes
  all_panes="$(tmux list-panes -a -F "#{pane_id}${TAB}#{pane_current_path}" 2>/dev/null)"
  [ -n "$all_panes" ] || {
    echo "fleet-layout down: cannot enumerate the server pane list — refusing" >&2; return 1; }

  # Sidecar preflight: a LIVE registration we cannot place could be self or a target.
  local live_regs name pid token
  live_regs="$(_down_live_regs)"
  while IFS="$TAB" read -r name pid token; do
    [ -n "$name" ] || continue
    _reg_cwd "$name" >/dev/null || {
      echo "fleet-layout down: live registration '$name' has an unresolvable .cwd sidecar — cannot place it (could be self or a target); refusing" >&2
      return 1; }
  done <<EOF
$live_regs
EOF

  # Self: token equality is PRIMARY (name- and cwd-independent — transient names blind
  # the name check, and the invoker's toplevel diverges outside the worktree); the name
  # and toplevel checks are secondaries. Both unresolvable → refuse: an unidentifiable
  # self could be among the targets.
  local self_token toplevel self_name token_matches=0
  self_token="$(fleet_self_token)"
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$toplevel" ] && toplevel="$(_abs "$toplevel")"
  self_name="$(fleet_find_self "$HOME/.claude/running-agents" 2>/dev/null || true)"
  printf '%s\n' "$live_regs" | cut -f3 | grep -qxF -- "$self_token" && token_matches=1
  if [ "$token_matches" = 0 ] && [ -z "$toplevel" ]; then
    echo "fleet-layout down: cannot resolve self (no registration carries our token, no git toplevel) — refusing" >&2
    return 1
  fi

  # Snapshot attribution ONCE before the first kill: kills mutate live_agents, and a
  # rescan would make the same-cwd ambiguity rule order-dependent (panes owed to
  # NEITHER re-attribute to the survivor). Ambiguous cwds feed the probe's exemptions.
  _snapshot_attr
  FL_DOWN_AMB="$(live_agents | cut -f3 | sort | uniq -d)"

  # Canonical (agent-number) order, same rule as boot.
  local entries
  entries="$(printf '%s\n' "$rows" | while IFS="$TAB" read -r a act p; do
               num="$(printf '%s' "$a" | grep -oE '[0-9]+$' || true)"
               printf '%09d\t%s\t%s\t%s\n' "${num:-999999999}" "$a" "$act" "$p"
             done | sort -n | cut -f2-)"

  # ---- per-entry pass: match by path, gate, kill (companions first, claude last) ----
  # `active:false` does NOT exempt an entry: "stop all agents" means all; the flag
  # gates boot only.
  local agent active path apath m n tk acwd tpath comps c
  local entry_kills entry_names entry_tokens
  local summaries="" swept_paths=""
  while IFS="$TAB" read -r agent active path; do
    [ -n "$agent" ] || continue
    apath="$(_abs "$path")"
    if [ -n "$self_name" ] && [ "$agent" = "$self_name" ]; then
      # Explicitly REQUESTED self → refuse loudly. The silent skip is correct only for an
      # unrequested whole-fleet sweep; for a named request, exit 0 would tell the caller the
      # agent is down while it is the very process running this command.
      if [ -n "${DOWN_FILTER:-}" ]; then
        _down_report "$agent" "REFUSED (self — a run cannot down its own pane)"; bad=1; continue
      fi
      _down_report "$agent" "skipped (self)"; continue
    fi
    m=""
    if [ -n "$apath" ]; then
      m="$(printf '%s\n' "$live_regs" | while IFS="$TAB" read -r n _p2 tk; do
             [ -n "$n" ] || continue
             acwd="$(_reg_cwd "$n")" || continue
             [ "$acwd" = "$apath" ] && printf '%s\t%s\n' "$n" "$tk"
           done)"
    fi
    if [ -n "$m" ] && printf '%s\n' "$m" | cut -f2 | grep -qxF -- "$self_token"; then
      if [ -n "${DOWN_FILTER:-}" ]; then
        _down_report "$agent" "REFUSED (self — a run cannot down its own pane)"; bad=1; continue
      fi
      _down_report "$agent" "skipped (self)"; continue
    fi
    if [ -n "$toplevel" ] && [ -n "$apath" ] && [ "$apath" = "$toplevel" ]; then
      # The invoking pane stands in this worktree without a matching registration — the
      # safe direction is skip, but the summary must not read as fully down.
      _down_report "$agent" "skipped (invoking pane is in this worktree)"; bad=1; continue
    fi
    swept_paths="${swept_paths}${apath}
"
    if [ -z "$m" ]; then
      # No live registration: PROBE before trusting "not running" — a broken
      # registration chain must never convert a live agent into a silent exit 0.
      if [ -z "$apath" ]; then
        _down_report "$agent" "not running (worktree missing)"; continue
      fi
      local hits prc first
      hits="$(_down_probe_unsanctioned "$apath")"; prc=$?
      if [ "$prc" = 0 ]; then
        first="$(printf '%s\n' "$hits" | head -1)"
        _down_report "$agent" "UNACCOUNTED (pane ${first%%"$TAB"*} at this worktree, no live registration)"; bad=1
      elif [ "$prc" = 2 ]; then
        _down_report "$agent" "REFUSED (cannot enumerate panes to confirm 'not running')"; bad=1
      else
        _down_report "$agent" "not running"
      fi
      continue
    fi
    entry_kills=0; entry_names=""; entry_tokens=""
    while IFS="$TAB" read -r n tk; do
      [ -n "$n" ] || continue
      case "$tk" in
        %[0-9]*) : ;;
        *) _down_report "$agent" "headless (as $n; cwd token — no pane to kill)"; bad=1; continue ;;
      esac
      if [ "$FORCE" != 1 ] && _down_busy "$n"; then
        _down_report "$agent" "BUSY (mid-turn, as $n) — skipped; re-run with --force"; bad=1; continue
      fi
      # Corroborate the token before killing: it must resolve to a pane at this
      # worktree (boundary-aware). Registry and tmux contradicting each other is a
      # refusal, not a kill.
      # Two DIFFERENT failures hide behind one lookup, and only one of them is "no pane":
      #   (a) the token is absent from the snapshot   -> the pane is gone. Refuse.
      #   (b) the token IS in the snapshot but its path field is EMPTY -> tmux knows the pane
      #       exists and cannot yet say where it is. That is BLINDNESS, not absence — and it is
      #       routine: pane_current_path is not populated the instant a pane is created, and
      #       `list-panes` and `display-message` settle at different moments. Reading (b) as "no
      #       pane" made `down` REFUSE to kill live agents (the 12%-flaky suite rows were this,
      #       root-caused 2026-07-11: "token %62 resolves to 'no pane'" while %62 sat at the
      #       worktree in the very same pane dump).
      # So re-read the pane directly before concluding anything; only then refuse — still
      # fail-closed, but on evidence rather than on a race.
      tline="$(printf '%s\n' "$all_panes" | awk -F"$TAB" -v p="$tk" '$1==p{print; exit}')"
      if [ -z "$tline" ]; then
        _down_report "$agent" "REFUSED (token $tk resolves to no pane, as $n)"; bad=1; continue
      fi
      tpath="${tline#*"$TAB"}"
      [ -n "$tpath" ] || tpath="$(_pane_path_settled "$tk")"   # rc 1/2 both leave tpath empty ->
      tpath="$(_abs "$tpath")"                                  # the refusal below, which is right:
                                                                # a vanished or unplaceable pane is
                                                                # never a pane we may kill.
      case "$tpath" in
        "$apath"|"$apath"/*) : ;;
        *) _down_report "$agent" "REFUSED (token $tk resolves to '${tpath:-an unreadable location}', not this worktree, as $n)"; bad=1; continue ;;
      esac
      # Skip marker on the claude pane: a PRE-kill decision (the user's explicit
      # hands-off; --force never overrides it — removing the marker is the override).
      # An unreadable marker is UNKNOWN and fails CLOSED.
      case "$(_skip_state "$tk")" in
        marked)  _down_report "$agent" "skipped (claude pane is skip-marked, as $n)"; bad=1; continue ;;
        unknown) _down_report "$agent" "REFUSED (cannot read skip marker on $tk, as $n)"; bad=1; continue ;;
      esac
      # Companions first, claude last: the claude kill is the SessionEnd trigger. A
      # refused companion kill (e.g. the terminal self backstop) is reported and taints
      # the rc — the cell was not fully removed, and exit 0 must never claim it was.
      comps="$(_attr | awk -F"$TAB" -v a="$n" '$1==a{print $3; exit}')"
      for c in $comps; do
        if _down_kill_pane "$c"; then entry_kills=$((entry_kills+1))
        else _down_report "$agent" "REFUSED (companion $c not killed)"; bad=1; fi
      done
      if _down_kill_pane "$tk"; then
        entry_kills=$((entry_kills+1))
        entry_tokens="${entry_tokens:+$entry_tokens }$tk"
        entry_names="${entry_names:+$entry_names, }$n"
      else
        _down_report "$agent" "FAILED (kill errored on $tk, as $n)"; bad=1
      fi
    done <<EOF2
$m
EOF2
    [ -n "$entry_tokens" ] && summaries="${summaries}${agent}${TAB}${entry_names}${TAB}${entry_kills}${TAB}${entry_tokens}${TAB}${apath}
"
  done <<EOF
$entries
EOF

  # ---- settle: give SessionEnd a moment to unregister, then verify + sweep + probe ----
  local vagent vnames vcount vtoks vpath tk2 waited still
  if [ "$DRY_RUN" != 1 ] && [ -n "$summaries" ]; then
    waited=0
    while [ "$waited" -lt "$FLEET_DOWN_SETTLE" ]; do
      still=0
      while IFS="$TAB" read -r _va _vn _vc vtoks _vp; do
        [ -n "$vtoks" ] || continue
        for tk2 in $vtoks; do _down_verify_dead "$tk2" || still=1; done
      done <<EOF
$summaries
EOF
      [ "$still" = 0 ] && break
      sleep 1; waited=$((waited+1))
    done
  fi

  # Pid-only sweep of registry entries at targeted paths — the SIGHUP-path backstop for
  # SessionEnd. A live pid is never swept (and has already produced FAILED below).
  local sp
  while IFS= read -r sp; do
    [ -n "$sp" ] || continue
    _down_sweep_path "$sp"
  done <<EOF
$(printf '%s\n' "$swept_paths" | sort -u)
EOF

  # Verification + closing probe. Under --dry-run both are neutralized: nothing was
  # killed, so the observation would flag every target as FAILED.
  while IFS="$TAB" read -r vagent vnames vcount vtoks vpath; do
    [ -n "$vagent" ] || continue
    if [ "$DRY_RUN" = 1 ]; then
      if [ "$vnames" = "$vagent" ]; then _down_report "$vagent" "downed ($(_down_plural "$vcount")) [dry-run]"
      else _down_report "$vagent" "downed ($(_down_plural "$vcount"), as $vnames) [dry-run]"; fi
      continue
    fi
    local entry_fail=0 hits prc first
    for tk2 in $vtoks; do
      if ! _down_verify_dead "$tk2"; then
        _down_report "$vagent" "FAILED (pane $tk2 survived the kill)"; bad=1; entry_fail=1
      fi
    done
    if [ "$entry_fail" = 0 ]; then
      # This is the probe that earns the success claim: it looks for panes still ALIVE at the
      # worktree after the kills. rc 2 = we could not see. A blind probe must NEVER fall through to
      # "downed" + exit 0 — `remove-worktree` gates deleting the worktree on exactly that exit code,
      # so reading blindness as "nothing survived" would delete a worktree out from under a live
      # pane, which is the failure the down-first discipline exists to prevent. The pre-kill probe
      # above already fails closed on rc 2; this one has to as well.
      hits="$(_down_probe_unsanctioned "$vpath")"; prc=$?
      if [ "$prc" = 0 ]; then
        first="$(printf '%s\n' "$hits" | head -1)"
        _down_report "$vagent" "UNACCOUNTED (pane ${first%%"$TAB"*} survived at this worktree)"; bad=1; entry_fail=1
      elif [ "$prc" = 2 ]; then
        _down_report "$vagent" "REFUSED (cannot enumerate panes to confirm nothing survived — NOT claiming this agent is down)"; bad=1; entry_fail=1
      fi
    fi
    if [ "$entry_fail" = 0 ]; then
      if [ "$vnames" = "$vagent" ]; then _down_report "$vagent" "downed ($(_down_plural "$vcount"))"
      else _down_report "$vagent" "downed ($(_down_plural "$vcount"), as $vnames)"; fi
    fi
  done <<EOF
$summaries
EOF

  if [ "$bad" = 0 ]; then
    if [ -n "${DOWN_FILTER:-}" ]; then
      echo "fleet down: every REQUESTED agent (${DOWN_FILTER# }) is downed-and-verified or not running."
    else
      echo "fleet down: every non-self entry is downed-and-verified or not running."
    fi
  else
    echo "fleet down: NOT fully down — see the report above." >&2
  fi
  return "$bad"
}

_down_plural() { if [ "$1" = 1 ]; then printf '1 pane'; else printf '%s panes' "$1"; fi; }

# rm DEAD-pid registry entries whose sidecar resolves to <path>. Pid-only, same
# discipline as boot's sweep: sweeping a live pid is the riskier error.
_down_sweep_path() {
  local f base pid name acwd
  for f in "$HOME"/.claude/running-agents/*; do
    [ -f "$f" ] || continue
    base="${f##*/}"; pid="${base##*.}"; name="${base%.*}"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null && continue
    acwd="$(_reg_cwd "$name")" || continue
    [ "$acwd" = "$1" ] || continue
    if [ "$DRY_RUN" = 1 ]; then echo "(dry-run) would sweep dead registry entry $base"
    else rm -f "$f"; fi
  done
}

# ---------------------------------------------------------------------------- main

[ -n "${FLEET_LAYOUT_LIB:-}" ] && return 0

USAGE="usage: fleet-layout.sh <single|dual|wide|attach|balance|name-windows|boot|down> [--dry-run] [--force] [--label-only (name-windows)] [agent...  (down only)]"
verb=""
DOWN_FILTER=""          # space-separated agent names; empty = whole fleet (today's behavior)
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --force)   FORCE=1 ;;
    --label-only) FL_LABEL_ONLY=1 ;;   # name-windows: relabel only, skip _order_windows (settle-recheck)
    single|dual|wide|attach|balance|name-windows|boot|down)
      # A bare verb word AFTER the verb is an agent name for `down` (an agent may legitimately
      # be named e.g. `test`), so only the FIRST verb-shaped arg is the verb.
      if [ -z "$verb" ]; then verb="$arg"; else DOWN_FILTER="$DOWN_FILTER $arg"; fi ;;
    -*) echo "$USAGE" >&2; exit 2 ;;
    *) DOWN_FILTER="$DOWN_FILTER $arg" ;;
  esac
done
[ -n "$verb" ] || { echo "$USAGE" >&2; exit 2; }
[ "$FORCE" = 1 ] && [ "$verb" != down ] && { echo "fleet-layout: --force applies to down only" >&2; exit 2; }
# Agent names are accepted by `down` alone — a stray word anywhere else is a usage error, never
# a silently-ignored argument.
if [ -n "$DOWN_FILTER" ] && [ "$verb" != down ]; then
  echo "fleet-layout: agent names apply to \`down\` only (got:$DOWN_FILTER)" >&2; exit 2
fi
# Validate BEFORE anything touches the filesystem or tmux — same rule boot applies to manifest
# names (the name feeds greps and reports).
for _n in $DOWN_FILTER; do
  case "$_n" in
    *[!A-Za-z0-9_-]*) echo "fleet-layout down: invalid agent name '$_n' (allowed: A-Za-z0-9_-)" >&2; exit 2 ;;
  esac
done

# The soft exit 0 is right for the layout verbs (nothing to restructure) and a FAIL-OPEN
# for down: "nothing to do, exit 0" outside tmux would read to a crash-recovering
# operator as "fleet is down" while every agent still runs (DX-jn-cc-010).
if ! fleet_tmux_ok; then
  if [ "$verb" = down ]; then
    echo "fleet-layout down: not inside tmux — cannot enumerate or kill fleet panes; refusing (this does NOT mean the fleet is down)" >&2
    exit 2
  fi
  # boot is a SPIN-UP verb an init flow depends on: "nothing to do, exit 0" outside tmux would
  # read to base-initialize (or a crash-recovering operator) as "the fleet is up" while zero
  # agents launched — the boot-side cousin of down's vacuous-success failure. The cosmetic
  # layout verbs keep exit 0 (restructuring nothing IS a valid no-op for them).
  if [ "$verb" = boot ]; then
    echo "fleet-layout boot: not inside tmux — cannot create windows or launch agents; refusing (this does NOT mean the fleet is up)" >&2
    exit 2
  fi
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
  single)       layout_single ;;
  dual)         layout_dual ;;
  wide)         layout_wide ;;
  attach)       attach_external ;;
  boot)         boot_fleet ;;
  down)         down_fleet ;;
esac
