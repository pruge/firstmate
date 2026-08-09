#!/usr/bin/env bash
# tests/fm-composer-lib.test.sh - the shared composer-content classifier
# (bin/fm-composer-lib.sh), the ONE fleet-wide owner every backend adapter
# delegates its empty|pending|unknown verdict to.
#
# The load-bearing contract, task fm-composer-shellglyph-safety:
#   1. A BARE shell prompt glyph (`>`/`$`/`%`/`#`) on an unstructured row is a
#      dead shell, NOT an empty agent composer - it must read `unknown`
#      (unsafe-for-injection), never `empty`. This is the safety fix.
#   2. The SAME shell glyph INSIDE a bordered composer box is the harness's own
#      prompt and still reads `empty` (existing behavior preserved).
#   3. The AGENT prompt glyphs `❯` (claude), `›` (codex), and `⟩` (muse) are a genuine empty
#      agent composer either way, bordered or bare.
#   4. Real unsubmitted text reads `pending`; a known idle placeholder reads
#      `empty`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

# classify <bordered> <content> [idle_re] -> echoes the verdict.
classify() { fm_composer_classify_content "$@"; }

# --- Safety fix: bare shell prompt is NOT an empty agent composer -----------

test_bare_shell_glyphs_are_unknown() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 0 "$g")
    [ "$out" = unknown ] \
      || fail "bare shell glyph '$g' must read unknown (dead shell, unsafe), got '$out'"
  done
  pass "fm_composer_classify_content: a bare shell prompt glyph (>/\$/%/#) reads unknown, never empty"
}

test_stripped_unbordered_content_uses_plain_content() {
  local plain out
  for plain in '$' 'user@host $'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = unknown ] \
      || fail "stripped unbordered content '$plain' must retain its unknown safety verdict, got '$out'"
  done
  # muse draws `⟩` at luminance ~150, the tightest margin over the 128 ghost
  # threshold in the fleet, so a raised threshold really can strip it to empty
  # and leave only the plain row. This branch is what keeps that pane readable.
  for plain in '❯' '›' '⟩'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = empty ] \
      || fail "a stripped agent glyph '$plain' must remain empty, got '$out'"
  done
  pass "fm_composer_classify_content: stripped unbordered content is unknown except verified agent glyphs"
}

test_bare_shell_prompt_with_command_is_not_empty() {
  local out
  # A dead shell showing a typed command must not read empty either.
  out=$(classify 0 '$ ls -la')
  [ "$out" != empty ] || fail "a bare shell prompt with a command must not read empty, got '$out'"
  pass "fm_composer_classify_content: a bare shell prompt carrying a command is not empty"
}

# --- Preserved: shell glyph inside a composer box is the harness prompt ------

test_bordered_shell_glyph_is_empty() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 1 "$g")
    [ "$out" = empty ] \
      || fail "a shell glyph '$g' inside a bordered composer box must read empty, got '$out'"
  done
  pass "fm_composer_classify_content: a bare prompt glyph inside a bordered composer box reads empty (claude's own idle composer)"
}

# --- Agent glyphs are empty either way --------------------------------------

test_agent_glyphs_are_empty_bordered_and_bare() {
  local out
  out=$(classify 0 '❯'); [ "$out" = empty ] || fail "bare claude '❯' should read empty, got '$out'"
  out=$(classify 0 '›'); [ "$out" = empty ] || fail "bare codex '›' should read empty, got '$out'"
  out=$(classify 1 '❯'); [ "$out" = empty ] || fail "bordered claude '❯' should read empty, got '$out'"
  out=$(classify 1 '›'); [ "$out" = empty ] || fail "bordered codex '›' should read empty, got '$out'"
  out=$(classify 0 '⟩'); [ "$out" = empty ] || fail "bare muse '⟩' should read empty, got '$out'"
  out=$(classify 1 '⟩'); [ "$out" = empty ] || fail "bordered muse '⟩' should read empty, got '$out'"
  pass "fm_composer_classify_content: agent prompt glyphs (❯ claude, › codex, ⟩ muse) read empty bordered or bare"
}

