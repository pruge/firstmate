#!/usr/bin/env bash
# Behavior tests for bin/fm-ticket-check.sh.
#
# The checker enforces the task-planning planning-document contract on ONE
# feature directory (never the whole repo, per the captain instruction to leave
# existing documents untouched). These tests build planning-document fixtures in
# a temp dir and drive the real script through its execution interface; they
# never assert the script's source bytes (the one-rule the task forbids).
#
# Coverage: a fully contract-satisfying feature is silent and exits 0; each
# contract violation is caught; and benign spec tokens (grill.md self reference,
# web/, GET /ca) are NOT false-flagged.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-ticket-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-ticket-check)

ALL_HEADERS="Goal
Why this slice
Produces
Consumers
Touched surfaces
Explicitly out of scope
Locked decisions
Evidence anchors
Regression guards
Depends on"

# make_feature <slug> builds an empty feature dir under TMP_ROOT and echoes its path.
make_feature() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/tickets"
  printf '%s\n' "$dir"
}

# write_spec <dir> <markdown> writes spec.md with the given body.
write_spec() {
  local dir=$1
  cat > "$dir/spec.md"
}

# make_ticket <dir> <num> <title> [omit-header]: write tickets/Tnn.md with all
# required headers (or skip <omit-header>), plus a benign Can-run-in-parallel
# section. <title> should carry a review signal (e.g. 검수) for review tickets.
make_ticket() {
  local dir=$1 num=$2 title=$3 omit=${4:-}
  local f h
  f="$dir/tickets/T$(printf '%02d' "$num").md"
  {
    echo "# T$(printf '%02d' "$num") - $title"
    echo
    while IFS= read -r h; do
      [ -n "$h" ] || continue
      [ "$h" = "$omit" ] && continue
      echo "## $h"
      echo "content for $h"
      echo
    done <<< "$ALL_HEADERS"
    echo "## Can run in parallel with"
    echo "- nothing"
  } > "$f"
}

# run_check <dir>: run the checker, leaving RUN_OUT (stdout+stderr) and RUN_RC.
RUN_OUT=
RUN_RC=
run_check() {
  set +e
  RUN_OUT=$("$CHECK" "$1" 2>&1)
  RUN_RC=$?
  set -e
}

test_full_pass_is_silent() {
  local dir
  dir=$(make_feature full-pass)
  write_spec "$dir" <<'EOF'
# Specification

## Goal
A goal.

## User stories
1. story
EOF
  # Single-ticket graph whose only (highest-numbered) ticket is the review one.
  make_ticket "$dir" 1 "캡틴 검수 (종착 티켓)"

  run_check "$dir"
  [ "$RUN_RC" -eq 0 ] || fail "expected clean pass (exit 0), got exit $RUN_RC; output: $RUN_OUT"
  [ -z "$RUN_OUT" ] || fail "expected no output on a clean pass, got: $RUN_OUT"
  pass "fm-ticket-check.sh: a contract-satisfying feature is silent and exits 0"
}

test_missing_one_required_field() {
  local dir
  dir=$(make_feature missing-field)
  write_spec "$dir" <<'EOF'
# Specification
## Goal
A goal.
EOF
  # All headers except Produces (one of the seven mandatory structural fields).
  make_ticket "$dir" 1 "캡틴 검수 (종착 티켓)" "Produces"

  run_check "$dir"
  [ "$RUN_RC" -eq 1 ] || fail "expected failure (exit 1) on a missing field, got exit $RUN_RC; output: $RUN_OUT"
  assert_contains "$RUN_OUT" "missing required ticket section '## Produces'" \
    "missing-field check did not report the omitted '## Produces' section"
  pass "fm-ticket-check.sh: a missing required ticket field is reported"
}

test_status_field_forbidden() {
  local dir f
  dir=$(make_feature status-field)
  write_spec "$dir" <<'EOF'
# Specification
## Goal
A goal.
EOF
  make_ticket "$dir" 1 "캡틴 검수 (종착 티켓)"
  # Inject a forbidden status field into the ticket body.
  f="$dir/tickets/T01.md"
  printf '\n**Status:** ready-for-agent\n' >> "$f"

  run_check "$dir"
  [ "$RUN_RC" -eq 1 ] || fail "expected failure (exit 1) on a status field, got exit $RUN_RC; output: $RUN_OUT"
  assert_contains "$RUN_OUT" "ticket file carries a status field" \
    "status-field check did not reject **Status:** inside a ticket"
  pass "fm-ticket-check.sh: a status field inside a ticket is rejected"
}

test_terminal_review_ticket_must_be_last() {
  local dir
  dir=$(make_feature review-not-last)
  write_spec "$dir" <<'EOF'
# Specification
## Goal
A goal.
EOF
  make_ticket "$dir" 1 "첫 조각"
  make_ticket "$dir" 2 "캡틴 검수 (종착 티켓)"
  # A non-review ticket appended after the review ticket breaks the contract.
  make_ticket "$dir" 3 "뒤에 덧붙인 조각"

  run_check "$dir"
  [ "$RUN_RC" -eq 1 ] || fail "expected failure (exit 1) when review ticket is not last, got exit $RUN_RC; output: $RUN_OUT"
  assert_contains "$RUN_OUT" "highest-numbered ticket is not a review/terminal ticket" \
    "review-not-last check did not reject a non-review terminal ticket"
  pass "fm-ticket-check.sh: a non-review highest-numbered ticket is rejected"
}

test_spec_path_leak() {
  local dir
  dir=$(make_feature spec-leak)
  # Path leakage inside both an inline code span and a fenced code block.
  write_spec "$dir" <<'EOF'
# Specification

## Goal
A goal.

Inline leak: `src/components/Foo.tsx`.

```swift
let model: Models/Bar.swift
```
EOF
  make_ticket "$dir" 1 "캡틴 검수 (종착 티켓)"

  run_check "$dir"
  [ "$RUN_RC" -eq 1 ] || fail "expected failure (exit 1) on spec path leakage, got exit $RUN_RC; output: $RUN_OUT"
  assert_contains "$RUN_OUT" "carries a file path inside a code span" \
    "spec path-leak check did not flag a source file path in the spec"
  pass "fm-ticket-check.sh: a source file path inside spec code spans is rejected"
}

test_benign_spec_tokens_not_flagged() {
  local dir
  dir=$(make_feature benign-spec)
  # Real measured benign tokens that must NOT be false-flagged: a planning-doc
  # self reference (grill.md), a trailing-slash dir (web/), a space-split route
  # (GET /ca), and an identifier with an underscore (ctrl_c).
  write_spec "$dir" <<'EOF'
# Specification

## Goal
A goal.

See `grill.md` for the decision log. The `web/` dir and `GET /ca` route and
the `ctrl_c` handler are not file paths.
EOF
  make_ticket "$dir" 1 "캡틴 검수 (종착 티켓)"

  run_check "$dir"
  [ "$RUN_RC" -eq 0 ] || fail "expected clean pass (exit 0) on benign spec tokens, got exit $RUN_RC; output: $RUN_OUT"
  [ -z "$RUN_OUT" ] || fail "benign spec tokens were false-flagged: $RUN_OUT"
  pass "fm-ticket-check.sh: grill.md / web/ / GET /ca / ctrl_c are not path leakage"
}

test_full_pass_is_silent
test_missing_one_required_field
test_status_field_forbidden
test_terminal_review_ticket_must_be_last
test_spec_path_leak
test_benign_spec_tokens_not_flagged
