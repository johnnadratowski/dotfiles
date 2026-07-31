#!/bin/bash
# subagentStatusLine — the per-row status line in the agent panel below the prompt.
#
# THE CONTRACT, read off the harness rather than guessed (v2.1.220, and confirmed against the
# published docs). It is NOT one invocation per row with that row's context on stdin, which is
# what this script assumed for its whole first life and why the panel stayed blank:
#
#   stdin   ONE JSON object for the WHOLE panel:
#             { columns: <int>, tasks: [ { id, name, type, status, description, label,
#                                          startTime, model, effort, contextWindowSize,
#                                          tokenCount, tokenSamples, cwd }, … ] }
#   stdout  ONE JSON LINE PER TASK:  {"id": "<task id>", "content": "<what to render>"}
#           Anything else is dropped with `subagentStatusLine emitted non-JSON line` in the
#           debug log — silently, as far as the panel is concerned.
#
# `content` REPLACES the whole default row (name · description · token count), so the name has
# to be re-emitted here or it disappears. Omit a task's id to keep the default row; emit an
# empty content string to hide the row entirely.
#
# WHICH ROWS EVER REACH THIS SCRIPT — the answer is "fewer than you think", and it cost a long
# hunt. The harness filters to `type === "local_agent"` (Task-tool subagents), excluding the
# `main` row and every other task type: `in_process_teammate`, `remote_agent`, `local_bash`,
# `local_workflow`. A tmux teammate is not a task in the parent at all. When the eligible list
# comes out empty the runner returns before spawning anything — so a TEAM LEAD, whose panel is
# teammates plus `main`, gets no decorations at all, and no setting changes that.
# fleet-status.sh is the answer for that case; its header carries the full finding.
#
# WHAT IT SHOWS, left to right, and why each earns its width:
#   name      you are looking at a list; the row has to say whose it is
#   status    the harness's OWN status string, rendered verbatim rather than interpreted —
#             if the panel's idle/active indicator is lying, this is where you see it lie
#   ctx%      the number you act on: when to /compact, when to hand work over
#   uptime    how long this agent has been at it — a stuck agent looks exactly like a busy
#             one without it
#   ▸ ID      the lane's in-progress tracker id, from the same mirror the main bar reads
#   📌 …      the agent's own last summary line, so the row says what it is DOING, not just
#             that it is alive
#
# Fields degrade independently: anything unavailable is dropped and the rest still renders.
# The per-agent facts themselves live in _agent_facts.py, shared with fleet-status.sh so the
# panel and the lead's view cannot disagree about what an agent is doing.
#
# CONTRACT ON OUR SIDE: always exit 0, always finish fast. The harness kills us at 5s and drops
# the whole panel's decorations if we exit non-zero. Everything here is bounded — the transcript
# is read from the TAIL, never scanned whole, because these files reach hundreds of megabytes.
#
# Set SUBAGENT_STATUSLINE_DEBUG=1, or touch ~/.claude/debug/subagent-statusline.capture, to
# append each raw payload to ~/.claude/debug/subagent-statusline.jsonl. That is how the contract
# above was established; use it again rather than guessing if a future version changes shape.

set -u
payload="$(cat 2>/dev/null || true)"

if [ "${SUBAGENT_STATUSLINE_DEBUG:-0}" = 1 ] || [ -e "$HOME/.claude/debug/subagent-statusline.capture" ]; then
  mkdir -p "$HOME/.claude/debug" 2>/dev/null
  printf '%s\n' "$payload" >> "$HOME/.claude/debug/subagent-statusline.jsonl" 2>/dev/null
fi

[ -n "$payload" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# The program is carried in a quoted heredoc and passed as an ARGUMENT, not inlined in a
# single-quoted `python3 -c '...'`. An apostrophe in any comment or docstring closes that
# quote and the whole script detonates — which it did, at "the agent's transcript".
PROG=$(cat <<'PYEOF'

import json, os, sys

sys.path.insert(0, os.environ.get("AGENT_FACTS_DIR") or ".")
try:
    from _agent_facts import (
        MARK, as_int, needs_input, summary_for, todo_for, uptime, window_for,
    )
except Exception:
    # No shared module → emit nothing, which leaves the harness's own default row standing.
    # A worse row is still a row; an exception here would blank the whole panel.
    sys.exit(0)

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)

tasks = d.get("tasks") or []
if not isinstance(tasks, list):
    sys.exit(0)

try:
    COLUMNS = int(d.get("columns") or 80)
except Exception:
    COLUMNS = 80

# Statuses that mean "running normally" and so say nothing worth a column. Anything else is
# shown VERBATIM — an indicator that misreports idle/active is only visible if we do not
# paper over it with our own vocabulary.
QUIET = {"running", "active", "in_progress", "in-progress", "working", ""}

for t in tasks:
    if not isinstance(t, dict):
        continue
    tid = t.get("id")
    if not tid:
        continue

    parts = []

    # FIRST, and loud. The point of the row is to say where you are needed; a question
    # buried behind six facts is a question you scroll past.
    ask = needs_input(t.get("cwd"))
    if ask:
        parts.append("❓")

    # IDENTITY. A teammate carries a real `name` (the lane). A subagent carries NONE — the
    # harness sends only `description`/`label`, which is the task PROMPT, so falling back to it
    # filled the row with "Full gate sweep on FEAT-6" where a name belongs. Prefer the name;
    # otherwise say what KIND of task this is and let the summary carry the what.
    name = t.get("name")
    if name:
        parts.append(str(name)[:18])
    else:
        kind = str(t.get("type") or "").replace("local_", "").replace("_", " ")
        if kind:
            parts.append(kind[:12])

    status = str(t.get("status") or "").strip()
    if status.lower() not in QUIET:
        parts.append(status[:12])

    used = as_int(t.get("tokenCount"))
    win = as_int(t.get("contextWindowSize")) or (window_for(t.get("model")) if used else None)
    if used and win:
        pct = round(100 * used / win)
        # The flags are the point of a percentage: ~ is "hand off soon", ! is "compact now".
        flag = "!" if pct >= 90 else ("~" if pct >= 80 else "")
        parts.append("%s%d%%" % (flag, pct))
        parts.append("%dk" % round(used / 1000) if used >= 1000 else str(used))

    up = uptime(t.get("startTime"))
    if up:
        parts.append(up)

    todo = todo_for(t.get("cwd"))
    if todo:
        parts.append("▸ " + todo)

    # For an unnamed task the description is the only thing that says what it IS, so it earns a
    # short slot — but truncated hard, because it is a prompt and prompts are long.
    if not name:
        desc = str(t.get("description") or t.get("label") or "").strip()
        if desc:
            parts.append(desc[:34] + ("…" if len(desc) > 34 else ""))

    head = " ".join(parts)

    # The summary takes whatever width is left and is the first thing dropped — every field
    # before it is a fact you act on; this one is context.
    # A question outranks the summary for the leftover width: one is addressed to you, the
    # other is background.
    room = COLUMNS - len(head) - 4
    if ask and room >= 12:
        head = head + "  ❓ " + (ask if len(ask) <= room else ask[:room - 1] + "…")
        room = COLUMNS - len(head) - 4
    if room >= 24:
        s = summary_for(t.get("cwd"))
        if s:
            head = head + "  · " + MARK + " " + (s if len(s) <= room else s[:room - 1] + "…")

    if head:
        sys.stdout.write(json.dumps({"id": str(tid), "content": head}) + "\n")
PYEOF
)
AGENT_FACTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AGENT_FACTS_DIR
printf '%s' "$payload" | python3 -c "$PROG" 2>/dev/null
exit 0
