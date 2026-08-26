#!/usr/bin/env bash
# tests/fm-secondmate-wake-stall.test.sh - secondmate wake-loop stall thresholds:
# the durable config/secondmate-wake-stall-secs knob, the adaptive threshold
# learned from each mate's observed foreign-row handling latency (no samples,
# slow home, clamp floor, clamp cap, per-mate isolation, durable roundtrip), the
# explicit FM_SECONDMATE_WAKE_STALL_SECS env regression that still wins over both,
# and a replay of the 2026-08-26 false-alarm observation set proving those ages no
# longer alarm while a genuine multi-minute wedge still does. Queue suppression,
# foreign-row read-only safety, and crash-recovery idempotence live in
# fm-wake-queue.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

LIB="$ROOT/bin/fm-wake-lib.sh"
CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-stall-tests)

# Run one lib function in a fresh process against a case dir, so every call is a
# restart-grade durability check rather than in-memory state.
lib_call() {  # <dir> <args...>
  local dir=$1
  shift
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    shift
    "$@"
  ' _ "$LIB" "$@"
}

test_threshold_without_observations_keeps_default() {
  local dir out
  dir=$(make_case stall-no-samples)
  mkdir -p "$dir/config"
  out=$(lib_call "$dir" fm_secondmate_stall_threshold mate)
  [ "$out" = "60" ] || fail "with no observations the threshold must stay at the historical default 60, got $out"
  pass "a mate with no observed latencies keeps the historical 60s threshold"
}

test_adaptive_threshold_tracks_slow_home_within_clamps() {
  local dir slow tiny huge
  dir=$(make_case stall-adaptive)
  mkdir -p "$dir/config"
  printf '62\n64\n66\n70\n71\n72\n75\n76\n78\n78\n109\n113\n114\n' \
    > "$dir/state/.secondmate-wake-stall-latency-mate"
  slow=$(lib_call "$dir" fm_secondmate_stall_threshold mate)
  [ "$slow" = "228" ] || fail "worst of the evidence set (114) times factor 2 should be 228, got $slow"
  printf '5\n8\n3\n' > "$dir/state/.secondmate-wake-stall-latency-mate"
  tiny=$(lib_call "$dir" fm_secondmate_stall_threshold mate)
  [ "$tiny" = "60" ] || fail "implausibly fast observations must clamp to the 60s floor, got $tiny"
  printf '5000\n800\n12000\n' > "$dir/state/.secondmate-wake-stall-latency-mate"
  huge=$(lib_call "$dir" fm_secondmate_stall_threshold mate)
  [ "$huge" = "900" ] || fail "huge observations must clamp to the 900s cap so a real wedge still alarms, got $huge"
  pass "the adaptive threshold follows observed pace but stays inside the floor/cap clamps"
}

test_adaptive_samples_are_per_mate_and_durable() {
  local dir fast slow
  dir=$(make_case stall-per-mate)
  mkdir -p "$dir/config"
  printf '20\n30\n' > "$dir/state/.secondmate-wake-stall-latency-fast"
  printf '100\n110\n' > "$dir/state/.secondmate-wake-stall-latency-slow"
  fast=$(lib_call "$dir" fm_secondmate_stall_threshold fast)
  slow=$(lib_call "$dir" fm_secondmate_stall_threshold slow)
  [ "$fast" = "60" ] || fail "the fast mate must keep its own floor threshold, got $fast"
  [ "$slow" = "220" ] || fail "the slow mate must learn from only its own samples, got $slow"
  # Restart grade: a fresh process reading the same durable file sees the same
  # threshold, and new observation calls append durably across processes.
  lib_call "$dir" fm_wake_secondmate_stall_latency_append fast 40 \
    || fail "cross-process latency append failed"
  fast=$(lib_call "$dir" fm_secondmate_stall_threshold fast)
  [ "$fast" = "80" ] || fail "an appended sample from another process must move the threshold, got $fast"
  pass "latency learning is per mate and survives process restarts through durable state"
}

