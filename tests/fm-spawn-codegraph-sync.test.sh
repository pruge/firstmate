#!/usr/bin/env bash
# Regression test for bin/fm-codegraph-sync-lib.sh's fm_spawn_codegraph_sync,
# called by bin/fm-spawn.sh right after every ship/scout worktree is validated
# and before the brief is sent (AGENTS.md task spawn-codegraph-sync).
#
# .codegraph/ is gitignored, so it never travels with a `git worktree add`
# clone: a fresh task worktree starts with no index at all, and a reused one
# still carries whatever index sat there before - stale or not. A stale index
# does not error, it just answers with outdated symbols as if they were
# current, so the index must be matched to the code before the worker's first
# turn.
#
# An index does not have to sit at the worktree root: `codegraph` resolves a
# query path upward but never downward, so a repository whose code lives in a
# subdirectory keeps its index beside that code and queries it with a matching
# path. Matching the root there would build a SECOND index while the one the
# project actually queries stayed stale, so the existing index must be found
# and synced wherever it already lives, and a repository holding indexes in
# more than one place must get all of them synced rather than one picked.
#
# A missing codegraph binary is a deliberate spawn gate (captain override,
# 2026-08-09): firstmate must refuse the spawn and say so, with an actionable
# install command, rather than warn and continue. That is the one exception -
# once codegraph IS installed, a failing init/sync or a hang past the bounded
# timeout must both fall through to a warning and let the spawn continue.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-codegraph-sync-lib.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-codegraph-sync)
INSTALL_CMD="npm install -g @colbymchenry/codegraph"

# --- direct lib tests (fast, no worktree/backend fixtures needed) ----------

# make_fake_codegraph <dir> <behavior> writes a fake `codegraph` binary that
# logs every invocation to $CODEGRAPH_LOG and then behaves per <behavior>:
# ok (exit 0), fail (exit 3), hang (sleeps past any bounded timeout).
#
# A successful `init <path>` also creates <path>/.codegraph, matching the real
# binary. That is what lets a test count the indexes left ON DISK rather than
# only the calls made - the defect this file guards is a second index existing,
# which a call log alone cannot show.
make_fake_codegraph() {
  local fakebin behavior=$2
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/codegraph" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "\$1" "\$2" >> "\${CODEGRAPH_LOG:?CODEGRAPH_LOG unset}"
case "$behavior" in
  fail) exit 3 ;;
  hang) sleep 5; exit 0 ;;
  *) [ "\$1" = init ] && mkdir -p "\$2/.codegraph"; exit 0 ;;
esac
SH
  chmod +x "$fakebin/codegraph"
  printf '%s\n' "$fakebin"
}

# count_indexes <dir>: how many .codegraph/ directories the tree holds. The
# invariant under test is that a spawn never leaves more than the project
# already had, so the count is the assertion that matters.
count_indexes() {
  find "$1" -type d -name .codegraph -print -prune 2>/dev/null | wc -l | tr -d ' '
}

expect_indexes() {  # <dir> <expected-count> <msg>
  local actual
  actual=$(count_indexes "$1")
  [ "$actual" = "$2" ] || fail "$3 (expected $2 index/indexes under $1, found $actual)"$'\n'"$(find "$1" -type d -name .codegraph -print -prune 2>/dev/null)"
}

# make_prune_fake_codegraph <dir> <node-count> <file-count> writes a fake
# `codegraph` binary for exercising fm_codegraph_prune_if_unindexable: `init`
# and `sync` behave like the "ok" fake above (log the call, `init` also
# creates <path>/.codegraph), `status -j <path>` logs the call and answers
# with the given nodeCount/fileCount, and `uninit -f <path>` logs the call
# and actually removes <path>/.codegraph - so a test can assert on both what
# was called and what is left on disk afterward.
make_prune_fake_codegraph() {
  local fakebin nodes=$2 files=$3
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/codegraph" <<SH
#!/usr/bin/env bash
log="\${CODEGRAPH_LOG:?CODEGRAPH_LOG unset}"
case "\$1" in
  init) printf 'init %s\n' "\$2" >> "\$log"; mkdir -p "\$2/.codegraph"; exit 0 ;;
  sync) printf 'sync %s\n' "\$2" >> "\$log"; exit 0 ;;
  status) printf 'status %s\n' "\$3" >> "\$log"; printf '{"nodeCount":%s,"fileCount":%s}' "$nodes" "$files"; exit 0 ;;
  uninit) printf 'uninit %s\n' "\$3" >> "\$log"; rm -rf "\$3/.codegraph"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/codegraph"
  printf '%s\n' "$fakebin"
}

