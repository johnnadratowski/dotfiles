#!/bin/bash
# Register / re-sync this Claude session in ~/.claude/running-agents.
#
# Idempotent: safe to call from SessionStart and as a self-heal prelude
# from agent-send.sh / agent-rename.sh. All paths converge on the same
# end state.
#
# Registry: ~/.claude/running-agents/<name>.<claude_pid>  (content: $TMUX_PANE)
# Name:     current git branch (sanitized), fallback to cwd basename.
#
# On SessionStart it also injects agent-type-specific startup instructions
# (the "role context") via additionalContext — see "Role context" below.
#
# Usage:
#   register-agent.sh sessionstart      — full setup; role context; schedules settle-recheck
#   register-agent.sh send-selfheal     — quiet re-sync; no role context, no /rename
#   register-agent.sh rename-selfheal   — quiet re-sync; no role context, no /rename
#   register-agent.sh settle-recheck    — delayed self-invocation (DX-jn-cc-006): after the
#                                         session's real name has settled, re-register if a
#                                         user-set name won the boot race, or type the
#                                         /rename fallback (fresh startups only). Identity
#                                         arrives via REGISTER_AGENT_* env, fail-closed.

set -u

LOG="$HOME/.claude/debug/register-agent.log"
mkdir -p "$(dirname "$LOG")"

# Drain hook stdin and capture for session_id extraction + diagnostic log.
stdin_payload=$(cat 2>/dev/null || true)

source="${1:-sessionstart}"
ts=$(date '+%Y-%m-%d %H:%M:%S')

log() {
  printf '%s [%s] %s\n' "$ts" "$source" "$*" >> "$LOG"
}

log "fired. TMUX_PANE=${TMUX_PANE:-(unset)} cwd=$PWD payload_bytes=${#stdin_payload}"

# --- Fleet self-heal: core.bare must stay false on the shared repo (DX-jn-cc-021) ----------
# The Agent-tool isolation:worktree lifecycle can flip core.bare=TRUE on the shared common
# config. It is ALWAYS wrong here (the main clone is a normal, non-bare checkout) and it breaks
# every work-tree op in the MAIN worktree (linked worktrees are unaffected). Re-assert false
# whenever it is true — idempotent + cheap, and it works even while broken (rev-parse / config -f
# need no work tree). Runs on every invocation (sessionstart + the frequent send/rename
# self-heals), so a mid-session flip heals within a turn or two. Source is harness-side; see
# DX-jn-cc-021. Guarded to a genuine flip so it never writes in normal operation.
_common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
# SCOPE to a NON-bare clone (git-dir is "<worktree>/.git"): there `core.bare=true` is always the
# bug. A genuinely BARE repo (git-dir does NOT end in /.git) legitimately carries core.bare=true —
# never touch it. This hook is synced to other projects via update-workflow, so it must self-scope.
case "$_common_dir" in
  */.git)
    if [ -f "$_common_dir/config" ] && [ "$(git config -f "$_common_dir/config" --get core.bare 2>/dev/null)" = "true" ]; then
      git config -f "$_common_dir/config" core.bare false 2>/dev/null \
        && log "self-heal: reset core.bare=false on shared config (was true — DX-jn-cc-021)"
    fi ;;
esac

# tmux is OPTIONAL (DX-jn-8-019): without it we still register, keyed by a
# cwd-based identity token (see _fleet.sh). Only the tmux cosmetics (pane/window
# title, /rename keystroke) below are skipped when tmux is unavailable.

# --- Resolve the claude PID ---
# Strategy (most -> least reliable):
#   1. Parse session_id from hook stdin JSON, then look up the matching
#      ~/.claude/sessions/<pid>.json — pid is authoritative because Claude
#      Code itself writes those files. Verify the candidate PID is still
#      alive and is actually a claude process (session files accumulate
#      across runs, so blind trust gives stale PIDs).
#   2. Walk the process tree from $$ upward; find nearest ancestor whose
#      command starts with `claude`.
#   3. Last-ditch: $PPID (unreliable because Claude Code wraps hooks in
#      an intermediate shell).
claude_pid=""

session_id=""
session_source=""
if [ -n "$stdin_payload" ] && command -v jq >/dev/null 2>&1; then
  session_id=$(printf '%s' "$stdin_payload" | jq -r '.session_id // empty' 2>/dev/null)
  # startup | resume | clear | compact — drives the settle verb's keystroke rule.
  session_source=$(printf '%s' "$stdin_payload" | jq -r '.source // empty' 2>/dev/null)