test_observation_records_consumption_latency_and_discards_outliers() {
  local dir now seen sample
  dir=$(make_case stall-observe)
  mkdir -p "$dir/config"
  now=$(date +%s)
  # First sighting of row epoch=now-70 records it as seen with no sample.
  lib_call "$dir" fm_secondmate_stall_observe mate $((now - 70)) 7 "$now" \
    || fail "first sighting observation failed"
  seen=$(cat "$dir/state/.secondmate-wake-stall-seen-mate")
  [ "$seen" = "$((now - 70))-7" ] || fail "first sighting did not record the seen row, got $seen"
  [ ! -e "$dir/state/.secondmate-wake-stall-latency-mate" ] \
    || fail "first sighting recorded a spurious latency sample"
  # Next poll: the old row was consumed, a newer oldest row exists; the sample
  # is now minus the consumed row's epoch.
  sleep 1
  lib_call "$dir" fm_secondmate_stall_observe mate $((now - 10)) 8 "$(date +%s)" \
    || fail "consumption observation failed"
  sample=$(cat "$dir/state/.secondmate-wake-stall-latency-mate")
  case "$sample" in
    ''|*[!0-9]*) fail "consumption latency sample is not a plain integer: $sample" ;;
  esac
  [ "$sample" -ge 69 ] && [ "$sample" -le 75 ] \
    || fail "expected a ~70s consumption sample, got $sample"
  # A downtime-sized gap (above the cap) must be discarded, not learned.
  lib_call "$dir" fm_secondmate_stall_observe mate $((now + 1)) 9 "$((now + 4000))" \
    || fail "post-downtime observation failed"
  [ "$(cat "$dir/state/.secondmate-wake-stall-latency-mate")" = "$sample" ] \
    || fail "a downtime-sized gap poisoned the learned samples"
  pass "observations record real consumption latency and discard downtime outliers"
}

test_explicit_env_still_wins_over_config_and_adaptation() {
  local dir out
  dir=$(make_case stall-env-precedence)
  mkdir -p "$dir/config"
  printf '100\n110\n' > "$dir/state/.secondmate-wake-stall-latency-mate"
  printf '300\n' > "$dir/config/secondmate-wake-stall-secs"
  out=$(FM_SECONDMATE_WAKE_STALL_SECS=45 lib_call "$dir" fm_secondmate_stall_threshold mate)
  [ "$out" = "45" ] || fail "explicit env must beat config pin and adaptive learning, got $out"
  rm "$dir/config/secondmate-wake-stall-secs"
  out=$(FM_SECONDMATE_WAKE_STALL_SECS=45 lib_call "$dir" fm_secondmate_stall_threshold mate)
  [ "$out" = "45" ] || fail "explicit env must beat adaptive learning, got $out"
  pass "explicit FM_SECONDMATE_WAKE_STALL_SECS remains the top precedence"
}

test_config_file_pins_threshold_and_falls_back_when_invalid() {
  local dir out
  dir=$(make_case stall-config-pin)
  mkdir -p "$dir/config"
  printf '100\n110\n' > "$dir/state/.secondmate-wake-stall-latency-mate"
  printf '300\n' > "$dir/config/secondmate-wake-stall-secs"
  out=$(lib_call "$dir" fm_secondmate_stall_threshold mate)
  [ "$out" = "300" ] || fail "a pinned config value must win over adaptation, got $out"
  printf '  120  \n' > "$dir/config/secondmate-wake-stall-secs"
  out=$(lib_call "$dir" fm_secondmate_stall_threshold mate)
  [ "$out" = "120" ] || fail "pinned value must tolerate surrounding whitespace, got $out"
  printf 'garbage\n' > "$dir/config/secondmate-wake-stall-secs"
  out=$(lib_call "$dir" fm_secondmate_stall_threshold mate)
  [ "$out" = "220" ] || fail "an invalid pinned value must fall back to adaptation, got $out"
  : > "$dir/config/secondmate-wake-stall-secs"
  out=$(lib_call "$dir" fm_secondmate_stall_threshold mate)
  [ "$out" = "220" ] || fail "an empty pinned value must fall back to adaptation, got $out"
  pass "config/secondmate-wake-stall-secs pins the threshold and invalid values fall back safely"
}

# Shared checkpoint fixture: a parent home with one endpoint-recorded local mate
# whose queue holds one aged row. Prints nothing on success; callers assert on
# the checkpoint output.
run_stall_checkpoint() {  # <dir> <state> <sub> <extra-env...>
  local dir=$1 state=$2 sub=$3 fakebin out
  shift 3
  fakebin="$dir/fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf '%s\n' "${FM_FAKE_TMUX_WINDOW:-}" ;;
  capture-pane) cat "${FM_FAKE_TMUX_CAPTURE:-/dev/null}" ;;
  display-message) printf '0\n' ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/tmux"
  out="$dir/watch.out"
  env PATH="$fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_WINDOW='firstmate:fm-mate' \
    FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_TMUX_CAPTURE="$dir/fake-tmux/pane.txt" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" \
    "$CHECKPOINT" --seconds 4 > "$out" 2> "$dir/watch.err" || true
  printf '%s\n' "$out"
}