# --- Empty content and idle placeholder -------------------------------------

test_empty_content_is_empty() {
  local out
  out=$(classify 0 ''); [ "$out" = empty ] || fail "empty bare content should read empty, got '$out'"
  out=$(classify 1 ''); [ "$out" = empty ] || fail "empty bordered content should read empty, got '$out'"
  pass "fm_composer_classify_content: an empty composer reads empty"
}

test_idle_placeholder_is_empty() {
  local idle='^Type a message\.\.\.$' out
  # Placeholder with no prompt glyph (grok's bordered empty composer).
  out=$(classify 1 'Type a message...' "$idle")
  [ "$out" = empty ] || fail "the grok idle placeholder should read empty, got '$out'"
  # Placeholder after an agent glyph (post-strip match).
  out=$(classify 0 '❯ Type a message...' "$idle")
  [ "$out" = empty ] || fail "the idle placeholder after a glyph should read empty, got '$out'"
  # Without the idle regex it is just text -> pending.
  out=$(classify 1 'Type a message...')
  [ "$out" = pending ] || fail "without an idle regex the placeholder text is pending, got '$out'"
  pass "fm_composer_classify_content: a known idle placeholder reads empty, before and after glyph stripping"
}

test_idle_placeholder_case_mode_is_explicit() {
  local idle='^Type a message\.\.\.$' out
  out=$(classify 1 'type a message...' "$idle")
  [ "$out" = pending ] || fail "a case-variant idle placeholder should remain pending by default, got '$out'"
  out=$(classify 1 'type a message...' "$idle" insensitive)
  [ "$out" = empty ] || fail "an explicitly insensitive idle placeholder should read empty, got '$out'"
  pass "fm_composer_classify_content: idle matching preserves the caller's case mode"
}

# --- Real text is pending ---------------------------------------------------

test_real_text_is_pending() {
  local out
  out=$(classify 0 '❯ fix findings 1 and 3'); [ "$out" = pending ] || fail "bare '❯ <text>' should be pending, got '$out'"
  out=$(classify 1 '> deploy staging now'); [ "$out" = pending ] || fail "bordered '> <text>' should be pending, got '$out'"
  # muse restores the interrupted prompt into its composer after Escape, as real
  # bright text. Reading that as pending is correct - it really is unsubmitted.
  out=$(classify 0 '⟩ second turn to interrupt'); [ "$out" = pending ] || fail "bare '⟩ <text>' should be pending, got '$out'"
  # A slash-command popup argument-hint placeholder is still unsubmitted text.
  out=$(classify 1 '/compact compaction instructions'); [ "$out" = pending ] || fail "a popup placeholder fill should be pending, got '$out'"
  pass "fm_composer_classify_content: real unsubmitted text reads pending (including a popup argument-hint fill)"
}

# --- fm_composer_option_list_active: picker-overlay detection ---------------
# Fixtures are the plain-text tail captured from a real, freshly-launched
# Claude Code 2.1.220 (tmux `capture-pane -p`), verified live for task
# send-into-option-list-picks-option (docs/verification/runtime-backends.md).

option_list() { fm_composer_option_list_active; }

test_askuserquestion_single_select_is_active() {
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
    | option_list || fail "a real single-select AskUserQuestion capture must classify as an active option list"
  pass "fm_composer_option_list_active: real single-select AskUserQuestion tail is active"
}