# add_tracked_files <dir> <count>: commit <count> more tracked files into the
# git repo/worktree at <dir>, so `git -C <dir> ls-files` reflects a chosen
# total - the coverage judgment reads that count, not codegraph's own.
add_tracked_files() {
  local dir=$1 count=$2 i
  for i in $(seq 1 "$count"); do
    printf 'x' > "$dir/prune-fixture-$i.txt"
  done
  git -C "$dir" add -A
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm "add $count tracked files"
}

test_lib_inits_a_worktree_with_no_existing_index() {
  local case_dir wt fakebin log out status
  case_dir="$TMP_ROOT/lib-init"
  wt="$case_dir/wt"
  mkdir -p "$wt"
  fakebin=$(make_fake_codegraph "$case_dir/fake" ok)
  log="$case_dir/codegraph.log"

  out=$(CODEGRAPH_LOG="$log" PATH="$fakebin:$PATH" bash -c \
    ". '$LIB'; fm_spawn_codegraph_sync '$wt'" 2>&1)
  status=$?
  expect_code 0 "$status" "lib call should succeed for a fresh worktree"
  assert_present "$log" "codegraph was never invoked"
  assert_grep "init $wt" "$log" "a worktree with no .codegraph/ should be init'd, not synced"
  assert_not_contains "$out" "warning:" "an ok init should not warn"
  pass "a worktree with no existing index is init'd"
}

test_lib_syncs_a_worktree_with_an_existing_index() {
  local case_dir wt fakebin log out status
  case_dir="$TMP_ROOT/lib-sync"
  wt="$case_dir/wt"
  mkdir -p "$wt/.codegraph"
  fakebin=$(make_fake_codegraph "$case_dir/fake" ok)
  log="$case_dir/codegraph.log"

  out=$(CODEGRAPH_LOG="$log" PATH="$fakebin:$PATH" bash -c \
    ". '$LIB'; fm_spawn_codegraph_sync '$wt'" 2>&1)
  status=$?
  expect_code 0 "$status" "lib call should succeed for an already-indexed worktree"
  assert_grep "sync $wt" "$log" "a worktree with an existing .codegraph/ should be sync'd, not re-init'd"
  assert_no_grep "init $wt" "$log" "an already-indexed worktree should never be re-init'd"
  pass "a worktree with an existing index is sync'd, matching it to current code"
}

# The subdirectory regression, measured in `gootte` on 2026-08-09: the code
# lives under code/web/, the project's own convention queries with a matching
# path, and its index sits at code/web/.codegraph with none at the root.
# Matching the worktree root there built a fresh SECOND index at the root
# while the one every query resolves to stayed stale - a silently-stale
# answer, which is the whole failure this function exists to prevent.
test_lib_syncs_an_existing_index_below_the_worktree_root() {
  local case_dir wt fakebin log out status
  case_dir="$TMP_ROOT/lib-subdir"
  wt="$case_dir/wt"
  mkdir -p "$wt/code/web/.codegraph" "$wt/code/web/src"
  fakebin=$(make_fake_codegraph "$case_dir/fake" ok)
  log="$case_dir/codegraph.log"

  out=$(CODEGRAPH_LOG="$log" PATH="$fakebin:$PATH" bash -c \
    ". '$LIB'; fm_spawn_codegraph_sync '$wt'" 2>&1)
  status=$?
  expect_code 0 "$status" "lib call should succeed when the index lives below the root"
  assert_grep "sync $wt/code/web" "$log" "the existing index below the root should be synced where it already lives"
  assert_no_grep "init $wt" "$log" "the worktree root must not be indexed alongside an index that already exists below it"
  assert_absent "$wt/.codegraph" "a second index must not appear at the worktree root"
  expect_indexes "$wt" 1 "a repo whose index lives below the root must still hold exactly one index"
  pass "an existing index below the worktree root is synced where it lives, and gains no root index"
}

