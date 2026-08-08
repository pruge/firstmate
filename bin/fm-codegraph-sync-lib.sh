#!/usr/bin/env bash
# Match a task worktree's local CodeGraph index to its checked-out code.
#
# .codegraph/ is gitignored, so it never travels with a `git worktree add`
# clone: a fresh worktree has none, and a reused one still carries whatever
# index sat there before, stale or not. A stale index does not error on
# query - it just answers with outdated symbols as if they were current.
#
# Optimization only, never a spawn gate: no codegraph binary, a failing
# init/sync, or the bounded timeout below all fall through to a warning and
# let the caller continue with no synced index.
fm_spawn_codegraph_sync() {  # <worktree>
  local wt=$1 timeout_secs=${FM_SPAWN_CODEGRAPH_TIMEOUT:-60} have_timeout=none cmd=init out status=0
  command -v codegraph >/dev/null 2>&1 || return 0
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
