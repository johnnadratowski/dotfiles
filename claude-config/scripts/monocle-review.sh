#!/bin/bash
# monocle-review.sh — workflow glue for sending review context to Monocle (DX-jn-8-017).
#
# Monocle reviews the uncommitted working-tree DIFF natively (and renders it
# properly). This script does the two things the agent can't get cleanly from the
# diff itself:
#
#   1. DETECT whether the Monocle engine is live for THIS repo (a clean, scriptable
#      probe — unlike the MCP connection, which flaps).
#   2. SEND the context artifacts that aren't in the diff (the TODO + its plan),
#      keyed by STABLE id so re-sends UPDATE in place instead of piling up.
#
# Retrieving the verdict (the blocking wait) is left to the normal Monocle path —
# the agent's MCP `get_feedback` (wait=true), the `/get-feedback-wait` command, or
# the on-stop hook — so a long human review doesn't run into a Bash-tool timeout.
# (`monocle review get-feedback --wait` exists too, for non-MCP contexts.)
#
# Usage:
#   monocle-review.sh available                 # exit 0 = engine live for this repo, 2 = not running
#   monocle-review.sh list <context> <ID>       # print the artifacts that WOULD be sent (no send)
#   monocle-review.sh send <context> <ID>       # send the context's artifacts (stable ids)
#   monocle-review.sh groups [<base>]           # classify the review diff into the canonical
#                                               #   bottom-up review layers AND APPLY the grouping
#                                               #   (monocle review group-files --replace).
#                                               #   <base> (optional) = the ref given to set_base_ref
#                                               #   for an ALREADY-COMMITTED review; default HEAD
#                                               #   (working-tree). Diffs <base> vs the working tree.
#   monocle-review.sh groups --print-only [<b>] # classify but DON'T apply — emit the JSON only.
#
#   <context> ∈ keys of .claude/monocle-artifacts.json "contexts" (plan | todo | diff)
#   <ID>      = the TODO id (e.g. DX-jn-8-017); resolves docs/todos/<ID>.md (or completed/)
#              and the plan from that TODO's `plan:` frontmatter.
#
# Why `groups` lives in the script (not each agent's head): the classification is
# deterministic and identical for EVERY agent, so a peer agent's diff-review send
# groups the files exactly the same as the author's would.
#
# It APPLIES the grouping rather than printing it for the agent to relay. This used to
# print JSON for `mcp__monocle__set_file_groups`, justified by "the script can't call the
# MCP itself" — true, but `monocle review group-files` is a CLI subcommand and always was.
# The relay made grouping an unverified second step, and nothing ever failed when it was
# skipped: measured 2026-08-04, one lane had never called set_file_groups on any review.
# An ungrouped review looks like a Monocle limitation, not a missed step, so it went
# unreported for weeks.
# Canonical bottom-up order (group_order) runs substrate first, surface last: infra, then
# the project's own layers (schema/data, shared types, service, client, ui), then docs and
# tests. The concrete layer names are the consuming project's, not this script's — but the
# TAIL of the order is the engine's and is not project-overridable:
#
#   … → docs → tests → <fallback: unclassified> → deps (lockfiles)
#
# because both of those buckets are things a reviewer reads LAST, and both used to be able
# to land FIRST. A file that matches no rule is unclassified, so it cannot be the substrate
# the review is read from; a lockfile is a byproduct of the change, never its subject. The
# consuming project may name the fallback group, but not order it.
#
# This is the CATEGORY level only (the inner level under Monocle's N-level grouping).
# For a multi-TODO diff review the AUTHOR wraps each file's category under its TODO id
# as the top "workstream" level (workstream → category) when mapping into
# set_file_groups — that split is not script-derivable pre-commit (no commits: ledger
# yet), so it stays the agent's job; the category level here stays deterministic. A
# single-TODO review uses this output as-is (one level). See the monocle-review skill.
#
# Exit codes: 0 ok · 1 usage/resolution error · 2 Monocle engine not running.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
MONOCLE="${MONOCLE_BIN:-monocle}"
ARTIFACTS_JSON="$ROOT/.claude/monocle-artifacts.json"

