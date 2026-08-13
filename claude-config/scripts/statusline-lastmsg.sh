#!/bin/bash
# .claude/scripts/statusline-lastmsg.sh
#
# ccstatusline `custom-command` widget: the clock time at which THIS agent last SPOKE —
# "🕐 15:40". The one fact the rest of the bar cannot give you: every other field says what
# the agent is or has, none of them says when it last said anything, so a pane parked
# mid-turn three hours ago is indistinguishable from one that answered a moment ago.
#
# SPOKE means an assistant message carrying TEXT. A tool call is not speech, and counting it
# would turn this into a liveness light — which is what `fleet-liveness` already is. During a
# long tool run the clock therefore holds at the last actual reply, which is the honest
# reading: "the agent has not said anything since 15:40".
#
# Sidechain records are excluded. A Task-tool subagent writes into its PARENT's transcript
# with isSidechain=true, so counting them would make the lead's clock tick to a subagent's
# utterance and report the lead as talking when it was silent.
#
# Session-exact: the transcript comes from the StatusJSON on stdin, so a cwd hosting several
# sessions (a lane and its teammates) reports each one's own clock. Falls back to the newest
# transcript for $PWD when invoked without a payload (tests, a bare shell run).
#
# READ FROM THE TAIL, WIDENING — same shape and same reason as statusline-summary.sh had:
# transcripts reach hundreds of megabytes and this runs on every repaint, but one turn that
# dumps a large tool result can push the last spoken message out of a small window. 512KB,
# then 2MB, then 8MB, each re-read from the end so no record is split across a boundary.
#
# Silent (exit 0, no output) when there is no transcript or it holds no spoken message.

payload="$(cat 2>/dev/null || true)"

# No jq: this runs per repaint per agent, and a transcript path holds no escaped quotes.
transcript="$(printf '%s' "$payload" |
  sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"

command -v python3 >/dev/null 2>&1 || exit 0

python3 - "$transcript" "$PWD" <<'PY' 2>/dev/null
import glob, json, os, re, sys
from datetime import datetime

path, cwd = sys.argv[1], sys.argv[2]

if not path or not os.path.isfile(path):
    # No payload (or a stale path): newest transcript for this working directory. Only a
    # fallback — it cannot tell two sessions in one cwd apart, which is the case the
    # StatusJSON path exists to settle.
    d = os.path.join(os.path.expanduser("~/.claude/projects"),
                     re.sub(r"[^A-Za-z0-9]", "-", cwd))
    try:
        files = glob.glob(os.path.join(d, "*.jsonl"))
        path = max(files, key=os.path.getmtime) if files else ""
    except OSError:
        path = ""
if not path:
    sys.exit(0)


def tail(nbytes):
    size = os.path.getsize(path)
    with open(path, "rb") as fh:
        if size > nbytes:
            fh.seek(size - nbytes)
            fh.readline()              # discard the partial line the seek landed inside
        return fh.read().decode("utf-8", "replace"), size


def scan(chunk):
    """Timestamp of the last assistant message with text in it, or None."""
    last = None
    for line in chunk.splitlines():
        if '"assistant"' not in line:      # cheap reject before the JSON parse
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if o.get("type") != "assistant" or o.get("isSidechain"):
            continue
        content = (o.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        if not any(isinstance(c, dict) and c.get("type") == "text" and (c.get("text") or "").strip()
                   for c in content):
            continue
        ts = o.get("timestamp")
        if ts:
            last = ts
    return last


stamp = None
try:
    for n in (512 * 1024, 2 * 1024 * 1024, 8 * 1024 * 1024):
        chunk, size = tail(n)
        stamp = scan(chunk)
        if stamp or size <= n:             # found it, or already read the whole file
            break
except OSError:
    sys.exit(0)

if not stamp:
    sys.exit(0)

try:
    # Transcripts stamp UTC with a trailing Z; render in the reader's own zone, because the
    # only question asked of this field is "how long ago was that, from where I am sitting".
    t = datetime.fromisoformat(stamp.replace("Z", "+00:00")).astimezone()
except Exception:
    sys.exit(0)

print("\U0001F550 " + t.strftime("%H:%M"))
PY
exit 0
