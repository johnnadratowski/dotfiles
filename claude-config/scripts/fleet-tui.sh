#!/bin/bash
# fleet-tui.sh — the lead's fleet view as a TUI. Companion to fleet-status.sh, not a
# replacement: the table stays the one that works in a pipe, a hook and a CI check.
#
# Usage:
#   fleet-tui.sh [SECS]     refresh every SECS (default 5)
#
# textual is fetched by `uv run` into its own cached environment on first launch — nothing
# is installed into any python on this machine, which is why this is a wrapper rather than a
# `pip install` in a README nobody runs.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v uv >/dev/null 2>&1 || {
  echo "fleet-tui: uv is not installed (brew install uv). Falling back to the table:" >&2
  exec "$HERE/fleet-status.sh" "$@"
}

# --quiet so the dependency resolve does not scribble over the first frame.
exec uv run --quiet "$HERE/fleet_tui.py" "$@"