_die() { echo "monocle-review: $*" >&2; exit 1; }

# --- detection ---------------------------------------------------------------
# `monocle review status` is a pure probe: it does NOT spawn an engine, and exits
# non-zero with "monocle is not running" when none is up for this repo. The repo's
# socket is derived from the working directory, so just run it in-repo.
mr_available() {
  "$MONOCLE" review status --json >/dev/null 2>&1
}

# --- artifact resolution -----------------------------------------------------
# Resolve the TODO file (active or completed) and the plan path from frontmatter.
# Since the Linear migration only the frozen docs/todos/completed/ files resolve;
# live issues have no file — missing artifacts are skipped with a warning (the
# review proceeds on the diff alone; the Linear issue link goes in the request text).
_todo_file() {
  local id="$1"
  for p in "docs/todos/$id.md" "docs/todos/completed/$id.md"; do
    [ -f "$ROOT/$p" ] && { echo "$p"; return 0; }
  done
  return 1
}

# Emit, for the given context, one TSV line per resolvable artifact:
#   <abs-path>\t<stable-id>\t<type>\t<title>
# Missing files (e.g. a grandfathered TODO with no plan) are skipped with a warning.
_resolve() {
  local context="$1" id="$2"
  [ -f "$ARTIFACTS_JSON" ] || _die "missing $ARTIFACTS_JSON"
  local todo_rel plan_rel
  # Linear-canonical: a LIVE issue has NO repo file, so this lookup is *expected* to miss —
  # only the frozen docs/todos/completed/ archive still resolves (reviewing a pre-migration
  # id). Missing is therefore not fatal: the roles that matter now use {ID} paths under
  # .claude/plans/ and resolve regardless, and the python below already skips any role whose
  # file is absent. This used to `_die`, which made a review of any live Linear issue
  # impossible — contradicting the comment above it.
  todo_rel="$(_todo_file "$id")" || todo_rel=""
  plan_rel=""
  if [ -n "$todo_rel" ]; then
    plan_rel="$(awk -F': *' '/^plan:/ {sub(/^plan: */,""); print; exit}' "$ROOT/$todo_rel")"
  fi

  ROOT="$ROOT" ID="$id" TODO_REL="$todo_rel" PLAN_REL="$plan_rel" \
  python3 - "$ARTIFACTS_JSON" "$context" <<'PY'
import json, os, sys
cfg = json.load(open(sys.argv[1]))
context = sys.argv[2]
root, ID = os.environ["ROOT"], os.environ["ID"]
todo_rel, plan_rel = os.environ["TODO_REL"], os.environ.get("PLAN_REL", "")
roles = cfg["roles"]
order = cfg["contexts"].get(context)
if order is None:
    sys.stderr.write("monocle-review: unknown context '%s' (have: %s)\n" % (context, ", ".join(cfg["contexts"])))
    sys.exit(1)

def expand(tmpl):
    return tmpl.replace("{ID}", ID).replace("{plan}", plan_rel).replace("{todo}", todo_rel)

# A MISSING ARTIFACT IS ANNOUNCED, NOT MURMURED. Every path here is PER-WORKTREE and
# gitignored (.claude/plans/), so the ordinary way to lose one is structural rather than
# careless: another lane authored the plan, so this worktree has no copy of it. The old
# one-line "… not found — skipping" scrolled past inside a send that otherwise reported
# success, and the human then reviewed a plan with no ticket beside it, or a review went out
# with nothing in it at all. Both were observed. So each miss gets a block that names the
# exact path expected and how to put it there.
#
# `plan-diff` is the one EXPECTED absence — round 1 has nothing to diff against — so it stays
# a quiet note. Everything else is loud, and the caller is told the count.
HOWTO = {
    "plan": ("the plan staging file is per-worktree and gitignored, so a plan authored in\n"
             "      ANOTHER LANE does not exist here. Copy it from the authoring lane\n"
             "      (<that-lane>/.claude/plans/{ID}.md), or re-export the Linear plan document\n"
             "      (get_issue {ID} -> documents[] -> get_document) into this path."),
    "issue": ("write a snapshot of the Linear issue to this path before sending —\n"
              "      get_issue {ID}, save its title + description as markdown. Without it the\n"
              "      human reviews the plan with no ticket beside it."),
}
missing_loud = []
for role in order:
    spec = roles.get(role)
    if not spec:
        sys.stderr.write("monocle-review: context '%s' names unknown role '%s'\n" % (context, role)); continue
    rel = expand(spec["path"])
    if not rel:
        sys.stderr.write("monocle-review: role '%s' unresolved (no path) — skipping\n" % role); continue
    ap = os.path.join(root, rel)
    if not os.path.isfile(ap):
        if role == "plan-diff":
            sys.stderr.write("monocle-review: note — no %s at %s (normal on round 1)\n" % (role, rel))
        else:
            missing_loud.append(role)
            howto = HOWTO.get(role, "create the file at that path, then re-run.").replace("{ID}", ID)
            sys.stderr.write(
                "\nmonocle-review: ⚠ MISSING ARTIFACT — '%s' will NOT be sent\n"
                "      expected: %s\n"
                "      how to fix: %s\n\n" % (role, ap, howto))
        continue
    print("\t".join([ap, expand(spec["id"]), spec.get("type", "md"), expand(spec.get("title", role))]))

if missing_loud:
    sys.stderr.write("monocle-review: %d artifact(s) MISSING for context '%s' (%s): %s\n"
                     % (len(missing_loud), context, ID, ", ".join(missing_loud)))
PY
}