# The other half of the same rule: a repo that has never been indexed has
# expressed no preference about where its index belongs, so the root is the
# only defensible default - and it must produce exactly one index, not more.
test_lib_creates_exactly_one_index_when_none_exists_anywhere() {
  local case_dir wt fakebin log out status
  case_dir="$TMP_ROOT/lib-none-anywhere"
  wt="$case_dir/wt"
  mkdir -p "$wt/code/web/src" "$wt/services/api"
  fakebin=$(make_fake_codegraph "$case_dir/fake" ok)
  log="$case_dir/codegraph.log"

  out=$(CODEGRAPH_LOG="$log" PATH="$fakebin:$PATH" bash -c \
    ". '$LIB'; fm_spawn_codegraph_sync '$wt'" 2>&1)
  status=$?
  expect_code 0 "$status" "lib call should succeed for a repo with no index anywhere"
  assert_grep "init $wt" "$log" "a repo with no index anywhere should be init'd at its root"
  assert_no_grep "sync " "$log" "there is nothing to sync when no index exists anywhere"
  expect_indexes "$wt" 1 "a repo with no index anywhere must end up with exactly one"
  pass "a repo with no index anywhere ends up with exactly one, at the root"
}

# The case that decides whether the rule is safe: when a repo already holds
# indexes in more than one place, EVERY one is synced. Picking one would leave
# the others stale and still reachable by a query path that resolves to them.
test_lib_syncs_every_index_when_a_repo_holds_more_than_one() {
  local case_dir wt fakebin log out status
  case_dir="$TMP_ROOT/lib-multi"
  wt="$case_dir/wt"
  mkdir -p "$wt/.codegraph" "$wt/code/web/.codegraph"
  fakebin=$(make_fake_codegraph "$case_dir/fake" ok)
  log="$case_dir/codegraph.log"

  out=$(CODEGRAPH_LOG="$log" PATH="$fakebin:$PATH" bash -c \
    ". '$LIB'; fm_spawn_codegraph_sync '$wt'" 2>&1)
  status=$?
  expect_code 0 "$status" "lib call should succeed for a repo holding several indexes"
  assert_grep "sync $wt" "$log" "the root index should be synced"
  assert_grep "sync $wt/code/web" "$log" "the index below the root should be synced too, not left stale and reachable"
  assert_no_grep "init " "$log" "nothing should be init'd when indexes already exist"
  expect_indexes "$wt" 2 "syncing several indexes must not add or remove any"
  pass "a repo holding indexes in more than one place gets all of them synced, and gains none"
}

# Discovery must not be fooled by an index that is not the project's own:
# .git and node_modules never hold an index a worker queries, and treating a
# vendored one as the project's would leave the real index unsynced.
test_lib_ignores_indexes_inside_git_and_node_modules() {
  local case_dir wt fakebin log out status
  case_dir="$TMP_ROOT/lib-vendored"
  wt="$case_dir/wt"
  mkdir -p "$wt/.git/x/.codegraph" "$wt/node_modules/pkg/.codegraph" "$wt/code/web/.codegraph"
  fakebin=$(make_fake_codegraph "$case_dir/fake" ok)
  log="$case_dir/codegraph.log"

  out=$(CODEGRAPH_LOG="$log" PATH="$fakebin:$PATH" bash -c \
    ". '$LIB'; fm_spawn_codegraph_sync '$wt'" 2>&1)
  status=$?
  expect_code 0 "$status" "lib call should succeed while ignoring vendored indexes"
  assert_grep "sync $wt/code/web" "$log" "the project's own index should still be synced"
  assert_no_grep "$wt/node_modules" "$log" "an index inside node_modules is not the project's own"
  assert_no_grep "$wt/.git" "$log" "an index inside .git is not the project's own"
  pass "indexes inside .git and node_modules are ignored, and the project's own is still synced"
}

