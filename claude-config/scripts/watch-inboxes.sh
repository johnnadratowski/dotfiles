#!/usr/bin/env bash
# watch-inboxes.sh — RECEIVE-side ledger for the fleet's native teammate transport.
#
# Delivery on disk is an append to  ~/.claude/teams/<session>/inboxes/<recipient>.json
# (a JSON array; each element has from/text/summary/timestamp/msg_id/read). Consumption
# TRUNCATES the array back to []; the entry is removed, not marked read:true.
#
# The recipient's transcript renders the message as `<teammate-message teammate_id=...>`
# WITHOUT the msg_id, so the transcript alone cannot tell a second APPEND (a real second
# delivery) from a second READ of one append (a compaction/bridge re-anchor). This watcher
# closes that gap: it logs every msg_id the moment it lands in an inbox.
#
# Log: ~/.claude/logs/inbox-deliveries.log   (tab-separated)
#   ts_iso <TAB> APPEND <TAB> recipient <TAB> from <TAB> msg_id <TAB> summary80
#
# Usage:  bash ~/.claude/scripts/watch-inboxes.sh [poll_seconds]     # foreground
#         nohup bash ~/.claude/scripts/watch-inboxes.sh 0.2 >/dev/null 2>&1 &
# Stop:   pkill -f watch-inboxes.sh
#
# Safe by construction: read-only against the inbox files. Deps: jq.
set -u

POLL="${1:-0.2}"
TEAMS_DIR="${HOME}/.claude/teams"
LOG_DIR="${HOME}/.claude/logs"
LOG_FILE="${LOG_DIR}/inbox-deliveries.log"
SEEN_FILE="${LOG_DIR}/.inbox-deliveries.seen"

command -v jq >/dev/null 2>&1 || { echo "watch-inboxes: jq required" >&2; exit 1; }
mkdir -p "$LOG_DIR"
: >> "$LOG_FILE"
: >> "$SEEN_FILE"

# An entry sits in the inbox until the recipient drains it, so "present in this poll" is
# NOT an arrival. Only an id that was ABSENT last poll and is present now is an arrival.
# msg_id is a uuid minted per SendMessage call, so an id arriving twice is a true
# re-append — the finding we care about — and is logged as DUPLICATE-APPEND.
# Seed from whatever is already pending, so a watcher RESTART does not re-report
# entries that were merely sitting undrained (SEEN_FILE persists across restarts).
prev_present="$(cat "$TEAMS_DIR"/*/inboxes/*.json 2>/dev/null \
  | jq -r 'if type=="array" then .[].msg_id else empty end' 2>/dev/null)"$'\n'
# ...and record them as seen, so a re-append of one of them still reads as DUPLICATE.
printf '%s' "$prev_present" | grep -v '^$' >> "$SEEN_FILE" 2>/dev/null

while :; do
  now_present=""
  for f in "$TEAMS_DIR"/*/inboxes/*.json; do
    [ -f "$f" ] || continue
    # Cheap gate: an empty array is the common case.
    [ "$(wc -c < "$f" 2>/dev/null || echo 0)" -gt 2 ] || continue
    recipient="$(basename "$f" .json)"
    while IFS=$'\t' read -r mid from summary; do
      [ -n "${mid:-}" ] || continue
      now_present="${now_present}${mid}"$'\n'
      # Still sitting from the previous poll (recipient hasn't drained it) — not an arrival.
      case $'\n'"${prev_present}" in *$'\n'"${mid}"$'\n'*) continue ;; esac
      ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      if grep -Fqx "$mid" "$SEEN_FILE" 2>/dev/null; then
        # Same msg_id landed in an inbox a second time — a true re-append.
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$ts" "DUPLICATE-APPEND" "$recipient" "$from" "$mid" "$summary" >> "$LOG_FILE"
      else
        printf '%s\n' "$mid" >> "$SEEN_FILE"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$ts" "APPEND" "$recipient" "$from" "$mid" "$summary" >> "$LOG_FILE"
      fi
    done < <(jq -r '
      (if type == "array" then . else [] end)[]
      | [ (.msg_id // "-"),
          (.from // "-"),
          ((.summary // .text // "") | tostring | gsub("[\n\t]"; " ") | .[0:80]) ]
      | @tsv' "$f" 2>/dev/null)
  done
  prev_present="$now_present"
  sleep "$POLL"
done
