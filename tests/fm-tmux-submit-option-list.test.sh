#!/usr/bin/env bash
# tests/fm-tmux-submit-option-list.test.sh - regression for task
# send-into-option-list-picks-option: fm_tmux_submit_core (bin/fm-tmux-lib.sh)
# must refuse BEFORE typing anything when a real harness-drawn selection list
# or confirm dialog is proven on screen, instead of typing the caller's text
# into it and having the follow-up Enter pick its highlighted option (which
# then leaves an empty, "successfully submitted"-looking composer with the
# message actually lost). See tests/fm-composer-lib.test.sh for the
# classifier's own unit coverage against real captured picker text; this file
# proves the send path actually consults it before sending any keystrokes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-tmux-submit-option-list.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

# make_mock: a fake tmux whose capture-pane always returns $FM_FAKE_TAIL
# (the picker/idle fixture under test) and whose send-keys just logs what it
# was asked to send, so a test can assert nothing was typed.
make_mock() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
TAIL="${FM_FAKE_TAIL:?}"
case "${1:-}" in
  capture-pane) cat "$TAIL" 2>/dev/null; exit 0 ;;
  send-keys)
    shift
    { printf 'send-keys'; for a in "$@"; do printf ' <%s>' "$a"; done; printf '\n'; } >> "${FM_FAKE_SENT:?}"
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '0\n'; exit 0 ;; esac; done
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# Real, freshly-launched Claude Code 2.1.220 capture (tmux `capture-pane -p`),
# same fixtures verified in tests/fm-composer-lib.test.sh.
write_askuserquestion_tail() {
  printf '%s\n' \
    '────────────────────────────────────────────────────────────' \
    ' ☐ A or B ' \
    '' \
    'Which option would you like to go with?' \
    '' \
    '❯ 1. Option A' \
    '     Pick the first option, A.' \
    '  2. Option B' \
    '     Pick the second option, B.' \
    '  3. Type something.' \
    '────────────────────────────────────────────────────────────' \
    '  4. Chat about this' \
    '' \
    'Enter to select · ↑/↓ to navigate · Esc to cancel' \
    > "$1"
}

write_idle_tail() {
  printf '%s\n' \
    '❯ ' \
    '────────────────────────────────────────────────────────────' \
    '  [Opus 5 (1M context)] │ askprobe' \
    '  Context █░░░░░░░░░ 7% │ Usage █░░░░░░░░░ 6% (resets in 3h 53m)' \
    '  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents' \
    > "$1"
}

test_option_list_active_refuses_before_typing() {
  local dir fakebin tail sent verdict
  dir="$TMP_ROOT/active"
  fakebin=$(make_mock "$dir")
  tail="$dir/tail"
  sent="$dir/sent.log"
  write_askuserquestion_tail "$tail"
  : > "$sent"
  verdict=$(PATH="$fakebin:$PATH" FM_FAKE_TAIL="$tail" FM_FAKE_SENT="$sent" \
    fm_tmux_submit_core "win" "do not skip - verify in a real browser" 3 0.01 0.01)
  [ "$verdict" = option-list-active ] \
    || fail "submit core must report option-list-active while a picker is on screen, got '$verdict'"
  [ ! -s "$sent" ] \
    || fail "submit core must send nothing (no typed text, no Enter) once a picker is proven active: $(cat "$sent")"
  pass "fm_tmux_submit_core: refuses before typing when a real AskUserQuestion picker tail is on screen"
}

test_idle_pane_still_submits_normally() {
  local dir fakebin tail sent verdict
  dir="$TMP_ROOT/idle"
  fakebin=$(make_mock "$dir")
  tail="$dir/tail"
  sent="$dir/sent.log"
  write_idle_tail "$tail"
  : > "$sent"
  # fm_tmux_submit_enter_core does its own composer_state read after Enter,
  # which this minimal mock does not model - stub it so this test stays
  # scoped to proving the pre-type guard does NOT fire on an ordinary idle
  # pane, not to re-testing the post-Enter verification already covered by
  # tests/fm-tmux-submit-busy.test.sh.
  fm_tmux_submit_enter_core() { printf 'empty'; }
  verdict=$(PATH="$fakebin:$PATH" FM_FAKE_TAIL="$tail" FM_FAKE_SENT="$sent" \
    fm_tmux_submit_core "win" "ordinary message" 3 0.01 0.01)
  [ "$verdict" = empty ] \
    || fail "an ordinary idle pane (no picker) must still submit normally, got '$verdict'"
  grep -q '<ordinary message>' "$sent" \
    || fail "an ordinary idle pane must still have its text typed: $(cat "$sent")"
  pass "fm_tmux_submit_core: an ordinary idle pane (no picker) still types and submits as before"
}

test_option_list_active_refuses_before_typing
test_idle_pane_still_submits_normally