fi
# settle-recheck gets its pid via REGISTER_AGENT_PID (validated in the verb) —
# running the ladder here would just burn a tree walk and stamp a misleading
# "via PPID fallback (probably wrong)" line into the log on every settle.
if [ -n "$session_id" ] && [ "$source" != "settle-recheck" ]; then
  for f in "$HOME/.claude/sessions/"*.json; do
    [ -f "$f" ] || continue
    if grep -q "\"sessionId\":\"$session_id\"" "$f" 2>/dev/null; then
      candidate=$(basename "$f" .json)
      if kill -0 "$candidate" 2>/dev/null && \
         ps -p "$candidate" -o command= 2>/dev/null | grep -qE '(^|/)claude( |$)'; then
        claude_pid="$candidate"
        log "pid=$claude_pid via session_id=$session_id"
        break
      else
        log "skipping stale session file $f (pid $candidate not a live claude)"
      fi
    fi
  done
fi

if [ -z "$claude_pid" ] && [ "$source" != "settle-recheck" ]; then
  pid=$$
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! read -r ppid cmd < <(ps -p "$pid" -o ppid=,command= 2>/dev/null); then
      break
    fi
    [ -z "${ppid:-}" ] && break
    if printf '%s' "$cmd" | grep -qE '(^|/)claude( |$)'; then
      claude_pid="$pid"
      log "pid=$claude_pid via process-tree walk"
      break
    fi
    pid="$ppid"
  done
fi

if [ -z "$claude_pid" ] && [ "$source" != "settle-recheck" ]; then
  claude_pid="$PPID"
  log "pid=$claude_pid via PPID fallback (probably wrong)"
fi

# --- Load per-project workflow config ---
# Defines optional WORKFLOW_AGENT_* knobs:
#   WORKFLOW_AGENT_DEFAULT_BRANCH   — pins agent name + base branch in config
#   WORKFLOW_AGENT_NAME_PREFIX      — prepended to derived name
#   WORKFLOW_AGENT_NAME_TRANSFORM   — sed expr applied to derived name
#   WORKFLOW_AGENT_SKIP_BRANCH_WARN — set to "1" to suppress mismatch warning
#   WORKFLOW_AGENT_SETTLE_SECONDS   — delay before the settle-recheck fires (default 4)
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# _config.sh and agent-roles/ are PROJECT content and stay in the consuming repo, so
# resolve them from the REPO ROOT -- never relative to this script. Once this hook lives in
# ~/.claude/hooks (fleet machinery, symlinked from dotfiles), a script-relative path would
# point at ~/.claude/scripts/_config.sh and ~/.claude/agent-roles/, neither of which exists.
# Same resolution unregister-agent.sh already uses.
_repo_root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD")}"
config_loader="$_repo_root/.claude/scripts/_config.sh"
[ -r "$config_loader" ] || config_loader="${script_dir%/hooks}/scripts/_config.sh"
if [ -r "$config_loader" ]; then
  # shellcheck disable=SC1090
  . "$config_loader"
fi
# Home first (canonical, symlinked from dotfiles), then the repo sibling.
fleet_helper="$HOME/.claude/scripts/_fleet.sh"
[ -r "$fleet_helper" ] || fleet_helper="${script_dir%/hooks}/scripts/_fleet.sh"
# shellcheck disable=SC1090
[ -r "$fleet_helper" ] && . "$fleet_helper"
# Identity token: $TMUX_PANE inside tmux, else cwd-based (works headless).
self_token="$(fleet_self_token 2>/dev/null || printf '%s' "${TMUX_PANE:-cwd:$PWD}")"

# The one sanitizer every name in this script must pass through (no dots — dots
# are field delimiters in the mailbox filenames).
_sanitize() { tr -c 'A-Za-z0-9_-' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//'; }

# DX-jn-cc-006: Claude Code's TRANSIENT session auto-name is <cwd-basename>-<2hex>.
# On `claude --continue` that is what the session file holds when SessionStart
# fires — the resumed session's real name lands ~2s later. The pattern is
# therefore RESERVED: a session name matching it is never trusted as the agent
# name (a genuine user name matching it gets branch-derived registration — the
# documented limitation).
_is_transient_name() { # $1 = sanitized candidate
  local _cb; _cb="$(basename "$PWD" | _sanitize)"
  case "$1" in
    "$_cb"-[0-9a-f][0-9a-f]) return 0 ;;
  esac
  return 1
}

