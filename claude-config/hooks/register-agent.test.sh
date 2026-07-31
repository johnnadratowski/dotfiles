#!/bin/bash
# Self-contained tests for register-agent.sh's naming behavior — the DX-jn-cc-006
# transient-auto-name race fix. Run: bash .claude/hooks/register-agent.test.sh
#
# Hermetic: every scenario uses a throwaway $HOME + throwaway git repo; `ps` and
# `tmux` are PATH-stubbed; the session file is keyed to $$ so `kill -0` (builtin,
# un-stubbable) sees a genuinely live pid. Exits non-zero on any failure.
#
# Locks in (mutation discipline: delete a guard, exactly its test reddens):
#   - transient session names (<cwd-base>-<2hex>) never become the agent name
#   - a real user-set session name still wins over the branch (the constraint)
#   - settle-recheck fails CLOSED on every env input's failure value
#   - the stale-settle-job clobber (dead pid deleting a successor's entry) is dead
#   - the /rename keystroke fires only on startup sessions; resumes get one
#     bounded retry then skip (never a clobber)
#   - registration's same-name prune (liveness-blind overwrite policy)

set -u
# Captured BEFORE any throwaway-$HOME override: the canonical _fleet.sh now lives in the
# real home (symlinked from dotfiles) and has no repo sibling to fall back to.
REAL_FLEET="$HOME/.claude/scripts/_fleet.sh"
REAL_LAYOUT="$HOME/.claude/scripts/fleet-layout.sh"
here="$(cd "$(dirname "$0")" && pwd)"
HOOK="$here/register-agent.sh"
[ -f "$HOOK" ] || { echo "register-agent.sh not found at $HOOK"; exit 1; }

pass=0; fail=0
ok(){ if eval "$2"; then echo "  PASS: $1"; pass=$((pass+1)); else echo "  FAIL: $1"; fail=$((fail+1)); fi; }

# Same sanitizer register-agent.sh uses.
sanitize(){ printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//'; }

# --- PATH stubs -------------------------------------------------------------
SUITE_T0="$(date +%s)"   # cleanup reaps only settle jobs younger than this run
STUB="$(mktemp -d)"
cat > "$STUB/ps" <<'EOF'
#!/bin/bash
# Test stub. `-o command=` answers ${PS_CMD:-claude}; the tree-walk form gets a
# dead-end parent so the walk terminates fast.
case "$*" in
  *"-o command="*)        printf '%s\n' "${PS_CMD:-claude}" ;;
  *"-o ppid=,command="*)  printf '1 bash\n' ;;
esac
EOF
cat > "$STUB/tmux" <<'EOF'
#!/bin/bash
[ -n "${TMUX_STUB_LOG:-}" ] && echo "$*" >> "$TMUX_STUB_LOG"
exit 0
EOF
chmod +x "$STUB/ps" "$STUB/tmux"

# --- Harness ---------------------------------------------------------------
newhome(){ local h; h="$(mktemp -d)"; mkdir -p "$h/.claude/sessions" "$h/.claude/running-agents" "$h/.claude/agents"; mkdir -p "$h/.claude/scripts"; cp "$REAL_FLEET" "$h/.claude/scripts/_fleet.sh" 2>/dev/null || true; cp "$REAL_LAYOUT" "$h/.claude/scripts/fleet-layout.sh" 2>/dev/null || true; printf '%s' "$h"; }
# A FLEET repo. The hook's opt-in gate requires .claude/workflow.config — without it
# registration exits 0 before doing anything, which is correct behaviour (a dotfiles or
# scratch checkout must never register) but silently invalidated 31 assertions here when
# the gate landed. `newrepo_nofleet` below is the un-opted-in counterpart, so the gate
# itself is now covered rather than merely tripped over.
newrepo(){ local r; r="$(mktemp -d)"; git init -q -b feature-1 "$r"; mkdir -p "$r/.claude"; : > "$r/.claude/workflow.config"; printf '%s' "$r"; }
newrepo_nofleet(){ local r; r="$(mktemp -d)"; git init -q -b feature-1 "$r"; printf '%s' "$r"; }

