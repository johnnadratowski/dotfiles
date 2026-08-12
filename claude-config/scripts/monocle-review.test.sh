#!/bin/bash
# Self-contained tests for `monocle-review.sh groups --print-only` — the deterministic
# file→review-layer classifier that decides the ORDER a human reads a diff in.
#
# It had none, and the defect it shipped was invisible for exactly that reason: nothing
# about an applied grouping tells you it grouped WRONG. Observed on the DX-18 review —
# `pnpm-lock.yaml` and the root manifests matched no project rule, fell to a fallback the
# repo config pinned at order 1, and OPENED the review, ahead of the file the change
# existed for. The whole review read as "infra / ui / docs".
#
# Every case below is a way the reading order can lie:
#   - a lockfile ordered ahead of the change's subject
#   - a config-pinned fallback outranking real layers
#   - a fallback bucket wearing a real layer's name
#   - a config-less repo collapsing every file into one bucket instead of grouping by type
#
# Hermetic: scratch git repos in a temp dir (the script resolves its root with
# `git rev-parse`), classified with --print-only so nothing touches a live Monocle review.

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$here/monocle-review.sh"
[ -f "$SCRIPT" ] || { echo "FATAL: monocle-review.sh not found at $SCRIPT"; exit 1; }

pass=0; fail=0
eq(){ if [ "$2" = "$3" ]; then echo "  PASS: $1"; pass=$((pass+1));
      else echo "  FAIL: $1"; echo "        expected: [$2]"; echo "        actual:   [$3]"; fail=$((fail+1)); fi }

T="$(cd "$(mktemp -d)" && pwd -P)"
cleanup(){ rm -rf "$T"; }
trap cleanup EXIT INT TERM

# GIT_DIR is exported by git hooks; unset it or every `git init` below writes into the REAL
# repository. That hazard has corrupted a live worktree before.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

mkrepo(){  # mkrepo <name> [<review-layers.json content>] — echoes the repo path
  local d="$T/$1"
  mkdir -p "$d"
  git -C "$d" init -q 2>/dev/null
  # The fixture's own config must not show up as a changed file — the classifier lists
  # untracked files, and in a real repo review-layers.json is committed.
  printf '.claude/project/review-layers.json\n' > "$d/.git/info/exclude"
  if [ $# -ge 2 ]; then
    mkdir -p "$d/.claude/project"
    printf '%s' "$2" > "$d/.claude/project/review-layers.json"
  fi
  printf '%s' "$d"
}

touchall(){  # touchall <repo> <path>... — create untracked files (the classifier reads them)
  local d="$1"; shift
  local p
  for p in "$@"; do mkdir -p "$d/$(dirname "$p")"; : > "$d/$p"; done
}

# groups <repo> — the classifier's JSON. --print-only NEVER contacts the Monocle engine.
groups(){ (cd "$1" && bash "$SCRIPT" groups --print-only 2>/dev/null); }

# order <repo> — the group names in emitted (reading) order, deduped, space-separated.
order(){ groups "$1" | python3 -c '
import sys, json
seen = []
for e in json.load(sys.stdin):
    if e["group"] not in seen: seen.append(e["group"])
print(" ".join(seen))'; }

# groupof <repo> <path> — "<group>@<group_order>" for one file.
groupof(){ groups "$1" | python3 -c '
import sys, json
want = sys.argv[1]
for e in json.load(sys.stdin):
    if e["path"] == want:
        print("%s@%s" % (e["group"], e["group_order"])); break
else:
    print("<absent>")' "$2"; }

# paths <repo> — every path in emitted order, space-separated.
paths(){ groups "$1" | python3 -c '
import sys, json
print(" ".join(e["path"] for e in json.load(sys.stdin)))'; }

echo "monocle-review.sh groups"

# The goals-onchain config VERBATIM (the one the DX-18 review ran against), trimmed to the
# rules that matter here. Its fallback is pinned at order 1 — the defect's proximate cause.
GOALS_CFG='{
  "rules": [
    {"group":"tests","order":11,"category":"test","regex":"(^|/)(tests?|test-infrastructure|__tests__|e2e)/|\\.(test|spec)\\.[cm]?[jt]sx?$"},
    {"group":"infra","order":1,"category":"config","regex":"^\\.claude/|^\\.github/|^scripts/"},
    {"group":"docs","order":10,"category":"docs","regex":"^docs/|\\.mdx?$"},
    {"group":"api","order":7,"category":"code","regex":"^server/"},
    {"group":"ui","order":9,"category":"code","regex":"^ui-web-b2b/"}
  ],
  "fallback": {"group":"infra","order":1,"category":"config"}
}'

# ── the DX-18 regression: a lockfile must never open the review ──────────────────────────
d="$(mkrepo dx18 "$GOALS_CFG")"
touchall "$d" pnpm-lock.yaml package.json .github/workflows/ci.yml \
              ui-web-b2b/tsconfig.playwright.json docs/guides/development.md
eq "the lockfile is LAST of all, not first" \
   "pnpm-lock.yaml" "$(paths "$d" | awk '{print $NF}')"
eq "the lockfile lands in its own trailing deps group" \
   "deps@13" "$(groupof "$d" pnpm-lock.yaml)"
eq "the change's subject (ui) outranks the unclassified manifests" \
   ".github/workflows/ci.yml ui-web-b2b/tsconfig.playwright.json docs/guides/development.md package.json pnpm-lock.yaml" \
   "$(paths "$d")"

# ── a config-pinned fallback order is IGNORED, and a colliding name is renamed ───────────
eq "an unmatched file sorts after every real layer, not at the config's order 1" \
   "other@12" "$(groupof "$d" package.json)"
eq "the fallback never wears a real layer's name (config said 'infra')" \
   "infra ui docs other deps" "$(order "$d")"

# ── a repo with NO config still groups BY TYPE, not into one bucket ──────────────────────
d="$(mkrepo nocfg)"
touchall "$d" contracts/Goal.sol subgraph/src/handlers.ts server/models/user.ts \
              sdk/ts/client.ts ui-web-b2b/pages/home.js docs/product.md \
              server/migrations/001/run/up.sql types/index.d.ts shared/js/states.js \
              .github/workflows/ci.yml server/tests/user.test.ts pnpm-lock.yaml
eq "the default rules reproduce the canonical by-type order" \
   "infra contracts subgraph db types shared api sdk ui docs tests deps" "$(order "$d")"

# ── within a group: substrate before surface, and it is stable ───────────────────────────
d="$(mkrepo within "$GOALS_CFG")"
touchall "$d" server/routes/goals.ts server/utils/format.ts server/models/goal.ts
eq "within a group, utils → models → routes" \
   "server/utils/format.ts server/models/goal.ts server/routes/goals.ts" "$(paths "$d")"
eq "classification is deterministic across runs" "$(paths "$d")" "$(paths "$d")"

# ── an empty diff is an empty list, not a crash ──────────────────────────────────────────
d="$(mkrepo empty "$GOALS_CFG")"
eq "no changed files ⇒ empty JSON array" "[]" "$(groups "$d")"

# ── a malformed config falls back to the defaults rather than dying ──────────────────────
d="$(mkrepo badcfg '{ this is not json')"
touchall "$d" server/models/user.ts pnpm-lock.yaml
eq "an unparseable review-layers.json degrades to the built-in rules" \
   "api deps" "$(order "$d")"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
