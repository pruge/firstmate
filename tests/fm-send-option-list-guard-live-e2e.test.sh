#!/usr/bin/env bash
# Opt-in credentialed live regression for task
# send-into-option-list-picks-option: against a real, freshly-launched Claude
# Code, proves fm-send.sh refuses (nonzero, actionable message, nothing
# typed) while a real AskUserQuestion picker is on screen, and that ordinary
# sends still work once the picker clears (no regression to the common
# no-picker path).
#
# Runs on the default tmux server/socket because fm-send.sh's tmux backend
# always dispatches through plain `tmux` with no socket override (unlike the
# dedicated-socket live E2E tests elsewhere in this suite, which need that
# isolation because they drive a wrapped `tmux`/harness pair). Isolation here
# instead comes from a unique per-pid session name plus exact-window-scoped
# cleanup, so this test can never affect another live session.
set -u

if [ "${FM_OPTION_LIST_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OPTION_LIST_LIVE_E2E=1 with tmux and a real claude binary installed to run this regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v claude >/dev/null 2>&1 || fail "claude not found"
command -v tmux >/dev/null 2>&1 || fail "tmux not found"
CLAUDE_VERSION=$(claude --version)

LAB="$ROOT/.option-list-live-e2e.$$"
PROJECT="$LAB/project"
SESSION="fm-option-list-e2e-$$"
WINDOW=probe
TARGET="$SESSION:$WINDOW"

cleanup() {
  tmux kill-session -t "$SESSION" >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
# git clone of this worktree carries only committed state; copy the working
# tree's bin/ so the lab exercises the exact candidate under review (same
# pattern as the other *-live-e2e tests in this suite).
git clone -q "$ROOT" "$PROJECT"
cp -R "$ROOT/bin/." "$PROJECT/bin/"

capture() { tmux capture-pane -p -t "$TARGET" -S -40 2>/dev/null; }

wait_for() {  # <grep-pattern> <timeout-seconds>
  local pat=$1 timeout=$2 i=0
  while [ "$i" -lt "$timeout" ]; do
    capture | grep -qE "$pat" && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

tmux new-session -d -s "$SESSION" -n "$WINDOW" -x 220 -y 50 \
  -c "$PROJECT" 'claude --dangerously-skip-permissions'

# First launch may show the directory trust dialog; accept it if present so
# the probe reaches an ordinary idle composer before triggering the picker
# under test.
if wait_for 'trust the contents' 20; then
  tmux send-keys -t "$TARGET" Enter
  wait_for '^❯[[:space:]]*$|bypass permissions' 20 \
    || fail "Claude did not reach an idle composer after accepting the trust dialog ($CLAUDE_VERSION)"
fi

tmux send-keys -t "$TARGET" -l \
  'Use the AskUserQuestion tool right now to ask me to pick between option A and option B. Do not do anything else first.'
tmux send-keys -t "$TARGET" Enter

wait_for 'Enter to select.*Esc to cancel' 60 \
  || fail "the AskUserQuestion picker never appeared on screen (harness UI changed? $CLAUDE_VERSION); capture: $(capture)"

mkdir -p "$LAB/fmhome/state"

set +e
FM_HOME="$LAB/fmhome" \
  "$PROJECT/bin/fm-send.sh" "$TARGET" 'do not skip this - verify it in a real browser' \
  > "$LAB/send.out" 2> "$LAB/send.err"
SEND_RC=$?
set -e

[ "$SEND_RC" -ne 0 ] \
  || fail "fm-send exited 0 while the picker was on screen (silent swallow reproduced): $(cat "$LAB/send.out" "$LAB/send.err")"
grep -qi 'not sent' "$LAB/send.err" \
  || fail "fm-send's refusal must say the text was not sent: $(cat "$LAB/send.err")"
grep -qi 'select\|dialog\|option' "$LAB/send.err" \
  || fail "fm-send's refusal must name the on-screen picker as the reason: $(cat "$LAB/send.err")"

AFTER=$(capture)
printf '%s\n' "$AFTER" | grep -qF 'do not skip this' \
  && fail "fm-send's message text leaked into the picker pane despite the refusal"
printf '%s\n' "$AFTER" | grep -qE 'Enter to select.*Esc to cancel' \
  || fail "the picker closed or advanced even though fm-send reported it refused to send: $AFTER"

# Regression: dismiss the picker and confirm an ordinary send still works.
tmux send-keys -t "$TARGET" Escape
i=0
while [ "$i" -lt 30 ] && capture | grep -qE 'Enter to select.*Esc to cancel'; do
  sleep 1
  i=$((i + 1))
done
capture | grep -qE 'Enter to select.*Esc to cancel' \
  && fail "the picker never cleared after Escape; cannot test the post-picker regression path"

set +e
FM_HOME="$LAB/fmhome" \
  "$PROJECT/bin/fm-send.sh" "$TARGET" 'reply with exactly PROBE_OK and stop' \
  > "$LAB/send2.out" 2> "$LAB/send2.err"
SEND2_RC=$?
set -e
[ "$SEND2_RC" -eq 0 ] \
  || fail "an ordinary send after the picker cleared must still succeed: $(cat "$LAB/send2.out" "$LAB/send2.err")"

wait_for 'PROBE_OK' 60 \
  || fail "ordinary send after the picker cleared was never processed by Claude"

printf 'ok - Claude %s: fm-send refused to send into a real on-screen AskUserQuestion picker (nothing typed, no option picked), and an ordinary send after it cleared still worked\n' "$CLAUDE_VERSION"