# --- commands ----------------------------------------------------------------
cmd="${1:-}"; shift || true
case "$cmd" in
  available)
    if mr_available; then echo "monocle: engine live for this repo"; exit 0
    else echo "monocle: not running for this repo"; exit 2; fi
    ;;
  list)
    [ $# -eq 2 ] || _die "usage: monocle-review.sh list <context> <ID>"
    _resolve "$1" "$2"
    ;;
  send)
    [ $# -eq 2 ] || _die "usage: monocle-review.sh send <context> <ID>"
    mr_available || { echo "monocle: not running — nothing sent (fall back to git diff / peer review)" >&2; exit 2; }
    # Resolve up front so a hard error (unknown context, no TODO file) fails the
    # whole command rather than being swallowed inside the loop's subshell.
    resolved="$(_resolve "$1" "$2")"
    sent=0
    while IFS=$'\t' read -r path id type title; do
      [ -n "$path" ] || continue
      "$MONOCLE" review send-artifact --title "$title" --file "$path" --type "$type" --id "$id" >/dev/null
      echo "  → sent $title  (id=$id)"
      sent=$((sent+1))
    done <<< "$resolved"
    # ZERO RESOLVED IS AN ERROR, NOT A REPORT. It used to print one line and exit 0, which is
    # indistinguishable from a successful send in a transcript — the agent moved on believing
    # the human had the plan. The per-artifact blocks above already say which files are missing
    # and how to produce them; this makes the command fail so the caller cannot miss it.
    [ "$sent" -gt 0 ] || _die "no artifacts resolved for context '$1' ($2) — nothing was sent. See the MISSING ARTIFACT block(s) above."
    echo "monocle: $sent artifact(s) sent/updated for context '$1' ($2)"
    ;;
  groups)
    # Emit set_file_groups entries (JSON) for the review diff, classified into the
    # canonical bottom-up layers. Default: the working-tree diff vs HEAD (uncommitted).
    # Pass a BASE REF — `groups <base>`, the SAME ref given to the set_base_ref MCP tool
    # — to classify an ALREADY-COMMITTED review: we diff <base> vs the working tree, so
    # committed work (and any uncommitted on top) is grouped too. (base=HEAD ⇒ identical
    # to the default working-tree behavior.)
    # The file list rides an env var (NOT stdin) because the python program comes in via
    # the heredoc — piping data into `python3 - <<'PY'` would be overridden by the heredoc.
    # APPLIES the grouping by default. It used to only PRINT JSON for the agent to pipe into
    # the MCP `set_file_groups` tool, on the premise that "the script can't call the MCP
    # itself" — true, and irrelevant: `monocle review group-files` is a CLI subcommand and
    # was available the whole time. That split made grouping an unverified second step, and
    # a step nothing checks is a step that gets skipped: measured 2026-08-04, one lane had
    # never called set_file_groups on any review and nothing ever objected. The reviewer just
    # sees an ungrouped review, which reads as "Monocle doesn't group" rather than "the agent
    # forgot". Applying it here deletes the seam.
    # --print-only restores the old behaviour for anyone who wants the raw JSON.
    apply=1
    if [ "${1:-}" = "--print-only" ]; then apply=0; shift; fi
    base_explicit=0; [ $# -ge 1 ] && base_explicit=1
    base="${1:-HEAD}"
    # THE ARG IS A BASE REF, AND IT IS VALIDATED BEFORE IT IS USED. `groups plan` — a context
    # name, the shape every OTHER subcommand takes — used to be accepted as a ref: the diff
    # below swallows git's error via `|| true`, so the file list came back empty and the
    # command reported "0 changed files vs 'plan'". That reads as a finished review with
    # nothing in it, when it is a usage error. Same for a typo'd SHA or a deleted branch.
    # Only an EXPLICIT arg is checked. The default `HEAD` must still work in a repo with no
    # commits yet, where the untracked-file half of the list is the whole review.
    if [ "$base_explicit" = 1 ] && ! git -C "$ROOT" rev-parse --verify --quiet "$base^{commit}" >/dev/null 2>&1; then
      _die "groups: '$base' is not a commit in this repo.
  'groups' takes a BASE REF (a commit-ish) — the same ref you gave set_base_ref — not a
  context name or an issue id. Examples:
      monocle-review.sh groups                 # working tree vs HEAD (the default)
      monocle-review.sh groups origin/master   # an already-committed review
  If you meant to send context artifacts, that is:  monocle-review.sh send <context> <ID>"
    fi
    files="$(
      {
        git -C "$ROOT" diff --name-only "$base" 2>/dev/null || true
        git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null || true
      } | sort -u
    )"
    # Output goes to a temp file, NOT `entries="$( ... <<'PY' ... )"`. macOS ships bash 3.2,
    # whose parser mishandles a heredoc inside command substitution — `bash -n` accepts it and
    # it dies at RUNTIME with "unexpected EOF while looking for matching )". Verified here.
    mr_json="$(mktemp -t monocle-groups)"
    trap 'rm -f "$mr_json"' EXIT
    FILES="$files" ROOT="$ROOT" python3 - > "$mr_json" <<'PY'
