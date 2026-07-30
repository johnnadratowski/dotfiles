#!/bin/bash
# subagentStatusLine — the per-row status line in the agent panel.
#
# THE CONTRACT, read off the harness rather than guessed (v2.1.220). It is NOT one invocation
# per row with that row's context on stdin, which is what this script assumed for its whole
# life and why the panel stayed blank:
#
#   stdin   ONE JSON object for the WHOLE panel:
#             { columns: <int>, tasks: [ { id, name, type, status, description, label,
#                                          startTime, model, effort, contextWindowSize,
#                                          tokenCount, tokenSamples: [...], cwd }, … ] }
#   stdout  ONE JSON LINE PER TASK:  {"id": "<task id>", "content": "<what to render>"}
#           Anything else is dropped with `subagentStatusLine emitted non-JSON line` /
#           `emitted invalid schema` in the debug log — silently, as far as the panel is
#           concerned. A bare string like "12% 123k" renders as nothing at all.
#
# Two consequences worth stating, because both were bugs here:
#   - context comes from `tokenCount` / `contextWindowSize` PER TASK, not from a per-row
#     payload of guessed field names;
#   - `cwd` is given PER TASK, so the TODO is read from each agent's OWN lane. Resolving it
#     from $PWD showed every row the LEAD's in-progress issue — which is empty, so the todo
#     never appeared even for the teammates that had one.
#
# WHAT IT SHOWS: context usage, which is the number you act on — when to /compact, when to hand
# work over, when an agent is about to start degrading — and the lane's in-progress Linear id.
#
# Set SUBAGENT_STATUSLINE_DEBUG=1 to append each raw payload to
# ~/.claude/debug/subagent-statusline.jsonl. That is how the contract above was established;
# use it again rather than guessing if a future version changes shape.
#
# CONTRACT ON OUR SIDE: always exit 0, always finish fast. The harness kills us at 5s and drops
# the whole panel's decorations if we exit non-zero.

set -u
payload="$(cat 2>/dev/null || true)"

# Capture is switchable from OUTSIDE the process, because the interesting question is usually
# "does the harness call this at all, and when" — and the harness owns our environment, so an
# env var cannot be turned on for a session that is already running. `touch` the sentinel,
# reproduce, `rm` it.
if [ "${SUBAGENT_STATUSLINE_DEBUG:-0}" = 1 ] || [ -e "$HOME/.claude/debug/subagent-statusline.capture" ]; then
  mkdir -p "$HOME/.claude/debug" 2>/dev/null
  printf '%s\n' "$payload" >> "$HOME/.claude/debug/subagent-statusline.jsonl" 2>/dev/null
fi

[ -n "$payload" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

printf '%s' "$payload" | python3 -c '
import json, os, re, sys

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)

tasks = d.get("tasks") or []
if not isinstance(tasks, list):
    sys.exit(0)

# Panel width, minus what the harness already spent on the name column. Rows are narrow; a long
# line is truncated by the panel anyway, and truncating here keeps the id readable.
try:
    budget = max(12, int(d.get("columns") or 80) // 3)
except Exception:
    budget = 24


def window_for(model):
    """Context window when the harness did not supply one — same rule agent-fanout uses:
    an explicit [1m] marker wins, then opus/sonnet major >= 4 means 1M, else a conservative 200k."""
    m = str(model or "").lower()
    if "1m" in re.findall(r"\[([^\]]*)\]", m) or m.endswith("-1m"):
        return 1_000_000
    fam = re.search(r"(opus|sonnet)[-_]?(\d+)", m)
    return 1_000_000 if (fam and int(fam.group(2)) >= 4) else 200_000


def as_int(x):
    try:
        return int(float(x))
    except Exception:
        return None


def todo_for(cwd):
    """In-progress Linear id(s) for the worktree this agent works in.

    Tracking lives in Linear, which has no cheap local state to read, so `/todo` mirrors the id
    to a gitignored per-worktree file and every status surface reads that — same mirror the main
    bar reads, so the panel and the bar cannot disagree. Walked up from the task cwd rather than
    resolved with git: no subprocess, and this runs for every row on every tick.

    NO hyperlink, deliberately: the main bar wraps the id in an OSC 8 escape for cmd-click, which
    needs a ccstatusline widget with preserveColors. Here the content is a plain string and the
    escape would render as visible garbage in every row.
    """
    p = cwd if isinstance(cwd, str) and cwd else None
    seen = 0
    while p and seen < 24:
        f = os.path.join(p, ".claude", "current-work")
        try:
            if os.path.getsize(f) > 0:
                with open(f) as fh:
                    ids = [ln.split("\t")[0].strip() for ln in fh if ln.strip()]
                ids = [i for i in ids if i]
                if ids:
                    return " ".join(ids)
        except OSError:
            pass
        parent = os.path.dirname(p)
        if parent == p:
            break
        p, seen = parent, seen + 1
    return ""


for t in tasks:
    if not isinstance(t, dict):
        continue
    tid = t.get("id")
    if not tid:
        continue

    parts = []
    used = as_int(t.get("tokenCount"))
    win = as_int(t.get("contextWindowSize")) or (window_for(t.get("model")) if used else None)
    if used and win:
        pct = round(100 * used / win)
        # The flags are the whole point of showing a percentage: ~ is "hand off soon", ! is
        # "compact now". A bare number makes every agent look the same at a glance.
        flag = "!" if pct >= 90 else ("~" if pct >= 80 else "")
        parts.append("%s%d%%" % (flag, pct))
        parts.append("%dk" % round(used / 1000) if used >= 1000 else str(used))

    todo = todo_for(t.get("cwd"))
    if todo:
        parts.append("▸ " + todo)

    content = " ".join(parts)[:budget]
    if content:
        sys.stdout.write(json.dumps({"id": str(tid), "content": content}) + "\n")
' 2>/dev/null
exit 0