make_mate_fixture() {  # <dir-name>
  local dir state sub
  dir=$(make_case "$1")
  state="$dir/state"
  sub="$dir/secondmate"
  mkdir -p "$sub/state" "$dir/config"
  printf 'mate\n' > "$sub/.fm-secondmate-home"
  printf 'window=firstmate:fm-mate\nkind=secondmate\nharness=claude\nbackend=tmux\nhome=%s\n' \
    "$sub" > "$state/mate.meta"
  printf '%s\n' "$dir"
}

test_replay_of_false_alarm_evidence_no_longer_alarms_but_wedges_do() {
  local dir state sub out age
  dir=$(make_mate_fixture stall-evidence-replay)
  state="$dir/state"
  sub="$dir/secondmate"
  # Replay input: the ages of all thirteen 2026-08-26 false alarms, seeded as
  # this home's observed handling-latency history exactly as observation would
  # have recorded them.
  printf '62\n64\n66\n70\n71\n72\n75\n76\n78\n78\n109\n113\n114\n' \
    > "$state/.secondmate-wake-stall-latency-mate"
  for age in 62 64 66 70 71 72 75 76 78 78 109 113 114; do
    printf '%s\t7\tcheck\trouted\tcheck: routed row\n' "$(( $(date +%s) - age ))" \
      > "$sub/state/.wake-queue"
    out=$(run_stall_checkpoint "$dir" "$state" "$sub")
    if grep -F 'secondmate wake-loop stalled' "$out" >/dev/null 2>&1; then
      fail "replayed evidence age ${age}s produced a false alarm"
    fi
  done
  # A genuine wedge is minutes long: past the 228s learned threshold it alarms.
  printf '%s\t7\tcheck\trouted\tcheck: routed row\n' "$(( $(date +%s) - 600 ))" \
    > "$sub/state/.wake-queue"
  out=$(run_stall_checkpoint "$dir" "$state" "$sub")
  grep -F 'secondmate wake-loop stalled: mate=mate row=7' "$out" >/dev/null \
    || fail "a genuine 600s wedge did not alarm above the learned threshold"
  pass "the thirteen observed false-alarm ages stay silent while a genuine wedge still alarms"
}

test_config_knob_applies_on_next_watch_cycle_without_restart() {
  local dir state sub out before
  dir=$(make_mate_fixture stall-config-live)
  state="$dir/state"
  sub="$dir/secondmate"
  # Cycle 1: no knob anywhere, no observations, so the historical 60s default
  # alarms on a 90s-old row.
  printf '%s\t7\tcheck\trouted\tcheck: routed row\n' "$(( $(date +%s) - 90 ))" \
    > "$sub/state/.wake-queue"
  out=$(run_stall_checkpoint "$dir" "$state" "$sub")
  before=$(cat "$out")
  grep -F 'secondmate wake-loop stalled: mate=mate row=7' "$out" >/dev/null \
    || fail "baseline cycle did not alarm under the historical default: $before"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err" \
    || fail "drain after baseline alarm failed"
  ack_drain_err "$state" "$dir/drain.err" || fail "baseline acknowledgement failed"
  # The operator drops a knob file on disk. Nothing persistent is restarted;
  # the next watcher cycle is a fresh process that reads the disk.
  printf '300\n' > "$dir/config/secondmate-wake-stall-secs"
  printf '%s\t9\tcheck\trouted\tcheck: routed row\n' "$(( $(date +%s) - 90 ))" \
    > "$sub/state/.wake-queue"
  out=$(run_stall_checkpoint "$dir" "$state" "$sub")
  if grep -F 'secondmate wake-loop stalled' "$out" >/dev/null 2>&1; then
    fail "the dropped config knob did not take effect on the next watcher cycle"
  fi
  # Removing the knob restores the historical default just as immediately,
  # shown on a fresh mate in the same parent: no pin, no observations, so the
  # 60s default alarms again on the very next cycle.
  rm "$dir/config/secondmate-wake-stall-secs"
  sub_b="$dir/secondmate-b"
  mkdir -p "$sub_b/state"
  printf 'mate-b\n' > "$sub_b/.fm-secondmate-home"
  printf 'window=firstmate:fm-mate-b\nkind=secondmate\nharness=claude\nbackend=tmux\nhome=%s\n' \
    "$sub_b" > "$state/mate-b.meta"
  printf '%s\t11\tcheck\trouted\tcheck: routed row\n' "$(( $(date +%s) - 90 ))" \
    > "$sub_b/state/.wake-queue"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  env PATH="$fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_WINDOW='firstmate:fm-mate-b' \
    FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_TMUX_CAPTURE="$dir/fake-tmux/pane.txt" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$CHECKPOINT" --seconds 4 > "$out" 2> "$dir/watch.err" || true
  grep -F 'secondmate wake-loop stalled: mate=mate-b row=11' "$out" >/dev/null \
    || fail "removing the knob did not restore the default on the next cycle: $(cat "$out")"
  pass "editing config/secondmate-wake-stall-secs changes behavior from the very next watch cycle"
}

