#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    # Log every send-keys invocation verbatim when a log path is set, so a
    # test can assert exactly what command text was sent into the pane
    # (e.g. `treehouse get` vs a reuse `cd <recorded worktree>`), without
    # changing behavior for callers that never set FM_FAKE_SENDLOG.
    [ -z "${FM_FAKE_SENDLOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_SENDLOG"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile sendlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  sendlog="$case_dir/sendlog"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads|$sendlog"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS SENDLOG <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    FM_FAKE_SENDLOG="$SENDLOG" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read still only
# costs the loop's existing one-second inter-poll sleep to confirm - not an
# extra full cycle on top of that.
test_already_settled_pane_costs_one_confirm_sleep() {
  local rec id out status start end elapsed
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  start=$(date +%s)
  out=$(run_settle_spawn "$id")
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  [ "$elapsed" -le 5 ] || fail "already-settled pane took ${elapsed}s to confirm - expected close to the single inter-poll sleep"
  pass "an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle"
}

# A clean, still-existing recorded worktree holds no unlanded work, so there is
# nothing to lose by acquiring a fresh one: the spawn stays silent and runs an
# ordinary `treehouse get`, exactly as it did before this guard existed. The
# guard deliberately does NOT reuse the recorded worktree - it only refuses
# when work would otherwise be left behind - so the pane must never be sent
# into the recorded path instead.
test_clean_recorded_worktree_gets_fresh_worktree() {
  local rec id out status
  id=settle-reuse-clean-z3
  rec=$(make_settle_case settle-reuse-clean "$id" 0)
  read_settle_record "$rec"
  fm_write_meta "$HOME_DIR/state/$id.meta" "worktree=$WT_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed past a clean recorded worktree"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "treehouse get" "$SENDLOG" \
    "a clean recorded worktree must still acquire a worktree via treehouse get"
  assert_no_grep "^cd " "$SENDLOG" \
    "spawn sent the pane into the recorded worktree instead of acquiring a fresh one"
  pass "a clean recorded worktree does not block the spawn and gets a fresh worktree"
}

# A recorded worktree with uncommitted work must refuse the spawn outright -
# silently acquiring a fresh worktree here is exactly the incident this
# task exists to close (the dead worker's 11 uncommitted files would have been
# orphaned in a worktree nobody was pointed at anymore).
test_recorded_worktree_dirty_refuses_new_worktree() {
  local rec id out status meta_before meta_after
  id=settle-reuse-dirty-z4
  rec=$(make_settle_case settle-reuse-dirty "$id" 0)
  read_settle_record "$rec"
  fm_write_meta "$HOME_DIR/state/$id.meta" "worktree=$WT_DIR"
  meta_before=$(cat "$HOME_DIR/state/$id.meta")
  printf 'uncommitted work\n' >> "$WT_DIR/README.md"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 1 "$status" "spawn must refuse when the recorded worktree has uncommitted work"
  assert_contains "$out" "uncommitted work" "refusal did not explain the uncommitted work"
  assert_contains "$out" "FM_SPAWN_ALLOW_NEW_WORKTREE" \
    "refusal did not name the explicit override for a genuinely fresh worktree"
  assert_absent "$SENDLOG" \
    "spawn sent pane commands despite refusing over the dirty recorded worktree"
  meta_after=$(cat "$HOME_DIR/state/$id.meta")
  [ "$meta_before" = "$meta_after" ] || fail "refused spawn must not rewrite the task's meta"
  pass "a dirty recorded worktree refuses the spawn instead of silently leaving the work behind"
}

# FM_SPAWN_ALLOW_NEW_WORKTREE=1 is the explicit escape hatch: with it set, a
# dirty recorded worktree no longer blocks the spawn, and a fresh worktree is
# acquired instead - leaving the old, uncommitted one untouched on disk.
test_recorded_worktree_dirty_allows_new_worktree_when_explicit() {
  local rec id out status
  id=settle-reuse-dirty-override-z5
  rec=$(make_settle_case settle-reuse-dirty-override "$id" 0)
  read_settle_record "$rec"
  fm_write_meta "$HOME_DIR/state/$id.meta" "worktree=$WT_DIR"
  printf 'uncommitted work\n' >> "$WT_DIR/README.md"

  out=$(FM_SPAWN_ALLOW_NEW_WORKTREE=1 run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "the explicit override should let the spawn proceed"
  assert_grep "treehouse get" "$SENDLOG" \
    "the explicit override should still acquire a fresh worktree via treehouse get"
  assert_present "$WT_DIR/README.md" "the old, dirty worktree must be left on disk untouched"
  pass "the explicit override acquires a fresh worktree and leaves the dirty one in place"
}

# A recorded worktree that no longer exists on disk (returned, pruned, or
# manually removed) holds nothing to lose: fall through to `treehouse get`
# exactly as before, with no explicit override required.
test_recorded_worktree_vanished_gets_fresh_worktree() {
  local rec id out status
  id=settle-reuse-vanished-z6
  rec=$(make_settle_case settle-reuse-vanished "$id" 0)
  read_settle_record "$rec"
  fm_write_meta "$HOME_DIR/state/$id.meta" "worktree=$TMP_ROOT/settle-reuse-vanished/gone-wt"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed falling back to a fresh worktree"
  assert_grep "treehouse get" "$SENDLOG" \
    "spawn did not fall back to treehouse get when the recorded worktree was gone"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the freshly acquired worktree"
  pass "a vanished recorded worktree falls back to a fresh worktree automatically"
}

# A brand new task id, with no prior meta at all, is unaffected: it still
# gets a fresh worktree via treehouse get exactly as before this change.
test_no_recorded_worktree_gets_fresh_worktree() {
  local rec id out status
  id=settle-reuse-none-z7
  rec=$(make_settle_case settle-reuse-none "$id" 0)
  read_settle_record "$rec"
  assert_absent "$HOME_DIR/state/$id.meta" "test setup should start with no recorded meta"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed for a brand new task id"
  assert_grep "treehouse get" "$SENDLOG" \
    "a brand new task id must still acquire a worktree via treehouse get"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the freshly acquired worktree"
  pass "a brand new task id with no recorded worktree gets a fresh one, unchanged"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_clean_recorded_worktree_gets_fresh_worktree
test_recorded_worktree_dirty_refuses_new_worktree
test_recorded_worktree_dirty_allows_new_worktree_when_explicit
test_recorded_worktree_vanished_gets_fresh_worktree
test_no_recorded_worktree_gets_fresh_worktree

echo "# all fm-spawn-worktree-settle tests passed"
