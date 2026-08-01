#!/bin/bash
# exec-bit.test.sh — every shipped shell file under claude-config/ is executable IN GIT.
#
# WHY THIS EXISTS, from a live failure on 2026-08-01.
#
# `settings.json` gates its hooks on `[ -x "$h" ]`, so a hook that loses its executable bit
# does not error — it is silently SKIPPED. register-agent.sh went 100755 -> 100644 and the
# whole fleet stopped registering: agents came up "unregistered", no role context was
# injected, and `team-boot.sh status` reported a lane occupied by a nameless pid. Nothing
# printed a warning, because being skipped is what the gate is FOR.
#
# The cause was tooling, not editing: a mutation-test harness wrote `file.bak` with python's
# default 0644 and then `mv`'d it back over the original. Every test still passed, because
# tests invoke these files as `bash <path>` — which does not need the bit. Only the harness
# that runs them for real does.
#
# So the check is on GIT's mode, not the working tree's: the working tree can be repaired by
# hand and the repo still ship 100644 to every other machine. `git ls-files -s` is the
# authority.
#
# Test files are exempt: they are always invoked as `bash <file>.test.sh`, never by path.
#
# Run: bash claude-config/exec-bit.test.sh

set -u
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1

pass=0; fail=0
while read -r mode _ _ path; do
  case "$path" in *.test.sh) continue ;; esac
  if [ "$mode" = 100755 ]; then
    pass=$((pass + 1))
  else
    echo "  FAIL: $path is $mode in git, expected 100755"
    echo "        fix: chmod 755 '$path' && git update-index --chmod=+x '$path'"
    fail=$((fail + 1))
  fi
done < <(git ls-files -s 'claude-config/*.sh' 'claude-config/**/*.sh')

echo
echo "== exec-bit: $pass executable, $fail wrong =="
[ "$fail" = 0 ]
