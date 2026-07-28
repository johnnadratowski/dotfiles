#!/bin/bash
# Self-contained tests for drain-inbox.sh + the name-sanitization invariant it
# depends on. Run: bash .claude/hooks/drain-inbox.test.sh
#
# Hermetic: every scenario uses a throwaway $HOME so it never touches the real
# registry or inbox. Exits non-zero on any failure (suitable for CI).
#
# Locks in the regressions found in review:
#   - empty-but-existing mailbox must be SILENT (the nullglob/bare-`ls` bug that
#     listed the cwd and blocked every Stop)
#   - filename dot-delimiter parse must recover sender + kind unambiguously,
#     which is only safe because sanitized agent names never contain dots
#   - GC sweeps abandoned messages but never fresh ones
#   - req/rep/fwd map to the right /agent-msg keyword
#   - stop_hook_active guard stays silent
#   - lazy self-heal repairs a missing self-entry, then drains

set -u
# Captured BEFORE any throwaway-$HOME override: the canonical _fleet.sh now lives in the
# real home (symlinked from dotfiles) and has no repo sibling to fall back to.
REAL_FLEET="$HOME/.claude/scripts/_fleet.sh"
here="$(cd "$(dirname "$0")" && pwd)"
HOOK="$here/drain-inbox.sh"
[ -x "$HOOK" ] || { echo "drain-inbox.sh not executable at $HOOK"; exit 1; }

pass=0; fail=0
ok(){ if eval "$2"; then echo "  PASS: $1"; pass=$((pass+1)); else echo "  FAIL: $1"; fail=$((fail+1)); fi; }

# Same sanitizer register-agent.sh uses to produce names.
sanitize(){ printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//'; }

newhome(){ # -> prints a fresh throwaway HOME with one registered self 'testself' on pane %99
  local h; h="$(mktemp -d)"
  mkdir -p "$h/.claude/running-agents" "$h/.claude/agent-inbox/testself"
  mkdir -p "$h/.claude/scripts"
  cp "$REAL_FLEET" "$h/.claude/scripts/_fleet.sh" 2>/dev/null || true
  echo '%99' > "$h/.claude/running-agents/testself.123"
  printf '%s' "$h"
}
run(){ # HOME=$1 : run drain with empty-json stdin from a scratch cwd full of decoys
  local h="$1" cwd; cwd="$(mktemp -d)"; ( cd "$cwd" && touch CLAUDE.md package.json source.ts )
  ( cd "$cwd" && HOME="$h" TMUX_PANE='%99' bash "$HOOK" <<< "${2:-{\}}" )
  rm -rf "$cwd"
}

echo "== name sanitization invariant: output never contains a dot =="
inv_ok=1
for n in "feat/x.y" "peer.pr.2" "a..b" "with spaces.txt" "../evil" "$(printf 'tab\tname')"; do
  s="$(sanitize "$n")"; case "$s" in *.*) inv_ok=0; echo "    LEAK: '$n' -> '$s'";; esac
done
ok "no sanitized name contains '.'" '[ "$inv_ok" = 1 ]'

echo "== empty-but-existing mailbox is silent (the cwd-listing regression) =="
H="$(newhome)"; out="$(run "$H")"
ok "silent" '[ -z "$out" ]'
ok "no repo file leaked" '! printf %s "$out" | grep -qE "CLAUDE.md|package.json|source.ts"'
rm -rf "$H"

echo "== req/rep/fwd parse + ordering + keywords =="
H="$(newhome)"
printf a > "$H/.claude/agent-inbox/testself/u1.peer-1.req.txt"; sleep 0.02
printf b > "$H/.claude/agent-inbox/testself/u2.peer-2.rep.txt"; sleep 0.02
printf c > "$H/.claude/agent-inbox/testself/u3.peer-pr-2.fwd.txt"
reason="$(run "$H" '{}' | jq -r .reason)"
ok "decision=block valid json" '[ "$(run "$H" "{}" | jq -r .decision)" = block ]'
ok "1=req (no keyword), oldest"   'printf %s "$reason" | grep -qE "1\. /agent-msg peer-1 testself/u1.peer-1.req.txt$"'
ok "2=rep -> reply"               'printf %s "$reason" | grep -qE "2\. /agent-msg peer-2 testself/u2.peer-2.rep.txt reply$"'
ok "3=fwd -> followup, sender keeps hyphens" 'printf %s "$reason" | grep -qE "3\. /agent-msg peer-pr-2 testself/u3.peer-pr-2.fwd.txt followup$"'
rm -rf "$H"

echo "== delivery-claim: a FRESH claim defers the drain (kills the duplicate); a STALE claim reclaims =="
backdate(){ touch -A -000300 "$1" 2>/dev/null || touch -d '3 minutes ago' "$1" 2>/dev/null; }  # ~3min ago (BSD||GNU)
H="$(newhome)"; mkdir -p "$H/.claude/agent-nudge-claim"
printf a > "$H/.claude/agent-inbox/testself/uc.peer-1.req.txt"
: > "$H/.claude/agent-nudge-claim/uc.peer-1.req.txt"                       # FRESH claim → a live nudge owns delivery
ok "fresh-claimed message is NOT injected (silent, no duplicate)" '[ -z "$(run "$H")" ]'
backdate "$H/.claude/agent-nudge-claim/uc.peer-1.req.txt"                  # claim ages out (>2min) → nudge presumed lost
ok "stale-claimed message IS delivered (reclaimed, never stranded)" '[ "$(run "$H" "{}" | jq -r .decision)" = block ]'
rm -rf "$H"

