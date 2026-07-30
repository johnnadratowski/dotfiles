#!/bin/bash
# subagentStatusLine — the per-row status line in the agent panel.
#
# Claude Code pipes that row's context to us as JSON on stdin and renders whatever we print,
# for EACH agent in the panel. This is the only per-agent display surface there is: teammate
# and subagent sessions do not render a `statusLine` of their own (verified — ccstatusline runs
# correctly when invoked by hand inside a teammate, the harness simply never calls it), so
# without this, a background agent shows a name and nothing about its state.
#
# WHAT IT SHOWS: context usage, which is the number you act on — it decides when to /compact,
# when to hand work over, and when an agent is about to start degrading.
#
# The payload's field names are NOT guessed. Set SUBAGENT_STATUSLINE_DEBUG=1 to append each raw
# payload to ~/.claude/debug/subagent-statusline.jsonl and read what actually arrives; the
# extraction below accepts several plausible spellings so a schema change degrades to a shorter
# line instead of an error.
#
# CONTRACT: always exit 0, always print something short. This runs per row, per refresh — a
# failure here would litter the panel, and a slow one would stall it.

set -u
payload="$(cat 2>/dev/null || true)"

[ "${SUBAGENT_STATUSLINE_DEBUG:-0}" = 1 ] && {
  mkdir -p "$HOME/.claude/debug" 2>/dev/null
  printf '%s\n' "$payload" >> "$HOME/.claude/debug/subagent-statusline.jsonl" 2>/dev/null
}

[ -n "$payload" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

ctx=$(printf '%s' "$payload" | python3 -c '
import sys, json

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)

def dig(*names):
    """First present, non-empty value among several spellings, at top level or one nested level."""
    for n in names:
        if isinstance(d, dict) and d.get(n) not in (None, ""):
            return d[n]
    for v in (d.values() if isinstance(d, dict) else []):
        if isinstance(v, dict):
            for n in names:
                if v.get(n) not in (None, ""):
                    return v[n]
    return None

# Tokens used, under whatever name this version supplies.
used = dig("contextTokens", "context_tokens", "totalTokens", "total_tokens",
           "inputTokens", "input_tokens", "tokens", "contextUsed")
win  = dig("contextWindow", "context_window", "maxTokens", "max_tokens", "windowSize")
pct  = dig("contextPercent", "context_percent", "contextUsage", "percent")

model = dig("model", "modelId", "model_id") or ""
if isinstance(model, dict):
    model = model.get("id") or model.get("name") or ""

out = []

def as_int(x):
    try:    return int(float(x))
    except Exception: return None

p = as_int(pct)
if p is None:
    u, w = as_int(used), as_int(win)
    # No window supplied: infer from the model id the same way agent-fanout does — an explicit
    # [1m] marker wins, then opus/sonnet major >= 4 -> 1M, else the conservative 200k.
    if u is not None and not w:
        m = str(model).lower()
        import re
        if "1m" in re.findall(r"\[([^\]]*)\]", m) or m.endswith("-1m"):
            w = 1_000_000
        else:
            fam = re.search(r"(opus|sonnet)[-_]?(\d+)", m)
            w = 1_000_000 if (fam and int(fam.group(2)) >= 4) else 200_000
    if u is not None and w:
        p = round(100 * u / w)

if p is not None:
    flag = "!" if p >= 90 else ("~" if p >= 80 else "")
    out.append(f"{flag}{p}%")
    u = as_int(used)
    if u:
        out.append(f"{round(u/1000)}k" if u >= 1000 else str(u))

sys.stdout.write(" ".join(out)[:24])
' 2>/dev/null)

# ── current TODO ─────────────────────────────────────────────────────────────────────────
# The in-progress Linear issue(s) for the worktree this agent is working in. Task tracking
# lives in Linear, which has no cheap local state to read, so `/todo` mirrors the id to a
# gitignored per-worktree file and every status surface reads that. Same source as the main
# bar's `statusline-todo.sh` — one mirror, so the panel and the bar cannot disagree.
#
# NO hyperlink here, deliberately: `statusline-todo.sh` wraps the id in an OSC 8 escape for
# ⌘-click, which needs `preserveColors` on a ccstatusline widget. This surface is a plain
# per-row string, so an escape would render as visible garbage in every agent's row.
#
# Resolved from $PWD, which is the spawning session's worktree — the agent's own lane if it
# has one. Silent when nothing is in progress: a row is a few characters wide and "<none>" on
# every line is noise, unlike the main bar where a positive "nothing in progress" is useful.
todo=""
_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$_root" ] && [ -s "$_root/.claude/current-work" ]; then
  _ids="$(cut -f1 < "$_root/.claude/current-work" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
  [ -n "$_ids" ] && todo=" ▸ $_ids"
fi

# ONE line. The panel renders a row per agent, so a trailing newline from the context block
# would split every agent across two rows.
printf '%s%s' "${ctx:-}" "$todo"
exit 0