test_askuserquestion_multiselect_is_active() {
  printf '%s\n' \
    '────────────────────────────────────────────────────────────' \
    '←  ☐ X / Y / Z  ✔ Submit  →' \
    '' \
    'Which of these would you like to include?' \
    '' \
    '❯ 1. [ ] X' \
    '  Include X.' \
    '  2. [ ] Y' \
    '  Include Y.' \
    '  3. [ ] Z' \
    '  Include Z.' \
    '  4. [ ] Type something' \
    '     Submit' \
    '────────────────────────────────────────────────────────────' \
    '  5. Chat about this' \
    '' \
    'Enter to select · ↑/↓ to navigate · Esc to cancel' \
    | option_list || fail "a real multiSelect AskUserQuestion capture must classify as an active option list"
  pass "fm_composer_option_list_active: real multiSelect AskUserQuestion tail is active"
}

test_trust_dialog_is_active() {
  printf '%s\n' \
    ' Security guide' \
    '' \
    ' ❯ 1. Yes, I trust this folder' \
    '   2. No, exit' \
    '' \
    ' Enter to confirm · Esc to cancel' \
    | option_list || fail "the real directory-trust dialog capture must classify as an active option list"
  pass "fm_composer_option_list_active: real trust-dialog tail is active"
}

test_idle_footer_is_not_active() {
  printf '%s\n' \
    '❯ ' \
    '────────────────────────────────────────────────────────────' \
    '  [Opus 5 (1M context)] │ askprobe' \
    '  Context █░░░░░░░░░ 7% │ Usage █░░░░░░░░░ 6% (resets in 3h 53m)' \
    '  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents' \
    | option_list && fail "a real idle empty-composer footer must not classify as an active option list"
  pass "fm_composer_option_list_active: real idle footer (no picker) is not active"
}

test_pending_text_is_not_active() {
  printf '%s\n' \
    '❯ hello world this is unsubmitted' \
    '────────────────────────────────────────────────────────────' \
    '  [Opus 5 (1M context)] │ askprobe' \
    '  Context █░░░░░░░░░ 7% │ Usage █░░░░░░░░░ 6% (resets in 3h 53m)' \
    '  ⏵⏵ bypass permissions on (shift+tab to cycle)' \
    | option_list && fail "real unsubmitted composer text must not classify as an active option list"
  pass "fm_composer_option_list_active: real pending composer text (no picker) is not active"
}

test_hint_line_alone_is_not_active() {
  # The two signals must be driven apart: the hint line matches, but there is
  # no highlighted numbered row anywhere in the tail (assistant prose merely
  # mentions cancelling). This must not misfire on the phrase alone.
  printf '%s\n' \
    'Some assistant text that happens to say Enter to select an item next,' \
    'and separately mentions Esc to cancel a future operation.' \
    | option_list && fail "the hint phrase alone, with no highlighted numbered row, must not classify as active"
  pass "fm_composer_option_list_active: the footer-hint signal alone (no highlighted row) is not active"
}

test_numbered_row_alone_is_not_active() {
  # The two signals must be driven apart the other way: a highlighted-looking
  # numbered row with no hint-bar text at all (ordinary assistant output that
  # happens to render a numbered list) must not misfire either.
  printf '%s\n' \
    '❯ 1. Do the first thing' \
    '  2. Do the second thing' \
    | option_list && fail "a numbered row alone, with no footer hint line, must not classify as active"
  pass "fm_composer_option_list_active: a numbered-row shape alone (no footer hint) is not active"
}

test_bare_shell_glyphs_are_unknown
test_stripped_unbordered_content_uses_plain_content
test_bare_shell_prompt_with_command_is_not_empty
test_bordered_shell_glyph_is_empty
test_agent_glyphs_are_empty_bordered_and_bare
test_empty_content_is_empty
test_idle_placeholder_is_empty
test_idle_placeholder_case_mode_is_explicit
test_real_text_is_pending
test_askuserquestion_single_select_is_active
test_askuserquestion_multiselect_is_active
test_trust_dialog_is_active
test_idle_footer_is_not_active
test_pending_text_is_not_active
test_hint_line_alone_is_not_active
test_numbered_row_alone_is_not_active
