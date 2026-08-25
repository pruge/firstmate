#!/usr/bin/env bash
# fm-ci-verified-merge.sh - judge whether a push to main is the result of a
# verified PR merge.
#
# Reads a head-commit message and prints exactly one line, `verified=true` or
# `verified=false`, in GitHub Actions step-output format. The message comes
# from FM_HEAD_COMMIT_MESSAGE (the caller maps github.event.head_commit.message
# into it); when unset or empty, the script falls back to reading stdin.
#
# A commit is judged a PR merge when its subject matches either shape this
# repository's merges produce:
#   - squash merge: subject ends with "(#<number>)"
#   - merge commit: subject starts with "Merge pull request #<number> from "
# Every other shape - including an empty message - prints `verified=false`, so
# the caller falls back to running the full CI suite. Skipping CI is only ever
# allowed on a confident match.
#
# Usage:
#   fm-ci-verified-merge.sh            judge $FM_HEAD_COMMIT_MESSAGE or stdin
#
# Exit status: 0 whenever a verdict was produced; nonzero only on usage errors.

set -eu

message=${FM_HEAD_COMMIT_MESSAGE:-}
if [ -z "$message" ]; then
  message=$(cat)
fi

# The subject is everything before the first newline; with no newline it is the
# whole input.
subject=${message%%$'\n'*}

squash_re='\(#[0-9]+\)$'
merge_re='^Merge pull request #[0-9]+ from '
if [[ $subject =~ $squash_re || $subject =~ $merge_re ]]; then
  echo "verified=true"
else
  echo "verified=false"
fi
