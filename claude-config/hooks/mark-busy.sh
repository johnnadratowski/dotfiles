#!/bin/bash
# UserPromptSubmit + PreToolUse hook: mark this agent BUSY.
#
# UserPromptSubmit marks the turn START; PreToolUse re-touches the marker on
# every tool call so it stays FRESH through turns that never had a prompt
# submit at all — background-task notifications and Stop-hook continuations
# start turns without UserPromptSubmit, and were invisible to the idle-guard.
#
# WHO READS THIS. `fleet_busy` (_fleet.sh), and through it:
#   - team-boot.sh's `down` verb, which is IDLE-GATED — it refuses to stop an
#     agent that is mid-turn. This is the load-bearing consumer: delete the marker
#     and `down` reads every agent as idle and kills one that is working.
#   - agent-fanout.sh's `restart` / `compact` skip lists, and `status`.
# The marker's ORIGINAL reader — a peer's agent-send, gating the live tmux nudge —
# died with the mailbox transport. The marker did not: idleness is still the thing
# every destructive fleet verb gates on.
#
# Keyed by agent name (mirrors the registry). Shared ~/.claude so other tools can
# read it. Silent, always exits 0. A missing marker means "treat as idle".

set -u
cat >/dev/null 2>&1 || true   # drain the hook payload on stdin (unused)

reg="$HOME/.claude/running-agents"
[ -d "$reg" ] || exit 0

# Self-id via the identity token (pane in tmux, else cwd-based) — works headless (DX-jn-8-019).
hook_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
# shellcheck disable=SC1090
# Resolve the fleet helpers from EITHER home (canonical, symlinked from dotfiles) or the
# repo sibling. The sibling form also resolves correctly once this hook itself lives in
# ~/.claude/hooks, so one chain covers every layout.
for _fleet_candidate in "$HOME/.claude/scripts/_fleet.sh" "$hook_dir/../scripts/_fleet.sh"; do
  [ -r "$_fleet_candidate" ] && { . "$_fleet_candidate"; break; }
done

# INLINE FALLBACK, and it is load-bearing rather than defensive boilerplate.
#
# This was `fleet_find_self "$reg" 2>/dev/null || true` with no fallback: if neither _fleet.sh
# candidate was readable the function was undefined, `self_name` came back empty, and the hook
# exited 0 having written NOTHING. A registered, mid-turn agent then looked exactly like an idle
# one — and idle is what authorises `team-boot.sh down` to kill it and `agent-fanout restart` to
# type into it. A destroy-guard's key input failing OPEN, on a path with no error and no output.
#
# Same shape (and same reason) as the inline `fleet_busy` fallbacks in agent-fanout.sh and
# statusline-fleet.sh, and guarded the same way: `command -v`, never `f || inline`, which would
# run the inline copy on every legitimately-empty answer.
_self_token() {
  if [ -n "${TMUX_PANE:-}" ]; then printf '%s' "$TMUX_PANE"; else printf 'cwd:%s' "$PWD"; fi
}
_find_self_inline() {
  local d="$1" tok f; tok="$(_self_token)"
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    [ "$(cat "$f" 2>/dev/null)" = "$tok" ] && { basename "$f" | sed 's/\.[0-9]*$//'; return 0; }
  done
  return 1
}
if command -v fleet_find_self >/dev/null 2>&1; then
  self_name="$(fleet_find_self "$reg" 2>/dev/null || true)"
else
  self_name="$(_find_self_inline "$reg" 2>/dev/null || true)"
fi
if [ -n "$self_name" ]; then
  mkdir -p "$HOME/.claude/agent-busy"
  : > "$HOME/.claude/agent-busy/$self_name"

  # KEEP THE CWD SIDECAR HONEST. register-agent.sh writes ~/.claude/agents/<name>.cwd ONCE, at
  # SessionStart — and a teammate boots in the LEAD's worktree and only moves itself afterwards
  # with EnterWorktree. Nothing ever rewrote the sidecar, so every teammate's recorded cwd said
  # `team-lead` for its whole life while the process sat in its own lane.
  #
  # That is not cosmetic. Three separate readers key off this file:
  #   - fleet-layout's attribution saw five agents sharing one cwd, hit its ambiguity rule, and
  #     made EVERY layout verb a silent no-op for teammates;
  #   - statusline-role matched $PWD against the sidecars and picked the alphabetically-first
  #     agent, labelling the LEAD `feat`;
  #   - agent-fanout's CTX column resolves each transcript through the same path.
  #
  # This hook is the natural writer: it already runs on every tool call with identity resolved,
  # so the sidecar converges within one turn of an agent moving. Guarded on a real change, so
  # steady state is a read and no write.
  _cwd_file="$HOME/.claude/agents/$self_name.cwd"
  if [ "$(cat "$_cwd_file" 2>/dev/null)" != "$PWD" ]; then
    mkdir -p "$HOME/.claude/agents" 2>/dev/null || true
    printf '%s' "$PWD" > "$_cwd_file" 2>/dev/null || true
  fi
fi

# There was also a HOLD marker here (DX-jn-8-031), set while this agent entered the
# blocking Monocle verdict wait — a single long tool call that emits no further
# PreToolUse, so the busy marker went stale mid-review and peers re-nudged every 30s
# for the whole human review. Its only readers were agent-send and the inbox-watcher.
# Both are gone, nothing reads ~/.claude/agent-hold, and write-only state is worse
# than no state: it looks like a live signal to the next reader of this file.
exit 0
