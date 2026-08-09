#!/usr/bin/env bash
# Match a task worktree's local CodeGraph index to its checked-out code.
#
# .codegraph/ is gitignored, so it never travels with a `git worktree add`
# clone: a fresh worktree has none, and a reused one still carries whatever
# index sat there before, stale or not. A stale index does not error on
# query - it just answers with outdated symbols as if they were current.
#
# Captain override, 2026-08-09: a missing codegraph binary is not an
# optimization shortfall - the caller must refuse the spawn until codegraph
# is installed, with an actionable install command (exit code 2 below). That
# is the one deliberate spawn gate here. Once codegraph IS installed, a
# failing init/sync or the bounded timeout below stay a best-effort
# optimization exactly as before: both only warn and return 0, letting the
# caller continue with no synced index.
fm_spawn_codegraph_sync() {  # <worktree>
  local wt=$1 timeout_secs=${FM_SPAWN_CODEGRAPH_TIMEOUT:-60} have_timeout=none cmd=init out status=0
  if ! command -v codegraph >/dev/null 2>&1; then
    echo "error: codegraph is not installed, so the CodeGraph index for $wt cannot be matched to its code; install it with 'npm install -g @colbymchenry/codegraph' and retry" >&2
    return 2
  fi
  [ -d "$wt/.codegraph" ] && cmd=sync
  if command -v timeout >/dev/null 2>&1; then have_timeout=timeout
  elif command -v gtimeout >/dev/null 2>&1; then have_timeout=gtimeout
  fi
  if [ "$have_timeout" != none ]; then
    out=$("$have_timeout" "$timeout_secs" codegraph "$cmd" "$wt" 2>&1) && status=0 || status=$?
  else
    out=$(codegraph "$cmd" "$wt" 2>&1) && status=0 || status=$?
  fi
  if [ "$status" -ne 0 ]; then
    echo "warning: codegraph $cmd failed for $wt (exit $status); spawning without a synced index: $out" >&2
  fi
  return 0
}