test_threshold_change_is_visible_in_tick_behavior_via_env_too() {
  local dir state sub out
  dir=$(make_mate_fixture stall-env-live)
  state="$dir/state"
  sub="$dir/secondmate"
  printf '%s\t7\tcheck\trouted\tcheck: routed row\n' "$(( $(date +%s) - 90 ))" \
    > "$sub/state/.wake-queue"
  out=$(run_stall_checkpoint "$dir" "$state" "$sub" FM_SECONDMATE_WAKE_STALL_SECS=300)
  if grep -F 'secondmate wake-loop stalled' "$out" >/dev/null 2>&1; then
    fail "an explicit env override did not suppress a below-threshold row"
  fi
  pass "the explicit env override still governs live checkpoint cycles"
}

test_empty_queue_clears_seen_row_but_keeps_learning() {
  local dir state sub out threshold_before threshold_after
  dir=$(make_mate_fixture stall-empty-keeps-learning)
  state="$dir/state"
  sub="$dir/secondmate"
  printf '100\n110\n' > "$state/.secondmate-wake-stall-latency-mate"
  printf '%s\t7\tcheck\trouted\tcheck: routed row\n' "$(( $(date +%s) - 300 ))" \
    > "$sub/state/.wake-queue"
  out=$(run_stall_checkpoint "$dir" "$state" "$sub")
  grep -F 'secondmate wake-loop stalled' "$out" >/dev/null \
    || fail "fixture did not alarm before the empty-queue leg"
  [ -f "$state/.secondmate-wake-stall-seen-mate" ] \
    || fail "the alarmed poll did not record the seen row"
  threshold_before=$(lib_call "$dir" fm_secondmate_stall_threshold mate)
  [ "$threshold_before" = "220" ] || fail "fixture threshold wrong: $threshold_before"
  # The queue empties: marker, receipts, and the seen row clear, but the
  # learned latency history must survive so an idle stretch cannot reset it.
  : > "$sub/state/.wake-queue"
  out=$(run_stall_checkpoint "$dir" "$state" "$sub")
  if grep -F 'secondmate wake-loop stalled' "$out" >/dev/null 2>&1; then
    fail "an emptied queue produced a stall notification"
  fi
  [ ! -e "$state/.secondmate-wake-stall-seen-mate" ] \
    || fail "an emptied queue did not clear the stale seen-row observation"
  threshold_after=$(lib_call "$dir" fm_secondmate_stall_threshold mate)
  [ "$threshold_after" = "220" ] || fail "an idle stretch reset the learned threshold"
  pass "an emptied queue clears alert state but keeps each mate's learned baseline"
}

test_threshold_without_observations_keeps_default
test_adaptive_threshold_tracks_slow_home_within_clamps
test_adaptive_samples_are_per_mate_and_durable
test_observation_records_consumption_latency_and_discards_outliers
test_explicit_env_still_wins_over_config_and_adaptation
test_config_file_pins_threshold_and_falls_back_when_invalid
test_replay_of_false_alarm_evidence_no_longer_alarms_but_wedges_do
test_config_knob_applies_on_next_watch_cycle_without_restart
test_threshold_change_is_visible_in_tick_behavior_via_env_too
test_empty_queue_clears_seen_row_but_keeps_learning