# THE name pipeline: transform -> sanitize -> prefix (with the double-application
# guard). Boot-time resolution AND the settle-recheck swap must both route
# through this — two resolvers for one identity that normalize differently
# oscillate the registry/mailbox/sidecar identity on every restart.
_normalize_name() { # stdin: raw candidate -> stdout: normalized name
  local n prefix
  n="$(cat)"
  # Transform BEFORE sanitization, so user patterns can match the raw branch
  # (e.g. "s|^feature/||").
  if [ -n "${WORKFLOW_AGENT_NAME_TRANSFORM:-}" ]; then
    n=$(printf '%s' "$n" | sed -E "$WORKFLOW_AGENT_NAME_TRANSFORM")
    log "applied transform: $n"
  fi
  # Sanitize: alnum/dash/underscore only. (No dots — dots are field delimiters
  # in the message-mailbox filenames; a dot would break drain parsing.)
  n=$(printf '%s' "$n" | _sanitize)
  # Prefix (sanitized WITHOUT edge-trim — a trailing dash like "wf-" is the
  # point). Guard against double-application: a name already carrying the
  # prefix (set by /rename, re-derived on `claude --continue`) must NOT become
  # <prefix><prefix>name, which forks a duplicate registry identity.
  if [ -n "${WORKFLOW_AGENT_NAME_PREFIX:-}" ]; then
    prefix=$(printf '%s' "$WORKFLOW_AGENT_NAME_PREFIX" | tr -c 'A-Za-z0-9_-' '-' | sed -E 's/-+/-/g')
    case "$n" in
      "$prefix"*) log "prefix already present, not re-applying: $n" ;;
      *) n="${prefix}${n}"; log "applied prefix: $n" ;;
    esac
  fi
  # Floor: a transform can reduce the name to sanitize-empty. The floor lives
  # IN the pipeline (post-prefix, byte-identical to the old boot-side fallback)
  # so every resolver shares it — an empty name reaching a mutation path writes
  # a hidden '.{pid}' registry file that fleet_find_self's glob can't see.
  if [ -z "$n" ]; then
    n="agent"
    log "name normalized to empty — floored to 'agent'"
  fi
  printf '%s' "$n"
}

