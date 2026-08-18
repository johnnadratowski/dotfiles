#!/usr/bin/env bash
# log-sendmessage.sh — PostToolUse hook: record every SendMessage SEND event.
#
# WHY: teammate messages occasionally appear twice at the recipient. Two possible
# shapes, indistinguishable from the receiving transcript alone:
#   (i)  ONE send, read twice   — transcript re-anchor after a compaction/bridge
#   (ii) TWO sends              — a genuine second delivery event
# The receive side (the `<teammate-message ...>` block in the recipient's
# transcript jsonl) carries NO msg_id, so only a send-side ledger settles it.
#
# Appends ONE tab-separated line per SendMessage to $HOME/.claude/logs/sendmessage.log:
#   ts_iso <TAB> sender <TAB> to <TAB> msg_id <TAB> sha1_12(message) <TAB> summary80
#
# Reads the hook payload on stdin. Never fails the tool call: always exits 0.
# Deps: jq. If jq is missing, exits 0 silently (instrumentation must never block work).
set -u

LOG_DIR="${HOME}/.claude/logs"
LOG_FILE="${LOG_DIR}/sendmessage.log"

command -v jq >/dev/null 2>&1 || exit 0

payload="$(cat 2>/dev/null)" || exit 0
[ -n "$payload" ] || exit 0

tool_name="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"
[ "$tool_name" = "SendMessage" ] || exit 0

# tool_response may be an object or a JSON string containing an object.
resp="$(printf '%s' "$payload" | jq -c '
  (.tool_response // {}) as $r
  | if ($r|type) == "string" then (try ($r|fromjson) catch {}) else $r end
' 2>/dev/null)"
[ -n "$resp" ] || resp='{}'

msg_id="$(printf '%s' "$resp"    | jq -r '.msg_id // "-"' 2>/dev/null)"
sender="$(printf '%s' "$resp"    | jq -r '.routing.sender // empty' 2>/dev/null)"
to="$(printf '%s' "$payload"     | jq -r '.tool_input.to // empty' 2>/dev/null)"
[ -n "$to" ] || to="$(printf '%s' "$resp" | jq -r '.routing.target // "-"' 2>/dev/null)"

# Sender fallbacks: hook env, then the lane name implied by cwd, then "-".
if [ -z "$sender" ]; then
  sender="${CLAUDE_AGENT_NAME:-}"
fi
if [ -z "$sender" ]; then
  cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
  case "$cwd" in
    */worktrees/*) sender="${cwd##*/worktrees/}"; sender="${sender%%/*}" ;;
  esac
fi
[ -n "$sender" ] || sender="-"

# Full message body, so identical re-sends collide on the hash.
body="$(printf '%s' "$payload" | jq -r '
  (.tool_input.message // "") | if type == "string" then . else tojson end
' 2>/dev/null)"
if command -v shasum >/dev/null 2>&1; then
  hash="$(printf '%s' "$body" | shasum -a 1 2>/dev/null | cut -c1-12)"
else
  hash="$(printf '%s' "$body" | sha1sum 2>/dev/null | cut -c1-12)"
fi
[ -n "$hash" ] || hash="-"

summary="$(printf '%s' "$payload" | jq -r '
  (.tool_input.summary // .tool_response.routing.summary // "") | tostring
' 2>/dev/null | tr '\n\t' '  ' | cut -c1-80)"
[ -n "$summary" ] || summary="-"

session="$(printf '%s' "$payload" | jq -r '.session_id // "-"' 2>/dev/null | cut -c1-8)"

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p "$LOG_DIR" 2>/dev/null || exit 0
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$ts" "$sender" "$to" "$msg_id" "$hash" "$session" "$summary" >> "$LOG_FILE" 2>/dev/null

exit 0
