#!/usr/bin/env bash
# Match a task worktree's local CodeGraph indexes to their checked-out code.
#
# .codegraph/ is gitignored, so it never travels with a `git worktree add`
# clone: a fresh worktree has none, and a reused one still carries whatever
# index sat there before, stale or not. A stale index does not error on
# query - it just answers with outdated symbols as if they were current.
#
# An index does not have to sit at the worktree root. `codegraph` resolves a
# query path UPWARD to the nearest enclosing .codegraph/ but never downward,
# so a repository whose code lives in a subdirectory keeps its index beside
# that code (`code/web/.codegraph`) and queries it with a matching path.
# Syncing the worktree root there would build a SECOND index at the root
# while the one the project actually queries stayed stale - exactly the
# silently-stale answer this function exists to prevent. So the root is not
# assumed: every existing index under the worktree is discovered and synced
# where it already lives, because an existing .codegraph/ is the project's
# own answer about where its index belongs.
#
# The rule, in full:
#   - one or more existing indexes -> sync every one of them, create none.
#     Syncing all of them is what keeps the invariant true when a repository
#     holds indexes in more than one place: picking one would leave the
#     others stale and still reachable by a query path resolving to them.
#   - no index anywhere, and the walk that established that was complete ->
#     init the worktree root. A repository that has never been indexed has
#     expressed no preference, so the root is the only defensible default.
#   - an incomplete walk that found nothing -> create nothing. An index may
#     exist in the part that could not be read, and initing the root on that
#     guess is precisely what would strand it as the stale-but-reachable
#     second copy.
# Either way spawn never leaves the worktree holding two indexes where one is
# stale and reachable, and it never has to know a project's layout in advance.
#
# Captain override, 2026-08-09: a missing codegraph binary is not an
# optimization shortfall - the caller must refuse the spawn until codegraph
# is installed, with an actionable install command (exit code 2 below). That
# is the one deliberate spawn gate here. Once codegraph IS installed, a
# failing init/sync, an incomplete discovery walk, or the bounded timeout
# below stay a best-effort optimization exactly as before: all only warn and
# return 0, letting the caller continue with no synced index.
#
# Captain override, 2026-08-09: an index that codegraph itself measures as
# covering only a sliver of the repository is judged worthless and removed
# after the same init or sync that built it, rather than kept around on the
# theory that some coverage beats none. A near-empty graph still costs disk,
# sync time on every later spawn, and - queried through the MCP hook - a
# false sense that the answer is complete when whole subsystems (a shell
# script tree, for example) are invisible to it. The judgment reads only
# codegraph's own measured node and file counts against the subtree's
# tracked file count (fm_codegraph_prune_if_unindexable): never a repository
# or directory name, since that would just be wrong for the next repository.