# The load-bearing regression: an absent codegraph binary must refuse rather
# than silently continue (captain override, 2026-08-09). Reproduces with the
# shared fm_test_path_without_codegraph helper, which strips the shared test
# stub (tests/lib.sh) along with any real codegraph the host happens to have.
test_lib_refuses_when_codegraph_binary_is_absent() {
  local case_dir wt out status no_cg
  case_dir="$TMP_ROOT/lib-missing-binary"
  wt="$case_dir/wt"
  mkdir -p "$wt"
  no_cg=$(fm_test_path_without_codegraph)

  out=$(PATH="$no_cg" bash -c ". '$LIB'; fm_spawn_codegraph_sync '$wt'" 2>&1)
  status=$?
  expect_code 2 "$status" "a missing codegraph binary must refuse with its distinct exit code"
  assert_contains "$out" "error: codegraph is not installed" "a missing codegraph binary should refuse loudly, not silently"
  assert_contains "$out" "$INSTALL_CMD" "the refusal should name the actual install command"
  pass "a missing codegraph binary refuses with an actionable install message"
}

test_lib_warns_but_succeeds_when_codegraph_fails() {
  local case_dir wt fakebin log out status
  case_dir="$TMP_ROOT/lib-failing"
  wt="$case_dir/wt"
  mkdir -p "$wt"
  fakebin=$(make_fake_codegraph "$case_dir/fake" fail)
  log="$case_dir/codegraph.log"

  out=$(CODEGRAPH_LOG="$log" PATH="$fakebin:$PATH" bash -c \
    ". '$LIB'; fm_spawn_codegraph_sync '$wt'" 2>&1)
  status=$?
  expect_code 0 "$status" "a failing codegraph init (binary present) must never fail the caller"
  assert_contains "$out" "warning: codegraph init failed" "a failing init should warn visibly"
  pass "a failing codegraph call (binary present) warns loudly but never blocks the caller"
}

test_lib_bounds_a_hanging_codegraph_and_still_succeeds() {
  local case_dir wt fakebin log out status start end elapsed
  case_dir="$TMP_ROOT/lib-hang"
  wt="$case_dir/wt"
  mkdir -p "$wt"
  fakebin=$(make_fake_codegraph "$case_dir/fake" hang)
  log="$case_dir/codegraph.log"
  if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
    pass "no timeout/gtimeout on this host - bounding behavior cannot be exercised, skipping"
    return 0
  fi

  start=$(date +%s)
  out=$(CODEGRAPH_LOG="$log" PATH="$fakebin:$PATH" FM_SPAWN_CODEGRAPH_TIMEOUT=1 bash -c \
    ". '$LIB'; fm_spawn_codegraph_sync '$wt'" 2>&1)
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 0 "$status" "a hanging codegraph call (binary present) must never fail the caller"
  assert_contains "$out" "warning: codegraph init failed" "a timed-out init should warn visibly"
  [ "$elapsed" -le 4 ] || fail "hanging codegraph took ${elapsed}s to give up - expected close to the 1s bound"
  pass "a hanging codegraph call (binary present) is bounded by the timeout and still lets the caller continue"
}

# --- fm_codegraph_prune_if_unindexable: skip/keep by measured result -------
#
# Captain override, 2026-08-09: an index judged worthless from codegraph's
# own measured node/file counts against the subtree's tracked file count is
# removed rather than kept, never judged by a repository or directory name.
# These pin both directions - a repo actually worth indexing must still keep
# its index - plus the small-subtree floor where the ratio is noise either way.

