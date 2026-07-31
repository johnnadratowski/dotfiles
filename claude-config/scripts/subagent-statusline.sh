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
# WHICH ROWS EVER REACH THIS SCRIPT — the answer is "fewer than you think", and establishing it
# cost a long hunt. The harness filters to `type === "local_agent"` (Task-tool subagents),
# excluding the `main` row and every other task type: `in_process_teammate`, `remote_agent`,
# `local_bash`, `local_workflow`. A tmux teammate is not a task in the parent at all. When the
# eligible list comes out empty the runner returns before spawning anything — so a TEAM LEAD,
# whose panel is teammates plus `main`, gets no decorations at all, and NO SETTING CHANGES THAT.
# Switching teammateMode only converts tmux teammates into `in_process_teammate`, also excluded.
# Do not re-litigate this: it is not workspace trust, not settings scope, not launch flags.
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

import json, os, re, sys, glob, time

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

MARK = "\U0001F4CC"          # the summary sentinel the Concise output style leads with
TAIL = 512 * 1024            # bytes of transcript to scan; a whole read would blow the 5s budget


def as_int(x):
    try:
        return int(float(x))
    except Exception:
        return None


def window_for(model):
    """Context window when the harness did not supply one — same rule agent-fanout uses:
    an explicit [1m] marker wins, then opus/sonnet major >= 4 means 1M, else 200k."""
    m = str(model or "").lower()
    if "1m" in re.findall(r"\[([^\]]*)\]", m) or m.endswith("-1m"):
        return 1_000_000
    fam = re.search(r"(opus|sonnet)[-_]?(\d+)", m)
    return 1_000_000 if (fam and int(fam.group(2)) >= 4) else 200_000


def uptime(start):
    """startTime is whatever the harness gives — epoch seconds, epoch millis, or ISO."""
    t = None
    n = as_int(start)
    if n:
        t = n / 1000.0 if n > 10_000_000_000 else float(n)
    elif isinstance(start, str) and start:
        try:
            from datetime import datetime
            t = datetime.fromisoformat(start.replace("Z", "+00:00")).timestamp()
        except Exception:
            t = None
    if not t:
        return ""
    s = int(time.time() - t)
    if s < 0 or s > 60 * 60 * 24 * 30:
        return ""
    if s < 60:
        return "%ds" % s
    if s < 3600:
        return "%dm" % (s // 60)
    return "%dh%02dm" % (s // 3600, (s % 3600) // 60)


def _walk_up(cwd, *rel):
    """First readable non-empty <ancestor>/<rel...>, walking up from cwd. Walked rather than
    resolved with git: no subprocess, and this runs per row per tick."""
    p = cwd if isinstance(cwd, str) and cwd else None
    for _ in range(24):
        if not p:
            break
        try:
            f = os.path.join(p, *rel)
            if os.path.getsize(f) > 0:
                with open(f) as fh:
                    return fh.read()
        except OSError:
            pass
        parent = os.path.dirname(p)
        if parent == p:
            break
        p = parent
    return ""


def todo_for(cwd):
    """In-progress tracker id(s) for the worktree this agent works in.

    Tracking lives in Linear, which has no cheap local state to read, so `/todo` mirrors the id
    to a gitignored per-worktree file and every status surface reads that — the same mirror the
    main bar uses, so the panel and the bar cannot disagree.

    ONLY the machine-readable head of the file: agents also leave themselves resume context
    below the pointer lines, and reading that as ids once rendered a 60-line checkpoint into the
    status bar. Blank and `#` lines are skipped; the first line whose first field is not
    id-shaped ends the list.
    """
    ids = []
    for ln in _walk_up(cwd, ".claude", "current-work").splitlines():
        ln = ln.strip()
        if not ln or ln.startswith("#"):
            continue
        first = ln.split("\t")[0].strip()
        if first and " " not in first and len(first) <= 24:
            ids.append(first)
        else:
            break
    return " ".join(ids)


def needs_input(cwd):
    """Does this agent want the human? THE HARNESS CANNOT TELL US.

    Measured across 294 live payloads, `status` only ever takes two values - `running` and
    `completed`. There is no waiting-for-input state to read, and an agent that has asked a
    question and gone idle is indistinguishable from one simply between turns. So the signal
    has to be one the agent writes: a one-line reason in <lane>/.claude/needs-input, created
    when it needs an answer and removed once it has one.
    """
    body = _walk_up(cwd, ".claude", "needs-input").strip()
    return body.splitlines()[0].strip() if body else ""


def _tail(path, nbytes):
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            if size > nbytes:
                fh.seek(size - nbytes)
                fh.readline()            # discard the partial line the seek landed inside
            return fh.read().decode("utf-8", "replace")
    except OSError:
        return ""


def summary_for(cwd):
    """The agent's most recent 📌 summary, from its own transcript.

    Transcripts live at ~/.claude/projects/<cwd with every non-alphanumeric char as - >/*.jsonl.
    Only 📌-led lines qualify, and the LAST one wins, so a trivial reply leaves the previous
    summary standing rather than blanking the row.

    Widening reads, not one big one. 512KB is the right size almost always, but a single turn
    that dumped a large tool result can push the last summary out of it — a 7MB transcript
    rendered a blank row for exactly that reason. The window grows only when the small read
    came up empty, and each step re-reads from the tail, so no record is split and lost.
    """
    if not isinstance(cwd, str) or not cwd:
        return ""
    d = os.path.join(os.path.expanduser("~/.claude/projects"),
                     re.sub(r"[^A-Za-z0-9]", "-", cwd))
    try:
        files = glob.glob(os.path.join(d, "*.jsonl"))
        if not files:
            return ""
        path = max(files, key=os.path.getmtime)
        size = os.path.getsize(path)
    except OSError:
        return ""

    for n in (TAIL, 4 * TAIL, 16 * TAIL):
        found = _scan_summary(_tail(path, n))
        if found:
            return found
        if size <= n:                    # already read the whole file; widening is futile
            break
    return ""


def _scan_summary(chunk):
    last = ""
    for line in chunk.splitlines():
        if MARK not in line:             # cheap reject before the JSON parse
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if o.get("type") != "assistant":
            continue
        content = (o.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        for c in content:
            if c.get("type") != "text":
                continue
            for ln in (c.get("text") or "").splitlines():
                ln = ln.strip()
                if ln.startswith(MARK):
                    last = ln[len(MARK):].strip()
    # Markdown is noise at this width.
    last = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", last)
    last = re.sub(r"\*\*|\*|`|~~|__", "", last)
    return re.sub(r"\s+", " ", last).strip()


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
printf '%s' "$payload" | python3 -c "$PROG" 2>/dev/null
exit 0
