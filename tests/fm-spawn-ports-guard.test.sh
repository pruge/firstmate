#!/usr/bin/env bash
# Regression test for fm-spawn.sh's port-contract guard (AGENTS.md task
# spawn-ports-bypass-guard): a project that carries its own
# code/web/.ports.main (bin/fm-worktree-runtime-lib.sh's
# FM_WORKTREE_RUNTIME_WEB_REL) must not be launched with neither
# --backend-port nor --frontend-port and no --no-ports - that silently left a
# live worktree occupying a dev port pair with no line in the global port
# ledger (2026-08-10 incident). A project with no such contract file stays the
# same silent no-op it always was - checked here against a real tree with no
# .ports.main present, never inferred from project name or path shape.
#
# The refusal fires at argument-validation time, right after the project path
# resolves and before any worktree or backend window/session is created, so
# these assertions stop at "no meta was written and nothing was sent to the
# backend" - never a real worktree move or launched process.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-ports-guard)

make_ports_guard_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_SENDLOG:-}" ]; then
      printf '%s\n' "$*" >> "$FM_FAKE_SENDLOG"
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse claude
  printf '%s\n' "$fakebin"
}

# make_ports_guard_case <name> <id> [--with-contract]: a home plus a real
# project/worktree pair. --with-contract seeds the project's own
# code/web/.ports.main so the project counts as port-contract-carrying.
make_ports_guard_case() {
  local name=$1 id=$2 with_contract=${3:-} case_dir home proj wt fakebin sendlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  sendlog="$case_dir/send.log"
  fakebin=$(make_ports_guard_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  if [ "$with_contract" = --with-contract ]; then
    mkdir -p "$proj/code/web"
    {
      printf 'BACKEND_PORT=8802\n'
      printf 'FRONTEND_PORT=5302\n'
    } > "$proj/code/web/.ports.main"
  fi
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$sendlog"
}

read_ports_guard_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR SEND_LOG <<EOF
$1
EOF
}

run_ports_guard_spawn() {
  local id=$1
  shift
  : > "$SEND_LOG"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' FM_FAKE_SENDLOG="$SEND_LOG" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off "$@" 2>&1
}

# --- 1. contract present + neither port flag given -> refused ----------------

test_contract_present_no_ports_is_refused() {
  local rec id out status
  id=ports-guard-refuse-z1
  rec=$(make_ports_guard_case ports-guard-refuse "$id" --with-contract)
  read_ports_guard_record "$rec"

  out=$(run_ports_guard_spawn "$id")
  status=$?
  expect_code 1 "$status" "a port-contract project with neither port flag must be refused"
  assert_contains "$out" "has a port contract" "refusal did not name the port contract"
  assert_contains "$out" "code/web/.ports.main" "refusal did not name the contract file"
  assert_contains "$out" "--no-ports" "refusal did not name the explicit escape hatch"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not write task metadata"
  [ ! -s "$SEND_LOG" ] || fail "a refused spawn must never send anything to the backend (got: $(cat "$SEND_LOG"))"
  pass "a port-contract project refuses to launch with neither --backend-port nor --frontend-port"
}

# --- 2. contract ABSENT + neither port flag given -> silent pass (the vast
# majority of projects, firstmate's own worktrees included) ------------------

test_no_contract_no_ports_still_passes_silently() {
  local rec id out status
  id=ports-guard-nocontract-z2
  rec=$(make_ports_guard_case ports-guard-nocontract "$id")
  read_ports_guard_record "$rec"
  [ ! -e "$PROJ_DIR/code/web/.ports.main" ] || fail "test setup leaked a contract file for the no-contract case"

  out=$(run_ports_guard_spawn "$id")
  status=$?
  expect_code 0 "$status" "a project with no port contract and no port flags must still launch"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_absent "$HOME_DIR/state/$id/code/web/.ports.worktree" "no ports.worktree should exist without a contract"
  pass "a project with no port contract file launches with neither port flag exactly as before"
}

# --- 3. contract present + both ports given -> passes, pair written ---------

test_contract_present_both_ports_given_passes() {
  local rec id out status
  id=ports-guard-both-z3
  rec=$(make_ports_guard_case ports-guard-both "$id" --with-contract)
  read_ports_guard_record "$rec"

  out=$(run_ports_guard_spawn "$id" --backend-port 8902 --frontend-port 5402)
  status=$?
  expect_code 0 "$status" "a port-contract project with both ports given must launch"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "BACKEND_PORT=8902" "$WT_DIR/code/web/.ports.worktree" \
    "the given backend port was not written to .ports.worktree"
  assert_grep "FRONTEND_PORT=5402" "$WT_DIR/code/web/.ports.worktree" \
    "the given frontend port was not written to .ports.worktree"
  pass "a port-contract project launches normally when both --backend-port and --frontend-port are given"
}

# --- 4. contract present + --no-ports -> passes, and a stale .ports.worktree
# from a recycled worktree is actively removed, not silently inherited -------

test_no_ports_escape_hatch_passes_and_clears_stale_file() {
  local rec id out status
  id=ports-guard-noflag-z4
  rec=$(make_ports_guard_case ports-guard-noflag "$id" --with-contract)
  read_ports_guard_record "$rec"

  # Simulate a recycled worktree still carrying a stale pair from a prior
  # occupant (gitignored, so `treehouse get` reusing the same physical
  # directory would otherwise leave it untouched).
  mkdir -p "$WT_DIR/code/web"
  {
    printf 'BACKEND_PORT=8907\n'
    printf 'FRONTEND_PORT=5408\n'
  } > "$WT_DIR/code/web/.ports.worktree"

  out=$(run_ports_guard_spawn "$id" --no-ports)
  status=$?
  expect_code 0 "$status" "--no-ports must let a port-contract project launch with neither port flag"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  [ ! -e "$WT_DIR/code/web/.ports.worktree" ] \
    || fail "--no-ports must actively remove a stale .ports.worktree left by a recycled worktree, not silently inherit it"
  pass "--no-ports launches a port-contract project and clears a stale .ports.worktree from a recycled worktree"
}

test_contract_present_no_ports_is_refused
test_no_contract_no_ports_still_passes_silently
test_contract_present_both_ports_given_passes
test_no_ports_escape_hatch_passes_and_clears_stale_file

echo "# all fm-spawn-ports-guard tests passed"