fm_spawn_codegraph_sync() {  # <worktree>
  local wt=$1 timeout_secs=${FM_SPAWN_CODEGRAPH_TIMEOUT:-60} have_timeout=none
  local listing target complete=1 roots=()
  if ! command -v codegraph >/dev/null 2>&1; then
    echo "error: codegraph is not installed, so the CodeGraph index for $wt cannot be matched to its code; install it with 'npm install -g @colbymchenry/codegraph' and retry" >&2
    return 2
  fi
  if command -v timeout >/dev/null 2>&1; then have_timeout=timeout
  elif command -v gtimeout >/dev/null 2>&1; then have_timeout=gtimeout
  fi

  # A NUL-separated listing has to reach the loop through a file: command
  # substitution drops NUL bytes, which is the one separator a directory
  # name cannot itself contain.
  listing=$(mktemp "${TMPDIR:-/tmp}/fm-codegraph-roots.XXXXXX") || {
    echo "warning: could not create a temp file to enumerate the CodeGraph indexes under $wt; spawning without a synced index" >&2
    return 0
  }
  fm_codegraph_index_roots "$wt" "$have_timeout" "$timeout_secs" \
    > "$listing" 2>/dev/null || complete=0
  while IFS= read -r -d '' target; do
    roots+=("$(dirname "$target")")
  done < "$listing"
  rm -f "$listing"

  if [ ${#roots[@]} -eq 0 ]; then
    if [ "$complete" -eq 0 ]; then
      echo "warning: could not fully enumerate the CodeGraph indexes under $wt; spawning without a synced index rather than risk indexing over one that was not listed" >&2
      return 0
    fi
    fm_codegraph_call init "$wt" "$have_timeout" "$timeout_secs"
    fm_codegraph_prune_if_unindexable "$wt" "$have_timeout" "$timeout_secs"
    return 0
  fi
  # Syncing the indexes that WERE listed is safe even after an incomplete
  # walk, because syncing creates nothing: the worst case is an unlisted
  # index left as stale as the walk found it, never a new one added.
  # Spelled as `if` rather than `test && echo` so the statement cannot itself
  # be the failing command an errexit caller trips on.
  if [ "$complete" -eq 0 ]; then
    echo "warning: could not fully enumerate the CodeGraph indexes under $wt; syncing only the ones that were listed" >&2
  fi
  for target in "${roots[@]}"; do
    fm_codegraph_call sync "$target" "$have_timeout" "$timeout_secs"
    fm_codegraph_prune_if_unindexable "$target" "$have_timeout" "$timeout_secs"
  done
  return 0
}

# Remove <dir>'s CodeGraph index when codegraph's own just-measured result
# shows it covers only a sliver of the subtree: zero nodes (no supported
# language present at all), or a file coverage ratio too small for the graph
# to represent what the subtree actually is. Below FM_CODEGRAPH_MIN_JUDGED_FILES
# tracked files the ratio is noise either way, so small subtrees are left
# alone rather than judged. A status or git failure leaves the index as
# codegraph and the caller already left it - this is a best-effort trim, not
# a second gate.
fm_codegraph_prune_if_unindexable() {  # <dir> <timeout-bin|none> <secs>
  local dir=$1 status_json node_count indexed total
  local min_judged_files=${FM_CODEGRAPH_MIN_JUDGED_FILES:-20}
  local min_coverage_percent=${FM_CODEGRAPH_MIN_COVERAGE_PERCENT:-10}
  status_json=$(fm_codegraph_run "$2" "$3" codegraph status -j "$dir" 2>/dev/null) || return 0
  node_count=$(fm_codegraph_json_number "$status_json" nodeCount)
  indexed=$(fm_codegraph_json_number "$status_json" fileCount)
  [ -n "$node_count" ] && [ -n "$indexed" ] || return 0

  if [ "$node_count" -eq 0 ]; then
    echo "notice: CodeGraph found no supported-language content under $dir; removing the empty index" >&2
    fm_codegraph_run "$2" "$3" codegraph uninit -f "$dir" >/dev/null 2>&1 || true
    return 0
  fi

  total=$(git -C "$dir" ls-files 2>/dev/null | wc -l | tr -d ' ')
  [ -n "$total" ] || return 0
  if [ "$total" -lt "$min_judged_files" ]; then
    return 0
  fi
  if [ $(( indexed * 100 / total )) -lt "$min_coverage_percent" ]; then
    echo "notice: CodeGraph indexed only $indexed of $total tracked files under $dir (under ${min_coverage_percent}% file coverage); removing the low-value index" >&2
    fm_codegraph_run "$2" "$3" codegraph uninit -f "$dir" >/dev/null 2>&1 || true
  fi
  return 0
}

# Print the numeric value of <field> in <json>, or nothing when it is absent
# or not a number. Shells out to node (already required to run codegraph
# itself) rather than adding a jq dependency this script has never needed.
fm_codegraph_json_number() {  # <json> <field>
  node -e '
    let raw = "";
    process.stdin.on("data", (chunk) => { raw += chunk; });
    process.stdin.on("end", () => {
      try {
        const value = JSON.parse(raw)[process.argv[1]];
        if (typeof value === "number") process.stdout.write(String(value));
      } catch {
        // leave stdout empty
      }
    });
  ' "$2" <<<"$1"
}

# Print every existing CodeGraph index root under <worktree>, NUL-separated,
# exiting non-zero when the walk could not be completed.
#
# Prunes .git and node_modules (neither holds an index a worker queries, and
# both dominate the walk), and stops descending into a matched .codegraph/
# itself - its own storage is large and cannot contain another index root.
# Pruning the matched directory does not skip its siblings, so a root index
# and a `code/web` index below it are both found. Deliberately unbounded in
# depth: a depth cap would silently miss a deeper index and then init the
# root beside it, recreating the very defect this discovery removes. The
# walk costs well under a second even on a 30,000-entry clone, and is bound
# by the same timeout that bounds codegraph itself.
fm_codegraph_index_roots() {  # <worktree> <timeout-bin|none> <secs>
  fm_codegraph_run "$2" "$3" find "$1" \
    \( -name .git -o -name node_modules \) -prune -o \
    -type d -name .codegraph -print0 -prune
}

# Run `codegraph <cmd> <dir>` under the resolved bound, warning (never
# failing) on a non-zero exit so the caller keeps spawning either way.
fm_codegraph_call() {  # <cmd> <dir> <timeout-bin|none> <secs>
  local cmd=$1 dir=$2 out status=0
  out=$(fm_codegraph_run "$3" "$4" codegraph "$cmd" "$dir" 2>&1) || status=$?
  if [ "$status" -ne 0 ]; then
    echo "warning: codegraph $cmd failed for $dir (exit $status); spawning without a synced index there: $out" >&2
  fi
  return 0
}

# Run a command under <timeout-bin> when the host has one, unbounded
# otherwise, preserving the command's own exit status.
fm_codegraph_run() {  # <timeout-bin|none> <secs> <cmd> [args...]
  local bin=$1 secs=$2
  shift 2
  if [ "$bin" != none ]; then
    "$bin" "$secs" "$@"
  else
    "$@"
  fi
}
