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
# turn. This must never gate the spawn itself: a missing codegraph binary, a
# failing init/sync, or a hang past the bounded timeout must all fall through
# to a warning, never a blocked launch.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-codegraph-sync-lib.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-codegraph-sync)
BASH_BIN=$(command -v bash)

# --- direct lib tests (fast, no worktree/backend fixtures needed) ----------

# make_fake_codegraph <dir> <behavior> writes a fake `codegraph` binary that
# logs every invocation to $CODEGRAPH_LOG and then behaves per <behavior>:
# ok (exit 0), fail (exit 3), hang (sleeps past any bounded timeout).
make_fake_codegraph() {
  local fakebin behavior=$2
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/codegraph" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "\$1" "\$2" >> "\${CODEGRAPH_LOG:?CODEGRAPH_LOG unset}"
case "$behavior" in
  fail) exit 3 ;;
  hang) sleep 5; exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/codegraph"
  printf '%s\n' "$fakebin"
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

test_lib_is_a_silent_noop_with_no_codegraph_binary() {
  local case_dir wt out status empty_path
  case_dir="$TMP_ROOT/lib-missing-binary"
  wt="$case_dir/wt"
  mkdir -p "$wt" "$case_dir/empty-path"
  empty_path="$case_dir/empty-path"

  out=$(env PATH="$empty_path" "$BASH_BIN" -c ". '$LIB'; fm_spawn_codegraph_sync '$wt'" 2>&1)
  status=$?
  expect_code 0 "$status" "a missing codegraph binary must never fail the caller"
  [ -z "$out" ] || fail "a missing codegraph binary should produce no warning output, got: $out"
  pass "no codegraph on PATH is a silent no-op, never a failure"
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
  expect_code 0 "$status" "a failing codegraph init must never fail the caller"
  assert_contains "$out" "warning: codegraph init failed" "a failing init should warn visibly"
  pass "a failing codegraph call warns loudly but never blocks the caller"
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
  expect_code 0 "$status" "a hanging codegraph call must never fail the caller"
  assert_contains "$out" "warning: codegraph init failed" "a timed-out init should warn visibly"
  [ "$elapsed" -le 4 ] || fail "hanging codegraph took ${elapsed}s to give up - expected close to the 1s bound"
  pass "a hanging codegraph call is bounded by the timeout and still lets the caller continue"
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
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    CODEGRAPH_LOG="$CGLOG" PATH="$FAKEBIN_DIR:$PATH" \
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

# The load-bearing regression: an entirely absent codegraph tool must never
# stop a spawn. Reproduces by omitting the fake codegraph from PATH.
test_spawn_succeeds_without_codegraph_installed() {
  local rec id out status
  id=cgspawn-absent-z3
  rec=$(make_spawn_case spawn-absent "$id")
  read_spawn_record "$rec"
  rm -f "$FAKEBIN_DIR/codegraph"

  out=$(run_case_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn must succeed even with no codegraph binary on PATH"
  assert_contains "$out" "spawned $id" "spawn did not report success without codegraph installed"
  assert_not_contains "$out" "warning: codegraph" "an absent codegraph tool should produce no codegraph warning"
  pass "spawn succeeds unaffected when codegraph is not installed at all"
}

# The other load-bearing regression: codegraph EXISTS but its call fails - the
# spawn must still complete, with a visible (not silent) warning.
test_spawn_succeeds_with_a_visible_warning_when_codegraph_fails() {
  local rec id out status
  id=cgspawn-fail-z4
  rec=$(make_spawn_case spawn-fail "$id")
  read_spawn_record "$rec"
  make_fake_codegraph "$(dirname "$FAKEBIN_DIR")" fail >/dev/null

  out=$(run_case_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn must succeed even when codegraph itself fails"
  assert_contains "$out" "spawned $id" "spawn did not report success when codegraph failed"
  assert_contains "$out" "warning: codegraph init failed" "a failing codegraph call should warn visibly rather than fail silently"
  pass "spawn succeeds with a visible warning when codegraph itself fails"
}

test_lib_inits_a_worktree_with_no_existing_index
test_lib_syncs_a_worktree_with_an_existing_index
test_lib_is_a_silent_noop_with_no_codegraph_binary
test_lib_warns_but_succeeds_when_codegraph_fails
test_lib_bounds_a_hanging_codegraph_and_still_succeeds
test_spawn_inits_a_fresh_task_worktree
test_spawn_syncs_an_already_indexed_task_worktree
test_spawn_succeeds_without_codegraph_installed
test_spawn_succeeds_with_a_visible_warning_when_codegraph_fails

echo "# all fm-spawn-codegraph-sync tests passed"
