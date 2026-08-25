#!/usr/bin/env bash
# Regression tests for bin/fm-ci-verified-merge.sh, the push-to-main verdict
# that lets CI skip re-running lanes a green PR already covered.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-ci-verified-merge.sh"

verdict() {
  FM_HEAD_COMMIT_MESSAGE=$1 "$CHECK"
}

assert_verdict() {
  local expected=$1 message=$2 label=$3 out
  out=$(verdict "$message")
  assert_contains "$out" "verified=$expected" \
    "$label: expected verified=$expected, got '$out'"
}

# Squash merges: subject ends with "(#<number>)".
assert_verdict true 'Make ticket + common scaffold = brief actually hold (#16)' \
  'squash merge subject is judged a PR merge'
assert_verdict true $'Fix watcher race (#123)\n\nLong body line.' \
  'squash merge with a body still judges on the subject'

# Merge commits: subject starts with "Merge pull request #<number> from ".
assert_verdict true 'Merge pull request #15 from pruge/fm/gate-abort-contract' \
  'merge-commit subject is judged a PR merge'
assert_verdict true $'Merge pull request #14 from pruge/fm/ci-changed-selection\n\nbody' \
  'merge commit with a body still judges on the subject'

# Everything else must fall back to running the full suite.
assert_verdict false 'feat(brief): add standing fast-abort contract to ship and scout scaffolds' \
  'a plain direct-push subject is not judged a PR merge'
assert_verdict false 'Merge pull request from nowhere' \
  'a merge-shaped subject without a number is not judged'
assert_verdict false 'revert (#16 partial' \
  'an unclosed squash reference is not judged'
assert_verdict false 'Merge pull request abc from somewhere' \
  'a non-numeric PR number is not judged'
assert_verdict false '(#16) leading reference' \
  'a leading squash reference is not judged'

# Empty or absent input must fail closed toward running everything.
assert_verdict false '' 'an empty message is not judged'
stdin_out=$(printf '' | "$CHECK")
assert_contains "$stdin_out" 'verified=false' \
  'stdin fallback with empty input is not judged'

pass "fm-ci-verified-merge verdict tests passed"
