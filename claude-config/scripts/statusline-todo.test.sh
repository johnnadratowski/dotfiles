#!/bin/bash
# Self-contained tests for statusline-todo.sh — the ccstatusline segment that renders the
# worktree's in-progress tracker ids from `.claude/current-work`.
#
# It had none until a review pointed out that the file's ONLY parser had just had its
# semantics changed (skip → stop-at-first-non-id) with no coverage and no mutation proof.
# Every case below is a way the bar can lie, and three of them were live defects:
#
#   - a 60-line resume checkpoint under the pointer line rendered INTO the bar
#   - a file with no trailing newline yielded ZERO ids — "<none>" with work in progress
#   - a CRLF-authored file, and an indented `#` comment, each silently dropped ids
#
# Hermetic: fixture worktrees in a temp dir, each a real git repo (the widget resolves its
# root with `git rev-parse`). Output is compared after stripping the OSC 8 hyperlink
# wrapper, so the tests assert what a reader SEES.

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$here/statusline-todo.sh"
[ -f "$SCRIPT" ] || { echo "FATAL: statusline-todo.sh not found at $SCRIPT"; exit 1; }

pass=0; fail=0
eq(){ if [ "$2" = "$3" ]; then echo "  PASS: $1"; pass=$((pass+1));
      else echo "  FAIL: $1"; echo "        expected: [$2]"; echo "        actual:   [$3]"; fail=$((fail+1)); fi }

T="$(cd "$(mktemp -d)" && pwd -P)"
cleanup(){ rm -rf "$T"; }
trap cleanup EXIT INT TERM

# A scratch git repo per case. GIT_DIR is exported by git hooks; unset it or every `git init`
# here writes into the REAL repository (that hazard corrupted a live branch once).
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

mkrepo(){  # mkrepo <name> — echoes the worktree path
  local d="$T/$1"
  mkdir -p "$d/.claude"
  git -C "$d" init -q 2>/dev/null
  printf '%s' "$d"
}

# run <dir> — the widget, with the OSC 8 hyperlink wrapper stripped so we compare visible text.
run(){ (cd "$1" && bash "$SCRIPT" </dev/null 2>/dev/null) | perl -pe 's/\e\]8;;[^\e]*\e\\//g'; }

echo "statusline-todo.sh"

# ── the happy path, and the two "nothing in progress" shapes ─────────────────────────────
d="$(mkrepo happy)"; printf 'FEAT-9\thttps://example.invalid/FEAT-9\n' > "$d/.claude/current-work"
eq "one id with a URL renders the id" "▸ FEAT-9" "$(run "$d")"

d="$(mkrepo two)"; printf 'FEAT-9\thttps://x/9\nSRV-12\thttps://x/12\n' > "$d/.claude/current-work"
eq "two ids render space-separated" "▸ FEAT-9 SRV-12" "$(run "$d")"

d="$(mkrepo noreal)"; : > "$d/.claude/current-work"
eq "an EMPTY mirror renders <none>, not silence" "▸ <none>" "$(run "$d")"

d="$(mkrepo absent)"
eq "an ABSENT mirror also renders <none>" "▸ <none>" "$(run "$d")"

d="$(mkrepo nourl)"; printf 'DX-7\n' > "$d/.claude/current-work"
eq "an id with no URL renders as plain text" "▸ DX-7" "$(run "$d")"

# ── the three silent drops ───────────────────────────────────────────────────────────────
# NO TRAILING NEWLINE. `while read` returns non-zero at EOF-without-newline BEFORE the body
# runs, so the whole file yielded nothing and the bar said "<none>" during live work.
d="$(mkrepo nonl)"; printf 'FEAT-9\thttps://x/9' > "$d/.claude/current-work"
eq "a final line with no trailing newline is still read" "▸ FEAT-9" "$(run "$d")"

d="$(mkrepo crlf)"; printf 'FEAT-9\thttps://x/9\r\nSRV-12\thttps://x/12\r\n' > "$d/.claude/current-work"
eq "a CRLF-authored file does not carry \\r into the URL" "▸ FEAT-9 SRV-12" "$(run "$d")"

# The one that actually bit: with NO url field the CR lands on the ID, and \r IS
# [[:space:]] — so the whitespace test fired `break` and dropped that id and every id
# after it. Two ids, so a passing assertion cannot come from the first one alone.
d="$(mkrepo crlfnourl)"; printf 'DX-7\r\nDX-8\r\n' > "$d/.claude/current-work"
eq "a CRLF id with NO url is not read as whitespace and dropped" "▸ DX-7 DX-8" "$(run "$d")"

d="$(mkrepo indent)"; printf 'FEAT-9\thttps://x/9\n   # indented note\nSRV-12\thttps://x/12\n' > "$d/.claude/current-work"
eq "an INDENTED # comment is skipped, not treated as prose" "▸ FEAT-9 SRV-12" "$(run "$d")"

# ── the checkpoint that ate the status bar ───────────────────────────────────────────────
d="$(mkrepo checkpoint)"
{ printf 'FEAT-6\thttps://example.invalid/FEAT-6\n\n'
  printf '# ---------------------------------------------------------------------------\n'
  printf '# CHECKPOINT — written before a restart.\n'
  printf '# ---------------------------------------------------------------------------\n\n'
  printf '## Where I stopped\n\n'
  printf 'Branch feature-3 @ 7e78f545, clean tree. Implementation was already complete.\n'
} > "$d/.claude/current-work"
eq "a resume checkpoint below the pointer never reaches the bar" "▸ FEAT-6" "$(run "$d")"

# The `continue`-on-blank is what lets a blank line sit BETWEEN two pointer lines.
d="$(mkrepo blankbetween)"; printf 'FEAT-9\thttps://x/9\n\nSRV-12\thttps://x/12\n' > "$d/.claude/current-work"
eq "a blank line between two ids does not end the list" "▸ FEAT-9 SRV-12" "$(run "$d")"

# Prose ENDS the list — everything after it is resume context, however it is punctuated.
d="$(mkrepo prose)"; printf 'FEAT-9\thttps://x/9\nresume prose that is not an id\nSRV-12\thttps://x/12\n' > "$d/.claude/current-work"
eq "prose ends the list — an id after it is NOT picked up" "▸ FEAT-9" "$(run "$d")"

# A single over-long token is not an id either (a URL pasted on its own line, say).
d="$(mkrepo long)"; printf 'FEAT-9\thttps://x/9\nhttps://example.invalid/a/very/long/path/that/is/not/an/id\n' > "$d/.claude/current-work"
eq "an over-long first field ends the list" "▸ FEAT-9" "$(run "$d")"

# ── the hyperlink, which is the whole reason for the OSC 8 escape ────────────────────────
d="$(mkrepo link)"; printf 'FEAT-9\thttps://example.invalid/FEAT-9\n' > "$d/.claude/current-work"
raw="$(cd "$d" && bash "$SCRIPT" </dev/null 2>/dev/null)"
case "$raw" in
  *$'\033]8;;https://example.invalid/FEAT-9\033\\'*) echo "  PASS: the id is wrapped in an OSC 8 hyperlink to its URL"; pass=$((pass+1)) ;;
  *) echo "  FAIL: the id is wrapped in an OSC 8 hyperlink to its URL"; echo "        raw: $(printf '%s' "$raw" | cat -v)"; fail=$((fail+1)) ;;
esac

# ── outside a git repo it must be silent, not noisy ──────────────────────────────────────
out="$(cd "$T" && bash "$SCRIPT" </dev/null 2>&1)"; rc=$?
eq "outside a git repo: exit 0" "0" "$rc"
eq "outside a git repo: no output" "" "$out"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