import os, json, re
# Review layers = the project's directory→group classification. SPLIT out of this
# (project-agnostic) engine into the repo's .claude/project/review-layers.json — loaded
# when present so each project describes its own layout; falls back to a minimal generic
# default (tests/docs/infra/other) so any repo groups sanely. group_order is the bottom-up
# display order; regex FIRST-match wins (precedence is NOT the display order).
ROOT = os.environ.get("ROOT", "")
# The generic default set mirrors the canonical BY-FILE-TYPE order the skill documents
# (infra → contracts → subgraph → db → types → shared → api → sdk → ui → docs → tests), so a
# repo with NO review-layers.json still groups by type instead of collapsing into one "code"
# bucket. Paths are the common conventions; a project that names things differently overrides
# the whole set in .claude/project/review-layers.json.
_DEFAULT_RULES = [
    ("tests",    11, "test",   r"(^|/)(tests?|test-infrastructure|__tests__|e2e)/|\.(test|spec)\.[cm]?[jt]sx?$|\.t\.sol$"),
    ("infra",     1, "config", r"^\.claude/|^\.github/|^\.husky/|^\.circleci/|^infra/|^deploy/|^scripts/|(^|/)Dockerfile|docker-compose|^\.env|(^|/)Caddyfile|^[^/]*\.config\.[cm]?[jt]s$|^[^/]*\.(ya?ml|toml)$|^[^/]*rc(\.[a-z]+)?$"),
    ("docs",     10, "docs",   r"^docs/|\.mdx?$"),
    ("contracts", 2, "code",   r"^contracts?/|\.sol$"),
    ("subgraph",  3, "code",   r"^(subgraph|indexer|ponder)/"),
    ("db",        4, "code",   r"(^|/)migrations?/|(^|/)fixtures?/|\.sql$"),
    ("types",     5, "code",   r"^types/|\.d\.ts$"),
    ("shared",    6, "code",   r"^shared/|^common/"),
    ("api",       7, "code",   r"^(server|api|backend)/"),
    ("sdk",       8, "code",   r"^sdk/|^packages?/sdk/"),
    ("ui",        9, "code",   r"^(ui|web|frontend|client)[^/]*/"),
]
_DEFAULT_FALLBACK = ("other", "other")