test_prune_removes_an_index_with_zero_nodes() {
  local case_dir dir fakebin log status
  case_dir="$TMP_ROOT/prune-zero-nodes"
  dir="$case_dir/wt"
  fm_git_init_commit "$dir"
  mkdir -p "$dir/.codegraph"
  fakebin=$(make_prune_fake_codegraph "$case_dir/fake" 0 0)
  log="$case_dir/codegraph.log"

  CODEGRAPH_LOG="$log" PATH="$fakebin:$PATH" bash -c \
    ". '$LIB'; fm_codegraph_prune_if_unindexable '$dir' none 0"
  status=$?
  expect_code 0 "$status" "prune should never fail the caller"
  assert_grep "uninit $dir" "$log" "an index with zero nodes should be uninit'd"
  assert_absent "$dir/.codegraph" "an index covering no supported-language content must not survive"
  pass "an index covering no supported-language content is removed"
}

test_prune_removes_an_index_with_low_file_coverage() {
  local case_dir dir fakebin log status
  case_dir="$TMP_ROOT/prune-low-coverage"
  dir="$case_dir/wt"
  fm_git_init_commit "$dir"
  add_tracked_files "$dir" 40
  mkdir -p "$dir/.codegraph"
  # 41 tracked files total (README + 40); reporting 2 indexed files is ~5%,
  # under the 10% default floor.
  fakebin=$(make_prune_fake_codegraph "$case_dir/fake" 50 2)
  log="$case_dir/codegraph.log"

  CODEGRAPH_LOG="$log" PATH="$fakebin:$PATH" bash -c \
    ". '$LIB'; fm_codegraph_prune_if_unindexable '$dir' none 0"
  status=$?
  expect_code 0 "$status" "prune should never fail the caller"
  assert_grep "uninit $dir" "$log" "an index covering only a sliver of the tracked files should be uninit'd"
  assert_absent "$dir/.codegraph" "an index with low file coverage must not survive"
  pass "an index covering only a sliver of the tracked files is removed"
}

test_prune_keeps_an_index_with_healthy_file_coverage() {
  local case_dir dir fakebin log status
  case_dir="$TMP_ROOT/prune-good-coverage"
  dir="$case_dir/wt"
  fm_git_init_commit "$dir"
  add_tracked_files "$dir" 24
  mkdir -p "$dir/.codegraph"
  # 25 tracked files total (README + 24); reporting 23 indexed files is 92%,
  # well above the 10% default floor.
  fakebin=$(make_prune_fake_codegraph "$case_dir/fake" 100 23)
  log="$case_dir/codegraph.log"

  CODEGRAPH_LOG="$log" PATH="$fakebin:$PATH" bash -c \
    ". '$LIB'; fm_codegraph_prune_if_unindexable '$dir' none 0"
  status=$?
  expect_code 0 "$status" "prune should never fail the caller"
  assert_no_grep "uninit" "$log" "an index covering most of the tracked files must not be removed"
  assert_present "$dir/.codegraph" "an index with healthy file coverage must survive"
  pass "an index covering most of a repository's tracked files is kept"
}

test_prune_leaves_a_small_subtree_unjudged() {
  local case_dir dir fakebin log status
  case_dir="$TMP_ROOT/prune-small-subtree"
  dir="$case_dir/wt"
  # Only the one README.md tracked file - far below FM_CODEGRAPH_MIN_JUDGED_FILES,
  # so a low ratio here is noise, not a verdict.
  fm_git_init_commit "$dir"
  mkdir -p "$dir/.codegraph"
  fakebin=$(make_prune_fake_codegraph "$case_dir/fake" 5 0)
  log="$case_dir/codegraph.log"

  CODEGRAPH_LOG="$log" PATH="$fakebin:$PATH" bash -c \
    ". '$LIB'; fm_codegraph_prune_if_unindexable '$dir' none 0"
  status=$?
  expect_code 0 "$status" "prune should never fail the caller"
  assert_no_grep "uninit" "$log" "a subtree too small to judge must not be pruned on ratio alone"
  assert_present "$dir/.codegraph" "a subtree below the judged-files floor must keep its index"
  pass "a subtree too small to judge keeps its index rather than being judged on noise"
}

