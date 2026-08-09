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

test_lib_inits_a_worktree_with_no_existing_index
test_lib_syncs_a_worktree_with_an_existing_index
test_lib_refuses_when_codegraph_binary_is_absent
test_lib_warns_but_succeeds_when_codegraph_fails
test_lib_bounds_a_hanging_codegraph_and_still_succeeds
test_spawn_inits_a_fresh_task_worktree
test_spawn_syncs_an_already_indexed_task_worktree
test_spawn_refuses_without_codegraph_installed
test_spawn_succeeds_with_a_visible_warning_when_codegraph_fails

echo "# all fm-spawn-codegraph-sync tests passed"