# Lockfiles are classified by the ENGINE, ahead of any project rule, into a `deps` group
# ordered DEAD LAST. They are never what a change is ABOUT — they are a byproduct of it —
# and every plausible per-repo regex swept them somewhere wrong: goals-onchain's config had
# no rule for them, so `pnpm-lock.yaml` fell to a fallback pinned at order 1 and opened the
# whole review, AHEAD of the file the change existed for (observed on the DX-18 review).
_LOCKFILE_RE = re.compile(
    r"(^|/)(pnpm-lock\.yaml|package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|bun\.lockb?"
    r"|Cargo\.lock|poetry\.lock|uv\.lock|Pipfile\.lock|Gemfile\.lock|composer\.lock"
    r"|go\.sum|flake\.lock)$"
)

def _load_layers():
    path = os.path.join(ROOT, ".claude", "project", "review-layers.json")
    try:
        with open(path) as f:
            data = json.load(f)
        rules = [(r["group"], int(r["order"]), r["category"], r["regex"]) for r in data["rules"]]
        fb = data.get("fallback")
        fallback = (fb["group"], fb.get("category", "other")) if fb else _DEFAULT_FALLBACK
        return (rules or _DEFAULT_RULES), (fallback if rules else _DEFAULT_FALLBACK)
    except (OSError, ValueError, KeyError, TypeError):
        return _DEFAULT_RULES, _DEFAULT_FALLBACK
RULES, _FB = _load_layers()

# An unmatched file is BY DEFINITION unclassified, so it can never be the substrate the
# reviewer should read first — the engine always places the fallback bucket after every
# real layer, and a config's `fallback.order` is deliberately ignored. (goals-onchain's
# pinned it to order 1, which is how `.husky/`, root manifests and the lockfile came to
# open a review whose subject was elsewhere.) A fallback whose name collides with a real
# rule group is renamed `other`, so the trailing bucket cannot masquerade as that layer.
_MAX_ORDER = max(o for _, o, _, _ in RULES)
_RULE_GROUPS = {g for g, _, _, _ in RULES}
FALLBACK = (_FB[0] if _FB[0] not in _RULE_GROUPS else "other", _MAX_ORDER + 1, _FB[1])
DEPS = ("deps", _MAX_ORDER + 2, "config")

def classify(p):
    if _LOCKFILE_RE.search(p):
        return DEPS
    for g, o, c, rx in RULES:
        if re.search(rx, p):
            return g, o, c
    return FALLBACK