echo "== stop_hook_active guard stays silent despite pending =="
H="$(newhome)"; printf x > "$H/.claude/agent-inbox/testself/u.peer-1.req.txt"
out="$(run "$H" '{"stop_hook_active":true}')"
ok "silent" '[ -z "$out" ]'
rm -rf "$H"

echo "== drain clears this agent's busy + error markers on Stop (recovery) =="
H="$(newhome)"; mkdir -p "$H/.claude/agent-busy" "$H/.claude/agent-error"
: > "$H/.claude/agent-busy/testself"; : > "$H/.claude/agent-error/testself"
run "$H" >/dev/null   # empty mailbox is fine; marker clears happen before the mailbox check
ok "busy marker cleared"  '[ ! -f "$H/.claude/agent-busy/testself" ]'
ok "error marker cleared" '[ ! -f "$H/.claude/agent-error/testself" ]'   # a clean Stop = recovered
rm -rf "$H"

echo "== busy marker cleared even on a stop_hook_active continuation (DX-jn-8-025) =="
# Regression: the continuation Stop used to early-exit BEFORE the clear, leaving the
# agent falsely busy → peers suppressed its live nudge. It must clear AND stay silent.
H="$(newhome)"; mkdir -p "$H/.claude/agent-busy"; : > "$H/.claude/agent-busy/testself"
printf x > "$H/.claude/agent-inbox/testself/u.peer-1.req.txt"   # pending, but must NOT re-block
out="$(run "$H" '{"stop_hook_active":true}')"
ok "continuation still cleared busy"          '[ ! -f "$H/.claude/agent-busy/testself" ]'
ok "continuation stayed silent (no re-block)" '[ -z "$out" ]'
rm -rf "$H"

echo "== GC sweeps an 8-day-old orphan, keeps fresh =="
H="$(newhome)"
mkdir -p "$H/.claude/agent-inbox/deadguy"
printf old > "$H/.claude/agent-inbox/deadguy/zz.peer-1.req.txt"
touch -t "$(date -v-8d '+%Y%m%d%H%M' 2>/dev/null || date -d '8 days ago' '+%Y%m%d%H%M')" "$H/.claude/agent-inbox/deadguy/zz.peer-1.req.txt"
printf fresh > "$H/.claude/agent-inbox/testself/keep.peer-1.req.txt"
run "$H" >/dev/null
ok "8-day orphan swept"  '[ ! -f "$H/.claude/agent-inbox/deadguy/zz.peer-1.req.txt" ]'
ok "fresh message kept"  '[ -f "$H/.claude/agent-inbox/testself/keep.peer-1.req.txt" ]'
rm -rf "$H"

echo "== lazy self-heal: missing self-entry is repaired, then drains =="
# Copy drain into a hooks/-shaped dir WITH the ../scripts/_fleet.sh sibling it
# sources (a bare copy left fleet_find_self undefined, so self-id failed even
# after the stub healed the registry), next to a STUB register-agent that
# writes the missing registry entry.
TD="$(mktemp -d)"; mkdir -p "$TD/hooks" "$TD/scripts"
cp "$HOOK" "$TD/hooks/drain-inbox.sh"
_fl="$HOME/.claude/scripts/_fleet.sh"; [ -r "$_fl" ] || _fl="$here/../scripts/_fleet.sh"
cp "$_fl" "$TD/scripts/_fleet.sh"
cat > "$TD/hooks/register-agent.sh" <<'STUB'
#!/bin/bash
# stub: register 'testself' on the current pane, as the real self-heal would
mkdir -p "$HOME/.claude/running-agents"
echo "$TMUX_PANE" > "$HOME/.claude/running-agents/testself.123"
STUB
chmod +x "$TD/hooks/register-agent.sh" "$TD/hooks/drain-inbox.sh"
H="$(mktemp -d)"; mkdir -p "$H/.claude/running-agents" "$H/.claude/agent-inbox/testself"
# NOTE: no registry entry yet — the scan must fail, trigger self-heal, then succeed.
printf hi > "$H/.claude/agent-inbox/testself/m.peer-1.req.txt"
CWD="$(mktemp -d)"
out="$( cd "$CWD" && HOME="$H" TMUX_PANE='%99' bash "$TD/hooks/drain-inbox.sh" <<< '{}' )"
ok "self-healed and produced block" 'printf %s "$out" | jq -e ".decision==\"block\"" >/dev/null'
ok "registry entry was created"     '[ -f "$H/.claude/running-agents/testself.123" ]'
rm -rf "$TD" "$H" "$CWD"

echo "== RESULT: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