# run_hook HOME REPO PAYLOAD SOURCE [VAR=val ...] — headless (no tmux vars).
# The caller's environment is a guard input too: a `--name`-launched session
# may export a stale WORKFLOW_AGENT_SKIP_RENAME=1, which used to silently suppress every
# keystroke assertion — strip it (tests opt back in explicitly via "$@").
run_hook(){
  local h="$1" repo="$2" payload="$3" src="$4"; shift 4
  ( cd "$repo" && env -u TMUX -u TMUX_PANE -u WORKFLOW_AGENT_SKIP_RENAME HOME="$h" PATH="$STUB:$PATH" \
      WORKFLOW_AGENT_SETTLE_SECONDS=3600 "$@" bash "$HOOK" "$src" <<<"$payload" )
}
payload(){ printf '{"session_id":"S1","transcript_path":"%s","source":"%s"}' "${2:-/tmp/t.jsonl}" "${1:-resume}"; }
session_json(){ # HOME NAME — write the session file keyed to $$ (live pid for kill -0)
  printf '{"sessionId":"S1","name":"%s"}' "$2" > "$1/.claude/sessions/$$.json"
}
reg_ls(){ ls "$1/.claude/running-agents" 2>/dev/null | sort | tr '\n' ' '; }
reg_snapshot(){ local f; for f in "$1/.claude/running-agents"/*; do [ -f "$f" ] && printf '%s=%s;' "$(basename "$f")" "$(cat "$f")"; done; }
hlog(){ cat "$1/.claude/debug/register-agent.log" 2>/dev/null; }

# settle_env HOME REPO [overrides...] — invoke the settle-recheck verb directly.
settle(){
  local h="$1" repo="$2"; shift 2
  ( cd "$repo" && env -u TMUX -u TMUX_PANE -u WORKFLOW_AGENT_SKIP_RENAME HOME="$h" PATH="$STUB:$PATH" \
      WORKFLOW_AGENT_SETTLE_SECONDS=3600 \
      REGISTER_AGENT_PID="$$" REGISTER_AGENT_BOOT_NAME="feature-1" \
      REGISTER_AGENT_TRANSCRIPT="/tmp/settle-t.jsonl" REGISTER_AGENT_SESSION_SOURCE="resume" \
      "$@" bash "$HOOK" settle-recheck </dev/null )
}
settle_tmux(){
  local h="$1" repo="$2"; shift 2
  ( cd "$repo" && env -u WORKFLOW_AGENT_SKIP_RENAME TMUX=/tmp/fake,1,0 TMUX_PANE='%99' HOME="$h" PATH="$STUB:$PATH" \
      WORKFLOW_AGENT_SETTLE_SECONDS=3600 \
      REGISTER_AGENT_PID="$$" REGISTER_AGENT_BOOT_NAME="feature-1" \
      REGISTER_AGENT_TRANSCRIPT="/tmp/settle-t.jsonl" REGISTER_AGENT_SESSION_SOURCE="resume" \
      "$@" bash "$HOOK" settle-recheck </dev/null )
}
# Seed the post-boot state settle-recheck operates on: registry entry + sidecars
# for boot name feature-1 under OUR headless token (cwd:<repo>).
seed_boot(){ # HOME REPO
  printf 'cwd:%s\n' "$2" > "$1/.claude/running-agents/feature-1.$$"
  printf 'feature-1\n'   > "$1/.claude/agents/feature-1"
  printf '%s\n' "$2"     > "$1/.claude/agents/feature-1.cwd"
  printf '/tmp/old.jsonl\n' > "$1/.claude/agents/feature-1.transcript"
}

echo "== 1. transient session name -> branch wins =="
H="$(newhome)"; R="$(newrepo)"; CB="$(sanitize "$(basename "$R")")"
session_json "$H" "$CB-a3"
run_hook "$H" "$R" "$(payload resume)" sessionstart >/dev/null
ok "registered under branch, not the transient name" '[ "$(reg_ls "$H")" = "feature-1.$$ " ]'
ok "guard logged" 'hlog "$H" | grep -q "transient"'
rm -rf "$H" "$R"

echo "== 2. real user-set session name wins over branch (the constraint) =="
H="$(newhome)"; R="$(newrepo)"
session_json "$H" "researcher"
run_hook "$H" "$R" "$(payload resume)" sessionstart >/dev/null
ok "registered under the session name" '[ "$(reg_ls "$H")" = "researcher.$$ " ]'
rm -rf "$H" "$R"

echo "== 3. fallbacks: no session file -> branch; no git -> cwd basename =="
H="$(newhome)"; R="$(newrepo)"
run_hook "$H" "$R" "$(payload resume)" sessionstart >/dev/null
ok "no session file -> branch" 'reg_ls "$H" | grep -q "^feature-1\."'
rm -rf "$H" "$R"
# Non-git, but opted in: the naming fallback we are pinning here sits DOWNSTREAM of the
# fleet gate, so the directory needs .claude/workflow.config or the hook exits first and
# the assertion passes vacuously for the wrong reason.
H="$(newhome)"; D="$(mktemp -d)"; mkdir -p "$D/.claude"; : > "$D/.claude/workflow.config"
run_hook "$H" "$D" "$(payload resume)" sessionstart >/dev/null
ok "no git -> cwd basename" 'reg_ls "$H" | grep -q "^$(sanitize "$(basename "$D")")\."'
rm -rf "$H" "$D"

echo "== 3a. --agent-name from argv WINS over the branch (the lead-deregistration bug) =="
# A teammate or subagent boots in the LEAD's worktree, on the LEAD's branch, and only moves
# itself afterwards (a reviewer/tester never moves at all). Every filesystem-derived source
# therefore resolves it to the LEAD's identity.
#
# OBSERVED 2026-07-29: subagent `rev-a2` registered as `running-agents/team-lead.75021`, and
# its SessionEnd then matched `team-lead.*` and DEREGISTERED THE LIVE LEAD — leaving an empty
# registry with the lead running, so every registry-first liveness query saw an empty fleet.
#
# Simulated the way lane-guard.test.sh does it: invoke the hook from a parent whose argv really
# contains `--agent-name`, so the process-tree walk under test runs for real rather than stubbed.
# DELIBERATELY NOT ON $STUB's PATH — and this is the point of the case, so do not "fix" it by
# adding $STUB back. That stub replaces `ps`, and its tree-walk form answers a hard-coded
# `1 bash` dead end while the plain `-o ppid=` form is not implemented at all. Under it the
# process-tree walk cannot find anything, so the assertions below would fail against a WORKING
# hook — which is exactly what happened when this case was first written.
#
# The walk is the behaviour under test, so it runs against the REAL `ps`. Only tmux is stubbed
# (via TMUX_ONLY_STUB), because the hook's tmux cosmetics are not what we are pinning here and
# a live tmux call would reach the developer's actual session.
TMUX_ONLY_STUB="$(mktemp -d)"; cp "$STUB/tmux" "$TMUX_ONLY_STUB/tmux"; chmod +x "$TMUX_ONLY_STUB/tmux"
as_agent(){ # as_agent HOME REPO NAME
  local h="$1" repo="$2" nm="$3" wrapper
  wrapper="$(mktemp -d)/fake-claude.sh"
  cat > "$wrapper" <<EOF
#!/bin/bash
cd "$repo" || exit 99
env -u TMUX -u TMUX_PANE HOME="$h" PATH="$TMUX_ONLY_STUB:\$PATH" WORKFLOW_AGENT_SETTLE_SECONDS=3600 \
  bash "$HOOK" sessionstart <<<'$(payload resume)'
EOF
  chmod +x "$wrapper"
  /bin/bash "$wrapper" --agent-name "$nm" >/dev/null 2>&1
}
H="$(newhome)"; R="$(newrepo)"          # branch is feature-1; pretend it is the lead's tree
as_agent "$H" "$R" reviewer-x
ok "registers under --agent-name, NOT the branch" 'reg_ls "$H" | grep -q "^reviewer-x\."'
ok "…and does NOT claim the branch-derived name"  '! reg_ls "$H" | grep -q "^feature-1\."'
ok "…and says so in the log"                      'hlog "$H" | grep -q "authoritative"'
rm -rf "$H" "$R"

# NON-VACUITY: without --agent-name in the tree, the branch fallback must still win. Otherwise
# the two assertions above would pass for a hook that simply never registered anything.
H="$(newhome)"; R="$(newrepo)"
run_hook "$H" "$R" "$(payload resume)" sessionstart >/dev/null
ok "no --agent-name -> branch fallback still applies" 'reg_ls "$H" | grep -q "^feature-1\."'
rm -rf "$H" "$R"

echo "== 3b. fleet opt-in gate (.claude/workflow.config) =="
# A repo without workflow.config is somebody else's checkout — dotfiles, a scratch clone,
# an editor session — and must NOT be registered, renamed, or given role context. This gate
# is what stopped a send-selfheal in ~/git/dotfiles from registering as the peer "master".
H="$(newhome)"; R="$(newrepo_nofleet)"
session_json "$H" "researcher"
run_hook "$H" "$R" "$(payload resume)" sessionstart >/dev/null
ok "non-fleet repo registers NOTHING"        '[ -z "$(reg_ls "$H")" ]'
ok "…and says why in the log"                'grep -q "not a fleet repo" "$H/.claude/debug/register-agent.log"'
ok "…and still exits 0 (never breaks a non-fleet session)" \
   '( cd "$R" && env -u TMUX -u TMUX_PANE HOME="$H" PATH="$STUB:$PATH" bash "$HOOK" sessionstart <<<"$(payload resume)" >/dev/null 2>&1 )'
rm -rf "$H" "$R"
# The same gate must hold on the direct re-entry paths, which skip the settings.json wiring.
H="$(newhome)"; R="$(newrepo_nofleet)"
session_json "$H" "researcher"
run_hook "$H" "$R" "$(payload resume)" send-selfheal >/dev/null
ok "send-selfheal is gated too (the path that leaked 'master')" '[ -z "$(reg_ls "$H")" ]'
rm -rf "$H" "$R"

echo "== 4. guard boundaries =="
for nm_kind in "3hex" "upper" "wrongbase"; do
  H="$(newhome)"; R="$(newrepo)"; CB="$(sanitize "$(basename "$R")")"
  case "$nm_kind" in
    3hex)      nm="$CB-a3f" ;;
    upper)     nm="$CB-A3"  ;;
    wrongbase) nm="otherdir-a3" ;;
  esac
  session_json "$H" "$nm"
  run_hook "$H" "$R" "$(payload resume)" sessionstart >/dev/null
  ok "non-transient lookalike '$nm_kind' still wins" '[ "$(reg_ls "$H")" = "$nm.$$ " ]'
  rm -rf "$H" "$R"
done
# The reserved pattern is reserved DELIBERATELY: a genuine user name matching it
# is treated as transient (documented limitation) -> branch-derived registration.
H="$(newhome)"; R="$(newrepo)"; CB="$(sanitize "$(basename "$R")")"
session_json "$H" "$CB-4f"
run_hook "$H" "$R" "$(payload resume)" sessionstart >/dev/null
ok "reserved-pattern user name -> branch (pinned limitation)" '[ "$(reg_ls "$H")" = "feature-1.$$ " ]'
rm -rf "$H" "$R"

echo "== 5. registration same-name prune (liveness-blind overwrite policy) =="
H="$(newhome)"; R="$(newrepo)"
printf '%%old\n' > "$H/.claude/running-agents/feature-1.99999"
run_hook "$H" "$R" "$(payload resume)" sessionstart >/dev/null
ok "exactly one feature-1 entry survives" \
   '[ "$(ls "$H/.claude/running-agents" | wc -l | tr -d " ")" = 1 ] && reg_ls "$H" | grep -q "^feature-1\." && ! reg_ls "$H" | grep -q "feature-1.99999"'
rm -rf "$H" "$R"

echo "== 6. settle-recheck: settled user name -> full identity swap =="
H="$(newhome)"; R="$(newrepo)"
seed_boot "$H" "$R"
session_json "$H" "researcher"
printf 'main\n' > "$H/.claude/agents/researcher"   # pre-existing user state survives
settle "$H" "$R"
ok "registry swapped boot -> settled" '[ "$(reg_ls "$H")" = "researcher.$$ " ]'
ok "settled .cwd written from env" '[ "$(cat "$H/.claude/agents/researcher.cwd")" = "$R" ]'
ok "settled .transcript written from env" '[ "$(cat "$H/.claude/agents/researcher.transcript")" = "/tmp/settle-t.jsonl" ]'
ok "pre-existing settled base file untouched" '[ "$(cat "$H/.claude/agents/researcher")" = "main" ]'
ok "boot sidecars removed" '[ ! -e "$H/.claude/agents/feature-1" ] && [ ! -e "$H/.claude/agents/feature-1.cwd" ] && [ ! -e "$H/.claude/agents/feature-1.transcript" ]'
rm -rf "$H" "$R"
# Dotted settled name registers SANITIZED (the last dot delimits the pid).
H="$(newhome)"; R="$(newrepo)"
seed_boot "$H" "$R"
session_json "$H" "feat.x"
settle "$H" "$R"
ok "dotted settled name registered sanitized" '[ "$(reg_ls "$H")" = "feat-x.$$ " ]'
rm -rf "$H" "$R"

echo "== 7. settle-recheck fails CLOSED on each input's failure value =="
mk_fail_state(){ H="$(newhome)"; R="$(newrepo)"; seed_boot "$H" "$R"; session_json "$H" "researcher"; SNAP="$(reg_snapshot "$H")"; }
(:) & DEADPID=$!; wait "$DEADPID" 2>/dev/null
mk_fail_state
# The dead pid gets its OWN session file (with a name that would trigger the
# swap) so this case isolates the pid-liveness check — without the file, the
# session-file check would mask a deleted pid guard.
printf '{"sessionId":"OLD","name":"researcher"}' > "$H/.claude/sessions/$DEADPID.json"
settle "$H" "$R" REGISTER_AGENT_PID="$DEADPID"
ok "dead pid -> zero mutation" '[ "$(reg_snapshot "$H")" = "$SNAP" ]'
rm -rf "$H" "$R"
mk_fail_state
settle "$H" "$R" REGISTER_AGENT_PID=""
ok "empty pid -> zero mutation" '[ "$(reg_snapshot "$H")" = "$SNAP" ]'
rm -rf "$H" "$R"
mk_fail_state
settle "$H" "$R" PS_CMD=bash
ok "pid alive but not claude -> zero mutation" '[ "$(reg_snapshot "$H")" = "$SNAP" ]'
rm -rf "$H" "$R"
mk_fail_state
settle "$H" "$R" REGISTER_AGENT_BOOT_NAME=""
ok "empty boot name -> zero mutation" '[ "$(reg_snapshot "$H")" = "$SNAP" ]'
rm -rf "$H" "$R"
mk_fail_state
settle "$H" "$R" REGISTER_AGENT_BOOT_NAME="feat.ure"
ok "unsanitized boot name -> zero mutation" '[ "$(reg_snapshot "$H")" = "$SNAP" ]'
rm -rf "$H" "$R"
mk_fail_state
rm -f "$H/.claude/sessions/$$.json"
SNAP="$(reg_snapshot "$H")"
settle "$H" "$R"
ok "missing session file -> zero mutation" '[ "$(reg_snapshot "$H")" = "$SNAP" ]'
# Zero-mutation alone can't distinguish the guard from the benign fail-open
# (empty settled -> retry path) — pin the guard itself via its log line.
ok "missing session file -> fail-closed (not the retry path)" 'hlog "$H" | grep -q "session file unreadable"'
rm -rf "$H" "$R"

echo "== 8. the stale-settle clobber is dead: successor's entry survives =="
H="$(newhome)"; R="$(newrepo)"
# Session B (us, alive) registered; session A died but left a session file (a
# settled name that WOULD trigger the swap branch) and a scheduled settle job
# carrying its dead pid. Fail-open here = the token-match prune deletes B's
# fresh entry and resurrects a dead registration.
printf 'cwd:%s\n' "$R" > "$H/.claude/running-agents/feature-1.$$"
printf '{"sessionId":"OLD","name":"researcher"}' > "$H/.claude/sessions/$DEADPID.json"
SNAP="$(reg_snapshot "$H")"
settle "$H" "$R" REGISTER_AGENT_PID="$DEADPID"
ok "B's registration survived A's stale settle job" '[ "$(reg_snapshot "$H")" = "$SNAP" ]'
ok "no dead-pid entry resurrected" '! reg_ls "$H" | grep -q "researcher"'
rm -rf "$H" "$R"

echo "== 9. still-transient keystroke: startup types; env cannot suppress it =="
H="$(newhome)"; R="$(newrepo)"; CB="$(sanitize "$(basename "$R")")"
seed_boot "$H" "$R"; session_json "$H" "$CB-d3"
KLOG="$(mktemp)"
settle_tmux "$H" "$R" TMUX_STUB_LOG="$KLOG" REGISTER_AGENT_SESSION_SOURCE="startup"
ok "startup -> /rename typed" 'grep -q -- "-l /rename feature-1" "$KLOG"'
ok "registry untouched (still boot name)" '[ "$(reg_ls "$H")" = "feature-1.$$ " ]'
# WORKFLOW_AGENT_SKIP_RENAME is GONE (it was redundant given `claude --name`, and because it
# rode in the process environment it outlived the startup it was scoped to and suppressed the
# fallback on every later /clear in that pane). Setting it must now do nothing at all —
# otherwise a stale export in someone's shell silently keeps dropping agent names.
: > "$KLOG"
settle_tmux "$H" "$R" TMUX_STUB_LOG="$KLOG" REGISTER_AGENT_SESSION_SOURCE="startup" WORKFLOW_AGENT_SKIP_RENAME=1
ok "a stale SKIP_RENAME=1 export no longer suppresses the keystroke" 'grep -q -- "-l /rename feature-1" "$KLOG"'
rm -f "$KLOG"; rm -rf "$H" "$R"

echo "== 10. still-transient on resume: one bounded retry, then skip — never a keystroke =="
H="$(newhome)"; R="$(newrepo)"; CB="$(sanitize "$(basename "$R")")"
seed_boot "$H" "$R"; session_json "$H" "$CB-d3"
KLOG="$(mktemp)"
settle_tmux "$H" "$R" TMUX_STUB_LOG="$KLOG" REGISTER_AGENT_SESSION_SOURCE="resume"
ok "hop 1: no keystroke" '! grep -q "/rename" "$KLOG"'
ok "hop 1: retry scheduled" 'hlog "$H" | grep -q "retry"'
# DX-jn-cc-018: branch 2 (still-transient resume — the branch-derived-name-on-resume case) must
# STILL re-assert the window label from the registry; the transient auto-name never settles, so
# without this the window stuck on it. Mutation-provable: delete the re-assert → this reddens.
ok "hop 1: re-asserts window labels via name-windows (DX-jn-cc-018)" 'hlog "$H" | grep -q "re-asserted window labels via name-windows"'
settle_tmux "$H" "$R" TMUX_STUB_LOG="$KLOG" REGISTER_AGENT_SESSION_SOURCE="resume" REGISTER_AGENT_SETTLE_RETRY=1
ok "hop 2: no keystroke, gave up" '! grep -q "/rename" "$KLOG" && hlog "$H" | grep -q "skipped"'
ok "registry stays on the boot name (cosmetic label only)" '[ "$(reg_ls "$H")" = "feature-1.$$ " ]'
rm -f "$KLOG"; rm -rf "$H" "$R"

echo "== 11. settled == boot -> no-op =="
H="$(newhome)"; R="$(newrepo)"
seed_boot "$H" "$R"; session_json "$H" "feature-1"
SNAP="$(reg_snapshot "$H")"
settle "$H" "$R"
ok "no-op" '[ "$(reg_snapshot "$H")" = "$SNAP" ]'
rm -rf "$H" "$R"

echo "== 12. sessionstart schedules exactly one settle job — headless, fast path too =="
H="$(newhome)"; R="$(newrepo)"
session_json "$H" "feature-1"
run_hook "$H" "$R" "$(payload resume)" sessionstart >/dev/null
ok "slow path scheduled one job (headless)" '[ "$(hlog "$H" | grep -c "scheduled settle-recheck")" = 1 ]'
run_hook "$H" "$R" "$(payload resume)" sessionstart >/dev/null
ok "fast path scheduled one more" '[ "$(hlog "$H" | grep -c "scheduled settle-recheck")" = 2 ]'
rm -rf "$H" "$R"

echo "== 13. boot-sidecar removal withheld when a foreign token owns the boot name =="
H="$(newhome)"; R="$(newrepo)"
seed_boot "$H" "$R"
printf '%%77\n' > "$H/.claude/running-agents/feature-1.777"   # a live peer's entry
session_json "$H" "researcher"
settle "$H" "$R"
ok "settled entry written" 'reg_ls "$H" | grep -q "researcher.$$"'
ok "foreign feature-1 entry survives" 'reg_ls "$H" | grep -q "feature-1.777"'
ok "boot sidecars withheld" '[ -e "$H/.claude/agents/feature-1" ] && [ -e "$H/.claude/agents/feature-1.cwd" ]'
rm -rf "$H" "$R"

echo "== 14. boot and settle resolve one identity: NAME_PREFIX applies on BOTH sides =="
# rev-a blocker repro: two resolvers for one identity must agree. With a prefix
# configured, boot registers wf-<name>; the settle swap must land on the SAME
# normalized name — and a settled name that normalizes to the boot name is a
# no-op, not an oscillation.
H="$(newhome)"; R="$(newrepo)"
session_json "$H" "researcher"
run_hook "$H" "$R" "$(payload resume)" sessionstart WORKFLOW_AGENT_NAME_PREFIX=wf- >/dev/null
ok "boot registers the prefixed name" '[ "$(reg_ls "$H")" = "wf-researcher.$$ " ]'
SNAP="$(reg_snapshot "$H")"
settle "$H" "$R" WORKFLOW_AGENT_NAME_PREFIX=wf- REGISTER_AGENT_BOOT_NAME="wf-researcher"
ok "settle normalizes to the same name -> no-op (no oscillation)" '[ "$(reg_snapshot "$H")" = "$SNAP" ]'
rm -rf "$H" "$R"
# And when the settled name genuinely differs, the swap lands PREFIXED.
H="$(newhome)"; R="$(newrepo)"
printf 'cwd:%s\n' "$R" > "$H/.claude/running-agents/wf-feature-1.$$"
printf 'wf-feature-1\n' > "$H/.claude/agents/wf-feature-1"
session_json "$H" "researcher"
settle "$H" "$R" WORKFLOW_AGENT_NAME_PREFIX=wf- REGISTER_AGENT_BOOT_NAME="wf-feature-1"
ok "settle swap registers the normalized (prefixed) name" '[ "$(reg_ls "$H")" = "wf-researcher.$$ " ]'
rm -rf "$H" "$R"

echo "== 15. the real retry hop carries the RETRY bound (async, SETTLE_SECONDS=0) =="
# The suite otherwise simulates hop 2 by direct invocation — a dropped
# REGISTER_AGENT_SETTLE_RETRY=1 in the real nohup line would pass the suite but
# retry forever in production (rev-b). Fire the real hop and poll for the
# terminal give-up line.
H="$(newhome)"; R="$(newrepo)"; CB="$(sanitize "$(basename "$R")")"
seed_boot "$H" "$R"; session_json "$H" "$CB-d3"
settle "$H" "$R" WORKFLOW_AGENT_SETTLE_SECONDS=0
WAITED=0
until hlog "$H" | grep -q "after retry" || [ "$WAITED" -ge 20 ]; do sleep 0.25; WAITED=$((WAITED+1)); done
ok "real hop 2 fired and gave up (RETRY bound held)" 'hlog "$H" | grep -q "after retry"'
ok "exactly one retry was scheduled" '[ "$(hlog "$H" | grep -c "retry scheduled")" = 1 ]'
rm -rf "$H" "$R"

echo "== 16. TRANSFORM knob agrees across boot and settle (same class, other knob) =="
# Boot feeds the transform the RAW session name (feature/x); settle must too —
# normalizing the sanitized form (feature-x) makes the transform miss and the
# identity oscillates exactly like the prefix case (rev-b, round 2).
H="$(newhome)"; R="$(newrepo)"
session_json "$H" "feature/x"
run_hook "$H" "$R" "$(payload resume)" sessionstart WORKFLOW_AGENT_NAME_TRANSFORM='s|^feature/||' >/dev/null
ok "boot transform sees the raw name" '[ "$(reg_ls "$H")" = "x.$$ " ]'
SNAP="$(reg_snapshot "$H")"
settle "$H" "$R" WORKFLOW_AGENT_NAME_TRANSFORM='s|^feature/||' REGISTER_AGENT_BOOT_NAME="x"
ok "settle transform sees the raw name too -> no-op (no oscillation)" '[ "$(reg_snapshot "$H")" = "$SNAP" ]'
rm -rf "$H" "$R"
H="$(newhome)"; R="$(newrepo)"
seed_boot "$H" "$R"
session_json "$H" "team/researcher"
settle "$H" "$R" WORKFLOW_AGENT_NAME_TRANSFORM='s|^team/||'
ok "settle swap lands the TRANSFORMED name" '[ "$(reg_ls "$H")" = "researcher.$$ " ]'
rm -rf "$H" "$R"

echo "== 17. transform-to-empty gets the same floor on both sides =="
# A transform can reduce a name to sanitize-empty (name 'feature/', transform
# 's|^feature/||'). Boot floors that to 'agent'; without the same floor in the
# pipeline, settle mutates with an EMPTY name — a hidden '.{pid}' registry file
# invisible to fleet_find_self's glob, i.e. total loss of discoverability
# (rev-a, round 3).
H="$(newhome)"; R="$(newrepo)"
session_json "$H" "feature/"
run_hook "$H" "$R" "$(payload resume)" sessionstart WORKFLOW_AGENT_NAME_TRANSFORM='s|^feature/||' >/dev/null
ok "boot floors the emptied name to 'agent'" '[ "$(reg_ls "$H")" = "agent.$$ " ]'
SNAP="$(reg_snapshot "$H")"
settle "$H" "$R" WORKFLOW_AGENT_NAME_TRANSFORM='s|^feature/||' REGISTER_AGENT_BOOT_NAME="agent"
ok "settle floors identically -> no-op (no oscillation)" '[ "$(reg_snapshot "$H")" = "$SNAP" ]'
# The two hidden-file assertions below own the mutation kill — under a deleted
# floor, boot and settle BOTH write the same hidden entry, so the snapshot
# comparison above passes coincidentally over corrupted state. Do not simplify
# this test down to the snapshot check.
ok "no hidden registry file was written" '[ -z "$(find "$H/.claude/running-agents" -name ".*" -type f)" ]'
ok "no hidden sidecar was written" '[ ! -e "$H/.claude/agents/.cwd" ]'
rm -rf "$H" "$R"

# --- core.bare self-heal (DX-jn-cc-021) ---------------------------------------------------
# The hook re-asserts core.bare=false on the shared common config of a NON-bare clone. Pin all
# three cases so a comparison/scope typo can't silently defeat the fix (it caused a real incident).
echo
echo "core.bare self-heal (DX-jn-cc-021)"
mkH(){ local h; h="$(mktemp -d)"; mkdir -p "$h/.claude/sessions" "$h/.claude/running-agents" "$h/.claude/debug"; printf '%s' "$h"; }
# (a) non-bare clone with core.bare wrongly true → healed to false + logged
CBH="$(mkH)"; CBR="$(newrepo)"; git -C "$CBR" config core.bare true
run_hook "$CBH" "$CBR" "$(payload startup)" sessionstart >/dev/null 2>&1
ok "self-heal flips a non-bare clone core.bare true->false" '[ "$(git -C "$CBR" config --get core.bare)" = false ]'
ok "self-heal logs the reset"                                'grep -q "self-heal: reset core.bare" "$CBH/.claude/debug/register-agent.log"'
# (b) MUTATION KILL: normal operation (already false) → NO write, NO self-heal log
CBH2="$(mkH)"; CBR2="$(newrepo)"
run_hook "$CBH2" "$CBR2" "$(payload startup)" sessionstart >/dev/null 2>&1
ok "self-heal is a no-op when core.bare is already false"    '! grep -q "self-heal: reset core.bare" "$CBH2/.claude/debug/register-agent.log"'
# (c) SCOPE KILL: a genuinely BARE repo (git-dir ends in bare.git, not /.git) is NEVER touched
CBH3="$(mkH)"; CBBARE="$(mktemp -d)/bare.git"; git init -q --bare "$CBBARE"
run_hook "$CBH3" "$CBBARE" "$(payload startup)" sessionstart >/dev/null 2>&1
ok "self-heal leaves a genuinely BARE repo core.bare=true untouched" '[ "$(git -C "$CBBARE" config --get core.bare)" = true ]'
rm -rf "$CBH" "$CBR" "$CBH2" "$CBR2" "$CBH3" "$CBBARE"

# Orphaned settle sleepers from the scheduling tests (3600s) reference THIS hook path — and so
# does every LIVE agent's pending settle job, because settings.json invokes the hook through
# ~/.claude/hooks (a symlink into this directory) and both sides build the path with `cd … &&
# pwd`. The pattern alone is therefore byte-identical to the fleet's, and a bare `pkill -f`
# reaped every agent's pending re-check machine-wide. Age is what distinguishes ours: only a
# process younger than this suite's own runtime can belong to it. A live job scheduled mid-run
# is the residual window, and losing one costs a re-check that gets rescheduled.
for _pid in $(pgrep -f "$HOOK settle-recheck" 2>/dev/null); do
  _age="$(ps -o etimes= -p "$_pid" 2>/dev/null | tr -d ' ')"
  case "$_age" in ''|*[!0-9]*) continue ;; esac
  [ "$_age" -le "$(( $(date +%s) - SUITE_T0 + 5 ))" ] && kill "$_pid" 2>/dev/null
done
rm -rf "$STUB"

echo
echo "== RESULT: $pass passed, $fail failed =="
[ "$fail" = 0 ]