# --- within-group ordering: call hierarchy (low-level → high-level) ---
# A file is listed AFTER everything it imports, so the reviewer reads the
# foundational units first (utils → models → routes). Implemented as a topological
# sort over the intra-group import graph; files with no edge between them are broken
# by a layer-rank heuristic (utils < models < services < middleware < routes < entry
# < scripts), then path, so the order is deterministic.
def layer_rank(p):
    for r, rx in [
        (0, r"/(utils?|helpers?|lib)/|(util|helper|constant|template)s?\.[cm]?[jt]sx?$"),
        (1, r"/(types|schema)/|\.d\.ts$|generated"),
        (2, r"/models?/"),
        (3, r"/(services|clients|integrations|providers)/"),
        (4, r"(^|/)(middleware|ratelimit)|/(guards?)/"),
        (5, r"/(routes|controllers|handlers|api|pages|views|components)/"),
        (6, r"(^|/)(server|app|main)\.[cm]?[jt]sx?$"),
        (7, r"/(scripts|cli|bin|admin)/"),
    ]:
        if re.search(rx, p):
            return r
    return 5

_IMPORT_RE = re.compile(
    r"""(?:import|export)\s[^'"]*?from\s*['"]([^'"]+)['"]"""
    r"""|require\(\s*['"]([^'"]+)['"]\s*\)"""
    r"""|import\(\s*['"]([^'"]+)['"]\s*\)"""
)
_EXTS = (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".d.ts", ".sql")

def _resolve(importer, spec, fileset):
    if not spec.startswith("."):  # only intra-repo relative imports can be in the set
        return None
    target = os.path.normpath(os.path.join(os.path.dirname(importer), spec))
    stem = re.sub(r"\.(js|ts|jsx|tsx|mjs|cjs)$", "", target)
    for cand in [stem + e for e in _EXTS] + [stem + "/index" + e for e in _EXTS] + [target]:
        if cand in fileset:
            return cand
    return None

def deps_within(path, group_set):
    try:
        with open(os.path.join(ROOT, path), encoding="utf-8", errors="ignore") as fh:
            txt = fh.read()
    except OSError:
        return set()
    out = set()
    for m in _IMPORT_RE.finditer(txt):
        spec = m.group(1) or m.group(2) or m.group(3)
        r = _resolve(path, spec, group_set)
        if r and r != path:
            out.add(r)
    return out

def topo_order(paths):
    group_set = set(paths)
    deps = {p: deps_within(p, group_set) for p in paths}
    ordered, emitted = [], set()
    remaining = set(paths)
    while remaining:
        ready = [p for p in remaining if deps[p] <= emitted]
        if not ready:  # import cycle — break it deterministically
            ready = list(remaining)
        ready.sort(key=lambda p: (layer_rank(p), p))
        nxt = ready[0]
        ordered.append(nxt)
        emitted.add(nxt)
        remaining.discard(nxt)
    return ordered

buckets = {}
for line in os.environ.get("FILES", "").splitlines():
    p = line.strip()
    if not p:
        continue
    g, o, c = classify(p)
    buckets.setdefault((o, g, c), []).append(p)
entries = []
for (o, g, c), paths in sorted(buckets.items()):
    for i, p in enumerate(topo_order(paths)):
        entries.append({"path": p, "group": g, "group_order": o, "sort_index": i, "category": c})
print(json.dumps(entries, indent=2))
PY
    if [ "$apply" -eq 0 ]; then cat "$mr_json"; exit 0; fi
    mr_available || { echo "monocle: not running — nothing grouped" >&2; exit 2; }
    n="$(python3 -c 'import sys,json; print(len(json.load(open(sys.argv[1]))))' "$mr_json")"
    if [ "$n" -eq 0 ]; then
      # Say so out loud. A silent no-op here is indistinguishable from success, and the whole
      # reason this subcommand changed is that an invisible skip looked like a working feature.
      echo "monocle: 0 changed files vs '$base' — nothing to group (is the base ref right?)" >&2
      exit 0
    fi
    "$MONOCLE" review group-files --file="$mr_json" --replace >/dev/null
    echo "monocle: grouped $n file(s) vs '$base' (reviewer presses 'f' for the grouped view)"
    ;;
  *)
    _die "usage: monocle-review.sh {available|list|send|groups} [<context> <ID>]"
    ;;
esac