test_lib_prunes_a_freshly_built_low_coverage_index_end_to_end() {
  local case_dir wt fakebin log out status
  case_dir="$TMP_ROOT/lib-prune-fresh"
  wt="$case_dir/wt"
  fm_git_init_commit "$wt"
  add_tracked_files "$wt" 40
  fakebin=$(make_prune_fake_codegraph "$case_dir/fake" 50 2)
  log="$case_dir/codegraph.log"

  out=$(CODEGRAPH_LOG="$log" PATH="$fakebin:$PATH" bash -c \
    ". '$LIB'; fm_spawn_codegraph_sync '$wt'" 2>&1)
  status=$?
  expect_code 0 "$status" "spawn sync should succeed even when the freshly built index gets pruned"
  assert_grep "init $wt" "$log" "a worktree with no existing index should still be init'd first"
  assert_grep "uninit $wt" "$log" "the freshly built low-coverage index should be uninit'd right after"
  assert_absent "$wt/.codegraph" "a freshly built low-coverage index must not survive the spawn sync"
  assert_contains "$out" "notice: CodeGraph indexed only 2 of 41 tracked files" \
    "the removal should explain itself with the measured counts"
  pass "a freshly built index covering only a sliver of the repository is removed in the same pass that built it"
}

# --- fm-spawn.sh integration (real spawn, fake tmux/treehouse backend) -----

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:?FM_FAKE_PANE_PATH unset}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_spawn_case <name> <id> builds a home, a primary project with a real
# worktree, and a fake codegraph on the spawn's own PATH that logs every
# invocation - so the assertions below observe exactly what fm-spawn.sh (not
# a hand-rolled stand-in) invoked.
make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin cglog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  cglog="$case_dir/codegraph.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  make_fake_codegraph "$case_dir/fake" ok >/dev/null
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$cglog"
}

read_spawn_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR CGLOG <<EOF
$1
EOF
}

