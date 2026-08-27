#!/usr/bin/env bash
# fm-ticket-check.sh - enforcement executor for the task-planning planning
# document contract.
#
# It checks ONE feature directory's planning documents (spec.md + tickets/)
# against the contract owned by .agents/skills/task-planning/SKILL.md.
# SKILL.md is the single owner of the contract; this script is only the
# executor and must never restate the contract's substance (one-owner rule).
# Every check below cites, in a comment, the SKILL.md sentence it enforces.
#
# This is NOT a whole-repo CI gate. It inspects exactly the feature directory
# passed as an argument, so it only catches planning documents written from now
# on; existing documents are left untouched (captain instruction).
#
# Usage:
#   fm-ticket-check.sh <feature-dir>
#   fm-ticket-check.sh -h | --help
#
# Output contract: prints nothing and exits 0 when the feature directory
# satisfies the contract; prints one line per problem (file + reason) and
# exits 1 when it does not. Mechanical usage and flags are owned by this header
# and --help, not by SKILL.md.
set -eu

usage() {
  cat <<'EOF'
usage: fm-ticket-check.sh <feature-dir>

Check one feature planning directory (docs/features/<slug>/, this repo's or an
absolute path) against the task-planning document contract owned by
.agents/skills/task-planning/SKILL.md.

Prints nothing and exits 0 when the contract holds. Prints one line per problem
and exits 1 when it does not.
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

[ "$#" -eq 1 ] || { usage >&2; exit 2; }

FEATURE_DIR="$1"
[ -d "$FEATURE_DIR" ] || { echo "error: not a directory: $FEATURE_DIR" >&2; exit 2; }
FEATURE_DIR=$(cd "$FEATURE_DIR" && pwd -P)

problems=0

report() {
  # $1 = file label, $2 = reason. One line per problem, as required.
  echo "$1: $2"
  problems=$((problems + 1))
}

# Required per-ticket sections. The first two are Goal and Why this slice; the
# next seven are the mandatory structural fields; the last is Depends on.
# Contract: each ticket "must contain" the Goal/Why-this-slice sections and the
# seven structural fields (SKILL.md section 6 "Decompose into vertical tickets"
# template and its "every ticket has ..." list), and "Every dependency must be
# explicit" under a Depends on section (SKILL.md section 6).
REQUIRED_HEADERS="Goal
Why this slice
Produces
Consumers
Touched surfaces
Explicitly out of scope
Locked decisions
Evidence anchors
Regression guards
Depends on"

# Contract: "The minimum artifact set is spec.md plus tickets/" (SKILL.md
# section 2 "Planned" and section 3 "Establish the planning workspace").
# grill.md absence is a pass, not a failure: grilling is owned by task-grill and
# the Simple classification skips it (SKILL.md section 2 "Simple" and section 1
# "task-grill owns ...").
SPEC="$FEATURE_DIR/spec.md"
TICKETS_DIR="$FEATURE_DIR/tickets"

[ -f "$SPEC" ] || report "$FEATURE_DIR" "missing required artifact spec.md (minimum set is spec.md plus tickets/)"
[ -d "$TICKETS_DIR" ] || report "$FEATURE_DIR" "missing required artifact tickets/ (minimum set is spec.md plus tickets/)"

# Contract: "A ticket markdown file carries no status field" (SKILL.md section 6
# "Decompose into vertical tickets"). Execution state lives in the backlog as
# separate work items, so a status field inside the ticket file is forbidden.
ticket_has_status_field() {
  grep -Eq '\*\*[Ss]tatus:\*\*|\*\*상태:\*\*' "$1"
}

# Contract: "Every approved ticket graph MUST end with a terminal captain-review
# ticket" (SKILL.md section 6 "Terminal review ticket"), so the highest-numbered
# ticket must be that review ticket. Real notations vary (measured: "T-review:
# 사관장 검수", "캡틴 검수 (종착 티켓)", "캡틴 실물 검수"), so accept several
# signals rather than one exact title string.
is_review_ticket() {
  printf '%s' "$1" | grep -Eqi 'T-review|검수|captain[ -]?review|review ticket|terminal review|종착'
}

# Contract: "the spec carries no file paths and no code snippets" (SKILL.md
# section 5 "Template", two drafting rules). A code span (inline or fenced)
# carrying a source file path fails. One exception: a "validated prototype
# snippet" explicitly noted as coming from the prototype that validated it may
# appear (SKILL.md section 5). Planning-document self references such as
# grill.md are not path leakage (measured normal usage in three bundles).
segment_has_path_leak() {
  # Source-file extensions measured in the audit's path-leak findings.
  if printf '%s' "$1" | grep -Eq '\.(ts|tsx|swift|kt|py|sh|go|rs)([^[:alnum:]]|$)'; then
    return 0
  fi
  # a/b shape: a slash-separated path token, excluding trailing-slash dirs like
  # web/ and space-split tokens like "GET /ca", and excluding .md self
  # references to planning documents.
  if printf '%s' "$1" | grep -Eo '[A-Za-z0-9_./-]+/[A-Za-z0-9_./-]+' | grep -qv '\.md'; then
    return 0
  fi
  return 1
}

# Emit every code span in the spec: fenced blocks (between ``` lines, skipping a
# block whose opening fence is immediately preceded by a validated-prototype
# marker), then inline `...` spans. One segment per line.
extract_code_spans() {
  local bt=$'\140' pat
  pat="${bt}[^${bt}]+${bt}"
  awk '
    BEGIN { infence=0; prev=""; skip=0 }
    {
      if (/^```/) {
        if (infence) { infence=0; skip=0; prev=""; next }
        infence=1
        if (prev ~ /validated prototype|prototype that validated|from the prototype/) skip=1
        else skip=0
        prev=""
        next
      }
      if (infence && !skip) print $0
      prev=$0
    }
  ' "$1"
  grep -oE "$pat" "$1" 2>/dev/null | awk '{ print substr($0, 2, length($0)-2) }' || true
}

check_spec_paths() {
  local spec=$1 segment
  while IFS= read -r segment; do
    [ -n "$segment" ] || continue
    if segment_has_path_leak "$segment"; then
      report "$spec" "spec.md carries a file path inside a code span: '$segment' (spec must be path-free)"
    fi
  done < <(extract_code_spans "$spec")
}

# --- per-ticket checks ------------------------------------------------------

if [ -d "$TICKETS_DIR" ]; then
  for f in "$TICKETS_DIR"/T*.md; do
    [ -e "$f" ] || continue
    while IFS= read -r header; do
      [ -n "$header" ] || continue
      if ! grep -Eq "^## ${header}([[:space:]]|$)" "$f"; then
        report "$f" "missing required ticket section '## ${header}'"
      fi
    done <<< "$REQUIRED_HEADERS"

    if ticket_has_status_field "$f"; then
      report "$f" "ticket file carries a status field (**Status:** / **상태:**), which the contract forbids"
    fi
  done

  # Terminal review ticket: the highest-numbered ticket must be the review one.
  max_num=0
  max_file=
  for f in "$TICKETS_DIR"/T*.md; do
    [ -e "$f" ] || continue
    num=$(basename "$f")
    num=${num#T}
    num=${num%.md}
    num=$(printf '%s' "$num" | tr -cd '0-9')
    [ -n "$num" ] || continue
    if [ "$num" -gt "$max_num" ]; then
      max_num=$num
      max_file=$f
    fi
  done
  if [ "$max_num" -gt 0 ] && [ -n "$max_file" ]; then
    title=$(awk 'NF{print; exit}' "$max_file")
    if ! is_review_ticket "$title"; then
      report "$max_file" "highest-numbered ticket is not a review/terminal ticket; the terminal captain-review ticket must be the last numbered ticket"
    fi
  fi
fi

# --- spec path-leak check ---------------------------------------------------

if [ -f "$SPEC" ]; then
  check_spec_paths "$SPEC"
fi

if [ "$problems" -gt 0 ]; then
  exit 1
fi
exit 0