# --- Settle re-check (DX-jn-cc-006) ---
# Scheduled by sessionstart (schedule_settle below). By the time this fires the
# session's REAL name has had time to land; if a user-set name won the boot
# race, re-register under it — the registry follows the session, never the
# reverse. Identity arrives via env: this runs from a detached background job
# (parent isn't claude, hook stdin is gone).
if [ "$source" = "settle-recheck" ]; then
  spid="${REGISTER_AGENT_PID:-}"
  boot_name="${REGISTER_AGENT_BOOT_NAME:-}"
  sess_file="$HOME/.claude/sessions/$spid.json"
  # FAIL-CLOSED on every input's failure value: a stale job from a
  # killed-and-relaunched session would otherwise act for a dead pid — and the
  # token-match prune below would DELETE the successor session's fresh registry
  # entry. Any doubt → exit with ZERO mutation.
  if [ -z "$spid" ] || ! kill -0 "$spid" 2>/dev/null \
     || ! ps -p "$spid" -o command= 2>/dev/null | grep -qE '(^|/)claude( |$)'; then
    log "settle: pid '${spid:-}' is not a live claude — fail-closed, no mutation"
    exit 0
  fi
  if [ -z "$boot_name" ] || [ "$(printf '%s' "$boot_name" | _sanitize)" != "$boot_name" ]; then
    log "settle: boot name '$boot_name' empty/unsanitized — fail-closed, no mutation"
    exit 0
  fi
  if [ ! -r "$sess_file" ] || ! command -v jq >/dev/null 2>&1; then
    log "settle: session file unreadable ($sess_file) — fail-closed, no mutation"
    exit 0
  fi

  # Transient check on the plain-sanitized name (mirroring the boot-side guard),
  # then the SAME normalization pipeline boot used — fed the RAW session name,
  # exactly as boot feeds it: the transform runs before sanitization by design
  # (patterns match the raw string, e.g. "s|^feature/||"), so normalizing a
  # pre-sanitized form makes the transform miss and boot/settle resolve one
  # session to two identities, oscillating on every restart.
  settled_json="$(jq -r '.name // empty' "$sess_file" 2>/dev/null)"
  settled_raw="$(printf '%s' "$settled_json" | _sanitize)"
  settled="$settled_raw"
  if [ -n "$settled_raw" ] && ! _is_transient_name "$settled_raw"; then
    settled="$(printf '%s' "$settled_json" | _normalize_name)"
  fi

  if [ -n "$settled_raw" ] && ! _is_transient_name "$settled_raw" && [ "$settled" != "$boot_name" ]; then
    # A real (user-set) name won — swap the whole identity to it.
    mkdir -p "$HOME/.claude/running-agents" "$HOME/.claude/agents"
    for _stale in "$HOME/.claude/running-agents"/*; do
      [ -f "$_stale" ] || continue
      [ "$(cat "$_stale" 2>/dev/null)" = "$self_token" ] && rm -f "$_stale"
    done
    rm -f "$HOME/.claude/running-agents/$settled".*
    printf '%s\n' "$self_token" > "$HOME/.claude/running-agents/$settled.$spid"
    printf '%s\n' "$PWD" > "$HOME/.claude/agents/$settled.cwd"
    [ -n "${REGISTER_AGENT_TRANSCRIPT:-}" ] \
      && printf '%s\n' "$REGISTER_AGENT_TRANSCRIPT" > "$HOME/.claude/agents/$settled.transcript"
    if [ ! -f "$HOME/.claude/agents/$settled" ]; then
      # No prior user state under this name — record the current branch as base.
      _cb_now="$(git -C "$PWD" branch --show-current 2>/dev/null | _sanitize)"
      [ -n "$_cb_now" ] && printf '%s\n' "$_cb_now" > "$HOME/.claude/agents/$settled"
    fi
    # Retire the boot name's sidecars written this boot — unless another live
    # registration (foreign token) legitimately owns that name.
    boot_foreign=0
    for _e in "$HOME/.claude/running-agents/$boot_name".*; do
      [ -f "$_e" ] || continue
      [ "$(cat "$_e" 2>/dev/null)" = "$self_token" ] || boot_foreign=1
    done
    if [ "$boot_foreign" = 0 ]; then
      rm -f "$HOME/.claude/agents/$boot_name" \
            "$HOME/.claude/agents/$boot_name.cwd" \
            "$HOME/.claude/agents/$boot_name.transcript"
    fi
    log "settle: session name settled to '$settled' — re-registered from '$boot_name'"
    if fleet_tmux_ok 2>/dev/null; then
      tmux select-pane -t "$TMUX_PANE" -T "$settled" 2>/dev/null || true
      layout_sh="$HOME/.claude/scripts/fleet-layout.sh"; [ -x "$layout_sh" ] || layout_sh="${script_dir%/hooks}/scripts/fleet-layout.sh"
      [ -x "$layout_sh" ] && "$layout_sh" name-windows --label-only >/dev/null 2>&1
    fi
  elif [ -z "$settled_raw" ] || _is_transient_name "$settled_raw"; then
    # Still transient/empty. Keystroke rule by session source: a RESUME buffers
    # keystrokes until AFTER initialization, so typing /rename now could land ON
    # TOP of a late-arriving user name — the clobber this verb exists to prevent.
    # Only a fresh startup (whose auto-name never settles on its own) gets the
    # keystroke; launching with `claude --name` makes this fallback a no-op, since
    # the name is then already settled when we get here (DX-jn-8-024).
    src_kind="${REGISTER_AGENT_SESSION_SOURCE:-}"
    # `clear` belongs here alongside `startup`. /clear begins a BRAND-NEW, unnamed
    # session inside the SAME claude process, so the launch-time `--name` — which
    # names only the first session — no longer applies and the auto-name never
    # settles. The clobber risk that excludes `resume` does not apply: /clear is not
    # replaying buffered keystrokes over a late-arriving user name.
    #
    # NOTE: for `clear` this branch is usually unreachable, and the fix is elsewhere.
    # The `settled_raw` we tested above comes from ~/.claude/sessions/<pid>.json, which
    # is keyed by PID — and /clear makes a new session in the SAME process, so that file
    # still holds the OLD name. It reads as settled, the `elif` above never fires, and
    # nothing renames the genuinely-unnamed new session. Run `fleet-clear.sh` in the
    # pane to fix a cleared agent's name; it reads the registry, which is accurate.
    if [ "$src_kind" = "startup" ] || [ "$src_kind" = "clear" ]; then
      # There used to be a WORKFLOW_AGENT_SKIP_RENAME opt-out here, a launch-time guard
      # against the startup modal eating the keystroke. It was redundant — `claude --name`
      # settles the name so this fallback is never reached — and actively harmful, because
      # it rides in the process environment and so outlived the startup it was scoped to,
      # suppressing the fallback on every later /clear in that pane. It needed its own
      # special case to undo itself. Removed; `--name` is the whole mechanism now.
      if fleet_tmux_ok 2>/dev/null && [ "$settled" != "$boot_name" ]; then
        tmux send-keys -t "$TMUX_PANE" -l "/rename $boot_name" 2>/dev/null
        tmux send-keys -t "$TMUX_PANE" Enter 2>/dev/null
        log "settle: typed /rename $boot_name ($src_kind, name never settled)"
      else
        log "settle: keystroke skipped ($src_kind: no tmux, or already named)"
      fi
    elif [ "${REGISTER_AGENT_SETTLE_RETRY:-}" != "1" ]; then
      # One bounded retry — the name may just be slow to land under load.
      settle_secs="${WORKFLOW_AGENT_SETTLE_SECONDS:-4}"
      hook_self="$script_dir/$(basename "${BASH_SOURCE[0]}")"
      nohup env REGISTER_AGENT_PID="$spid" REGISTER_AGENT_BOOT_NAME="$boot_name" \
        REGISTER_AGENT_TRANSCRIPT="${REGISTER_AGENT_TRANSCRIPT:-}" \
        REGISTER_AGENT_SESSION_SOURCE="$src_kind" REGISTER_AGENT_SETTLE_RETRY=1 \
        TMUX_PANE="${TMUX_PANE:-}" \
        bash -c "sleep $(printf %q "$settle_secs"); exec bash $(printf %q "$hook_self") settle-recheck" \
        </dev/null >/dev/null 2>&1 &
      log "settle: still transient on '$src_kind' — one retry scheduled (+${settle_secs}s)"
    else
      log "settle: still transient after retry on '$src_kind' — keystroke skipped (never clobber a late name)"
    fi
  else
    log "settle: settled name matches boot name '$boot_name' — no-op"
  fi
  # DX-jn-cc-018: ALWAYS re-assert window LABELS from the REGISTRY before exiting. The registry
  # already holds the correct (often branch-derived) name, but a `claude --continue` resume stamps
  # the window with the TRANSIENT auto-name ~2s AFTER SessionStart's name-windows ran. Branch 2
  # above (the common branch-derived-name-on-resume case) and the SessionStart fast path both skip
  # name-windows, so the window stuck on the transient label. name-windows derives from the
  # registry, NOT the session name, so this converges the window regardless of settle state.
  # Idempotent + cheap; runs at the settle tick (+~4s) and its one retry (+~8s), after the clobber.
  # Reached from all three settle branches (Branch 1/2/3 above all fall through here). The
  # earlier fail-closed guards deliberately skip it — an orphaned settle job (dead pid /
  # corrupt inputs) must not mutate tmux, and the live successor's own settle job re-asserts.
  # --label-only: this runs on a possibly-HALF-SETTLED registry (cc itself may be mid-restart),
  # and reordering from that snapshot demoted cc to last — so relabel only; leave window ORDER
  # to the boot-time name-windows, which runs when the registry is whole.
  if fleet_tmux_ok 2>/dev/null; then
    _settle_lw="$HOME/.claude/scripts/fleet-layout.sh"; [ -x "$_settle_lw" ] || _settle_lw="${script_dir%/hooks}/scripts/fleet-layout.sh"
    if [ -x "$_settle_lw" ]; then
      if "$_settle_lw" name-windows --label-only >/dev/null 2>&1; then
        log "settle: re-asserted window labels via name-windows (DX-jn-cc-018)"
      else
        log "settle: name-windows re-assert failed, non-fatal (DX-jn-cc-018)"
      fi
    fi
  fi
  exit 0
fi

# --- Determine agent name ---
# Priority:
#   1. Session file's `name` field (set by `/rename`; persists across resumes).
#   2. WORKFLOW_AGENT_DEFAULT_BRANCH from .claude/workflow.config (if set).
#   3. Current git branch (sanitized).
#   4. cwd basename.
name=""
session_name=""
if [ -n "$claude_pid" ] && [ -f "$HOME/.claude/sessions/$claude_pid.json" ] && command -v jq >/dev/null 2>&1; then
  session_name=$(jq -r '.name // empty' "$HOME/.claude/sessions/$claude_pid.json" 2>/dev/null)
  # DX-jn-cc-006: never trust a transient auto-name here — on `claude --continue`
  # it's what the file holds until the real name lands (~2s after this hook).
  # Fall through to config/branch; the settle-recheck converges any late name.
  if [ -n "$session_name" ] && _is_transient_name "$(printf '%s' "$session_name" | _sanitize)"; then
    log "session name '$session_name' matches the transient auto-name pattern — treating as absent"
    session_name=""
  fi
  name="$session_name"
fi
if [ -z "$name" ] && [ -n "${WORKFLOW_AGENT_DEFAULT_BRANCH:-}" ]; then
  name="$WORKFLOW_AGENT_DEFAULT_BRANCH"
  log "using WORKFLOW_AGENT_DEFAULT_BRANCH=$name"
fi
current_branch=$(git -C "$PWD" branch --show-current 2>/dev/null)
if [ -z "$name" ] && [ -n "$current_branch" ]; then
  name="$current_branch"
fi
[ -z "$name" ] && name="$(basename "$PWD")"

# Transform + sanitize + prefix + empty-floor — the same pipeline the
# settle-recheck swap uses, so boot and settle can never disagree on the same
# input (the floor included: pipeline output is never empty).
name=$(printf '%s' "$name" | _normalize_name)

# Sanitize current_branch the same way for consistent comparison.
current_branch_sanitized=$(printf '%s' "$current_branch" | _sanitize)

# --- Role context (injected at SessionStart via additionalContext) ---
# Different agent types get tailored startup instructions. The role is derived
# from the agent name; override per-agent with ~/.claude/agents/<name>.role (a
# single word). Role docs live in .claude/agent-roles/<role>.md and ship with
# the repo (so they propagate via merge-down). Only loaded on sessionstart.
# Delegates to fleet_resolve_role() in scripts/_fleet.sh (sourced above) — the single
# source of the name→role patterns, shared with agent-fanout.sh's role_of().
resolve_role() { fleet_resolve_role "$1"; }
role_context=""
if [ "$source" = "sessionstart" ]; then
  role=""
  [ -f "$HOME/.claude/agents/$name.role" ] && role="$(tr -dc 'A-Za-z0-9_-' < "$HOME/.claude/agents/$name.role")"
  [ -z "$role" ] && role="$(resolve_role "$name")"
  # Repo-rooted, not script-relative -- see the note at config_loader above.
  _rr="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD")}"
  role_file="$_rr/.claude/agent-roles/$role.md"
  [ -r "$role_file" ] || role_file="$(cd "$(dirname "$0")/../agent-roles" 2>/dev/null && pwd)/$role.md"
  if [ -f "$role_file" ]; then
    role_context="$(cat "$role_file")"
    log "loaded role context: role=$role file=$role_file"
    # Project overlay: a repo may customize the generic base role with project-specific
    # content at .claude/project/roles/<role>.md — appended when present, absent ⇒ just the
    # generic base (so the same engine role works in any repo). The base ships with the
    # engine (resolved via $0); the overlay lives in the current worktree (repo root).
    _proj_root="$(git rev-parse --show-toplevel 2>/dev/null)"
    role_overlay="${_proj_root:+$_proj_root/.claude/project/roles/$role.md}"
    if [ -n "$role_overlay" ] && [ -f "$role_overlay" ]; then
      role_context="$role_context

$(cat "$role_overlay")"
      log "appended project role overlay: $role_overlay"
    fi
  else
    log "no role file for role=$role ($role_file)"
  fi
  # Base-branch alias: tell the model the configured base branch's NAME, so a
  # user saying "merge <branch>" / "push <branch>" routes to the base-* skills
  # even though the skills are branch-name-agnostic. Config-derived — renaming
  # the base branch never requires a prose edit.
  if [ -n "${WORKFLOW_BASE_BRANCH:-}" ]; then
    base_alias_note="This project's configured base branch is \`$WORKFLOW_BASE_BRANCH\` (WORKFLOW_BASE_BRANCH in .claude/workflow.config). When the user names it — \"merge $WORKFLOW_BASE_BRANCH\", \"push $WORKFLOW_BASE_BRANCH\", \"review $WORKFLOW_BASE_BRANCH\", \"test $WORKFLOW_BASE_BRANCH\" — they mean /base-merge, /base-push, /base-pr, /base-test against that branch."
    if [ -n "$role_context" ]; then
      role_context="$role_context

$base_alias_note"
    else
      role_context="$base_alias_note"
    fi
  fi
fi

log "name=$name current_branch=$current_branch"

# --- Base-branch tracking ---
# Persistent per-agent metadata at ~/.claude/agents/<name>; survives
# SessionEnd. Records the branch the agent was last registered with so
# the next SessionStart can warn if the worktree drifts to another branch.
#
# If WORKFLOW_AGENT_DEFAULT_BRANCH is set in the project config, that
# config IS the source of truth — we force-write it as the recorded
# base and the mismatch warning fires when the worktree isn't on it.
mkdir -p "$HOME/.claude/agents"
base_branch_file="$HOME/.claude/agents/$name"
mismatch_warning=""

# Sanitize the intended (config-pinned) base too, so comparisons match.
intended_base=""
if [ -n "${WORKFLOW_AGENT_DEFAULT_BRANCH:-}" ]; then
  intended_base=$(printf '%s' "$WORKFLOW_AGENT_DEFAULT_BRANCH" | _sanitize)
fi

if [ -n "$intended_base" ]; then
  # Config-pinned: always force-write the recorded base.
  printf '%s\n' "$intended_base" > "$base_branch_file"
  recorded_base="$intended_base"
  log "pinned base branch from config: $recorded_base"
elif [ -f "$base_branch_file" ]; then
  recorded_base=$(cat "$base_branch_file" 2>/dev/null)
else
  # First registration with no config pin: record current branch.
  if [ -n "$current_branch_sanitized" ]; then
    printf '%s\n' "$current_branch_sanitized" > "$base_branch_file"
    log "recorded base branch: $current_branch_sanitized"
  fi
  recorded_base="$current_branch_sanitized"
fi

if [ "${WORKFLOW_AGENT_SKIP_BRANCH_WARN:-}" != "1" ] \
   && [ -n "$recorded_base" ] \
   && [ -n "$current_branch_sanitized" ] \
   && [ "$recorded_base" != "$current_branch_sanitized" ]; then
  mismatch_warning="Agent '$name' was registered with base branch '$recorded_base' but the worktree is currently on '$current_branch'. If this is unintentional, switch back with: git checkout $recorded_base"
  log "BRANCH MISMATCH: registered=$recorded_base current=$current_branch_sanitized"
fi

# --- Context-lookup anchors (DX-jn-8-018) ---
# Record the agent's cwd and live transcript path so tools (e.g. agent-fanout
# `status`/`compact`) can find this agent's session transcript WITHOUT tmux. cwd
# derives the project dir (~/.claude/projects/<cwd|nonalnum→->); transcript_path
# (from the SessionStart payload) is the direct, heuristic-free pointer. Both are
# refreshed every SessionStart (incl. `--continue`).
printf '%s\n' "$PWD" > "$HOME/.claude/agents/$name.cwd"
transcript_path=$(printf '%s' "$stdin_payload" | jq -r '.transcript_path // empty' 2>/dev/null)
if [ -n "$transcript_path" ]; then
  printf '%s\n' "$transcript_path" > "$HOME/.claude/agents/$name.transcript"
  log "recorded cwd=$PWD transcript=$transcript_path"
else
  log "recorded cwd=$PWD (no transcript_path in payload)"
fi

mkdir -p "$HOME/.claude/running-agents"
target="$HOME/.claude/running-agents/$name.$claude_pid"

# Helper: emit Claude Code's SessionStart additionalContext JSON to stdout.
# Combines the role context (loaded above) with any per-call warning so both
# reach the model in one SessionStart additionalContext payload.
emit_session_context() {
  local msg="$1"
  local combined="${role_context:-}"
  if [ -n "$msg" ]; then
    if [ -n "$combined" ]; then
      combined="$combined

$msg"
    else
      combined="$msg"
    fi
  fi
  if [ "$source" = "sessionstart" ] && [ -n "$combined" ]; then
    if command -v jq >/dev/null 2>&1; then
      jq -n --arg ctx "$combined" '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":$ctx}}'
    else
      esc=${combined//\\/\\\\}; esc=${esc//\"/\\\"}; esc=${esc//$'\n'/\\n}
      printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$esc"
    fi
    log "emitted SessionStart additionalContext"
  fi
}

# DX-jn-cc-006: schedule the delayed settle re-check (the verb near the top).
# Runs on EVERY sessionstart — fast and slow path, tmux or headless (the
# registry correction matters without tmux too; the keystroke fallback
# suppresses only the keystroke inside the verb). The resumed session's real
# name lands ~2s after this hook fires; the verb re-registers if a user-set
# name won, or types the /rename fallback (fresh startups only).
schedule_settle() {
  [ "$source" = "sessionstart" ] || return 0
  local settle_secs hook_self
  settle_secs="${WORKFLOW_AGENT_SETTLE_SECONDS:-4}"
  hook_self="$script_dir/$(basename "${BASH_SOURCE[0]}")"
  nohup env REGISTER_AGENT_PID="$claude_pid" REGISTER_AGENT_BOOT_NAME="$name" \
    REGISTER_AGENT_TRANSCRIPT="${transcript_path:-}" \
    REGISTER_AGENT_SESSION_SOURCE="${session_source:-}" \
    TMUX_PANE="${TMUX_PANE:-}" \
    bash -c "sleep $(printf %q "$settle_secs"); exec bash $(printf %q "$hook_self") settle-recheck" \
    </dev/null >/dev/null 2>&1 &
  log "scheduled settle-recheck (+${settle_secs}s)"
}

# Fast path: registry already correct.
if [ -f "$target" ] && [ "$(cat "$target" 2>/dev/null)" = "$self_token" ]; then
  log "exit: registry already correct ($target)"
  emit_session_context "$mismatch_warning"
  schedule_settle
  exit 0
fi

# Slow path: rebuild this name's entry (keyed by the identity token).
# Also remove any OTHER name's entry claiming the SAME identity token — after a
# mid-session branch switch (name re-derived from the new branch) the old-name
# entry would otherwise survive, making fleet_find_self nondeterministic and
# stranding mail staged under whichever name loses the glob race.
for _stale in "$HOME/.claude/running-agents"/*; do
  [ -f "$_stale" ] || continue
  [ "$(cat "$_stale" 2>/dev/null)" = "$self_token" ] && rm -f "$_stale"
done
rm -f "$HOME/.claude/running-agents/$name".*
printf '%s\n' "$self_token" > "$target"
log "wrote $target -> $self_token"

# tmux cosmetics — only when tmux is actually drivable (headless: skipped).
if fleet_tmux_ok 2>/dev/null; then
  # tmux pane title (right granularity for split panes).
  tmux select-pane -t "$TMUX_PANE" -T "$name" 2>/dev/null || true

  # tmux window names are owned by fleet-layout.sh (DX-jn-cc-001). Renaming from here
  # meant every agent stamped its OWN name onto a window it might share, last-writer-wins,
  # re-firing on every restart. name-windows instead derives each window's label from ALL
  # of its resident agents, so every agent computes the same answer and co-tenants can't
  # clobber each other.
  layout_sh="$(cd "$(dirname "$0")/../scripts" 2>/dev/null && pwd)/fleet-layout.sh"
  if [ -x "$layout_sh" ]; then
    "$layout_sh" name-windows >/dev/null 2>&1 || log "fleet-layout name-windows failed (non-fatal)"
  else
    log "fleet-layout.sh not found at $layout_sh — window naming skipped"
  fi

  # The /rename keystroke moved into the settle-recheck verb (DX-jn-cc-006): it
  # now fires only after the session name has settled, and only on fresh
  # startups — a resume buffers keystrokes until AFTER initialization, so a
  # blind send here could type over a late-arriving user name. The DX-jn-8-024
  # guidance stands: launch with `claude --name "<name>"`, which settles the name
  # and makes the fallback a no-op.
  :
else
  log "tmux unavailable — skipped pane/window title (headless registration)"
fi

schedule_settle
emit_session_context "$mismatch_warning"
exit 0