run_case_spawn() {
  local id=$1 path_base=${CGPATH_BASE:-$PATH}
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    CODEGRAPH_LOG="$CGLOG" PATH="$FAKEBIN_DIR:$path_base" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

test_spawn_inits_a_fresh_task_worktree() {
  local rec id out status
  id=cgspawn-init-z1
  rec=$(make_spawn_case spawn-init "$id")
  read_spawn_record "$rec"

  out=$(run_case_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "init $WT_DIR" "$CGLOG" "spawn should have init'd the fresh task worktree's index"
  pass "spawning into a fresh task worktree builds its CodeGraph index"
}

test_spawn_syncs_an_already_indexed_task_worktree() {
  local rec id out status
  id=cgspawn-sync-z2
  rec=$(make_spawn_case spawn-sync "$id")
  read_spawn_record "$rec"
  mkdir -p "$WT_DIR/.codegraph"

  out=$(run_case_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed"
  assert_grep "sync $WT_DIR" "$CGLOG" "spawn should have synced the already-indexed task worktree"
  pass "spawning into an already-indexed task worktree syncs it to current code"
}

# The subdirectory regression at the fm-spawn.sh integration level: a real
# spawn into a worktree whose index lives below the root must sync that index
# and leave no second one at the root.
test_spawn_syncs_an_index_below_the_task_worktree_root() {
  local rec id out status
  id=cgspawn-subdir-z5
  rec=$(make_spawn_case spawn-subdir "$id")
  read_spawn_record "$rec"
  mkdir -p "$WT_DIR/code/web/.codegraph"

  out=$(run_case_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "sync $WT_DIR/code/web" "$CGLOG" "spawn should have synced the index that lives below the worktree root"
  assert_no_grep "init $WT_DIR" "$CGLOG" "spawn must not index the root alongside an index that already exists below it"
  assert_absent "$WT_DIR/.codegraph" "spawn must not leave a second index at the worktree root"
  pass "spawning into a worktree whose index lives below the root syncs that index and adds no root index"
}

# The other load-bearing regression, at the fm-spawn.sh integration level: an
# entirely absent codegraph tool must refuse the spawn, not silently let it
# through. Reproduces by omitting the fake codegraph from PATH and stripping
# any other codegraph (including the shared test stub) from the base PATH too.
test_spawn_refuses_without_codegraph_installed() {
  local rec id out status
  id=cgspawn-absent-z3
  rec=$(make_spawn_case spawn-absent "$id")
  read_spawn_record "$rec"
  rm -f "$FAKEBIN_DIR/codegraph"

  out=$(CGPATH_BASE=$(fm_test_path_without_codegraph) run_case_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn must refuse when no codegraph binary is on PATH, got success"$'\n'"$out"
  assert_not_contains "$out" "spawned $id" "a refused spawn must not report success"
  assert_contains "$out" "error: codegraph is not installed" "a refused spawn should explain why"
  assert_contains "$out" "$INSTALL_CMD" "a refused spawn should name the actual install command"
  pass "spawn refuses when codegraph is not installed at all, with an actionable message"
}

# codegraph EXISTS but its call fails - the spawn must still complete, with a
# visible (not silent) warning. This is the one case that keeps warn-and-continue.
test_spawn_succeeds_with_a_visible_warning_when_codegraph_fails() {
  local rec id out status
  id=cgspawn-fail-z4
  rec=$(make_spawn_case spawn-fail "$id")
  read_spawn_record "$rec"
  make_fake_codegraph "$(dirname "$FAKEBIN_DIR")" fail >/dev/null

  out=$(run_case_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn must succeed when codegraph is present but its own call fails"
  assert_contains "$out" "spawned $id" "spawn did not report success when codegraph's call failed"
  assert_contains "$out" "warning: codegraph init failed" "a failing codegraph call (binary present) should warn visibly rather than fail silently"
  pass "spawn succeeds with a visible warning when codegraph is present but its call fails"
}

# The prune rule at the real fm-spawn.sh integration level: a fresh task
# worktree whose freshly built index covers no supported-language content at
# all must come out of a real spawn with no .codegraph/ left behind.
test_spawn_prunes_a_freshly_built_index_that_covers_nothing() {
  local rec id out status
  id=cgspawn-prune-z6
  rec=$(make_spawn_case spawn-prune "$id")
  read_spawn_record "$rec"
  make_prune_fake_codegraph "$(dirname "$FAKEBIN_DIR")" 0 0 >/dev/null

  out=$(run_case_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed even when the freshly built index gets pruned"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "init $WT_DIR" "$CGLOG" "spawn should still have built the index before judging it"
  assert_grep "uninit $WT_DIR" "$CGLOG" "spawn should have removed the index once it measured no supported content"
  assert_absent "$WT_DIR/.codegraph" "a freshly built index covering nothing must not survive the spawn"
  pass "spawning into a repository with no supported-language content leaves no CodeGraph index behind"
}

test_lib_inits_a_worktree_with_no_existing_index
test_lib_syncs_a_worktree_with_an_existing_index
test_lib_syncs_an_existing_index_below_the_worktree_root
test_lib_creates_exactly_one_index_when_none_exists_anywhere
test_lib_syncs_every_index_when_a_repo_holds_more_than_one
test_lib_ignores_indexes_inside_git_and_node_modules
test_lib_refuses_when_codegraph_binary_is_absent
test_lib_warns_but_succeeds_when_codegraph_fails
test_lib_bounds_a_hanging_codegraph_and_still_succeeds
test_prune_removes_an_index_with_zero_nodes
test_prune_removes_an_index_with_low_file_coverage
test_prune_keeps_an_index_with_healthy_file_coverage
test_prune_leaves_a_small_subtree_unjudged
test_lib_prunes_a_freshly_built_low_coverage_index_end_to_end
test_spawn_inits_a_fresh_task_worktree
test_spawn_syncs_an_already_indexed_task_worktree
test_spawn_syncs_an_index_below_the_task_worktree_root
test_spawn_refuses_without_codegraph_installed
test_spawn_succeeds_with_a_visible_warning_when_codegraph_fails
test_spawn_prunes_a_freshly_built_index_that_covers_nothing

echo "# all fm-spawn-codegraph-sync tests passed"
