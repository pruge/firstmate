#!/usr/bin/env bash
# Behavior tests for bin/fm-token-report.sh: the three-way own/crew/pipeline
# split, window filtering, no-mistakes-worktree exclusion from the crew
# bucket, graceful zero-reporting when a source is absent, and basic argument
# handling. Exercises the script only through its --json/table output and
# exit status, never its internal functions.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-token-report.sh"
TMP_ROOT=$(fm_test_tmproot fm-token-report)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

epoch_to_iso() {  # <epoch-seconds> -> YYYY-MM-DDTHH:MM:SS.000Z
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z
  else
    date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z
  fi
}

NOW=$(date -u +%s)
RECENT_EPOCH=$((NOW - 60))
OLD_EPOCH=$((NOW - 7200))
RECENT_ISO=$(epoch_to_iso "$RECENT_EPOCH")
OLD_ISO=$(epoch_to_iso "$OLD_EPOCH")

usage_line() {  # <input> <output> <cache_read> <cache_creation> <iso-timestamp>
  printf '{"timestamp":"%s","message":{"usage":{"input_tokens":%s,"output_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s}}}\n' \
    "$5" "$1" "$2" "$3" "$4"
}

make_fixture() {
  local base=$1 projects own_dir crew_dir crew2_dir nm_worktree_dir

  own_dir="$base/claude-projects/own-encoded-root"
  crew_dir="$base/claude-projects/-Users-x--treehouse-proj-aaa-1-proj"
  crew2_dir="$base/claude-projects/-Users-x--treehouse-proj-aaa-2-proj"
  nm_worktree_dir="$base/claude-projects/-Users-x--no-mistakes-worktrees-abc-1"
  projects="$base/claude-projects"
  mkdir -p "$own_dir" "$crew_dir" "$crew2_dir" "$nm_worktree_dir"

  # Own session: one in-window record, one stale record (must be excluded).
  {
    usage_line 100 200 3000 400 "$RECENT_ISO"
    usage_line 999 999 9999 999 "$OLD_ISO"
    echo '{"timestamp":"'"$RECENT_ISO"'","type":"summary"}'
  } > "$own_dir/session-a.jsonl"

  # Crew worktree 1: two in-window records across the same file.
  {
    usage_line 10 20 300 40 "$RECENT_ISO"
    usage_line 5 6 70 8 "$RECENT_ISO"
  } > "$crew_dir/session-b.jsonl"

  # Crew worktree 2: one in-window record, entirely idle otherwise.
  usage_line 1 2 30 4 "$RECENT_ISO" > "$crew2_dir/session-c.jsonl"

  # A no-mistakes-owned Claude session dir: must never appear in the crew bucket.
  usage_line 777 777 7777 777 "$RECENT_ISO" > "$nm_worktree_dir/session-d.jsonl"

  printf '%s\n' "$projects"
}

make_nm_db() {  # <path>
  local db=$1
  sqlite3 "$db" "
    CREATE TABLE agent_invocations (
      id TEXT PRIMARY KEY, run_id TEXT NOT NULL, step_name TEXT NOT NULL,
      round INTEGER NOT NULL, purpose TEXT NOT NULL, agent TEXT NOT NULL,
      session_mode TEXT NOT NULL, started_at INTEGER NOT NULL,
      completed_at INTEGER NOT NULL, duration_ms INTEGER NOT NULL,
      exit_status TEXT NOT NULL,
      input_tokens INTEGER, output_tokens INTEGER,
      cache_read_tokens INTEGER, cache_creation_tokens INTEGER
    );
    INSERT INTO agent_invocations VALUES
      ('r1','run1','review',1,'p','a','sync',$RECENT_EPOCH,$RECENT_EPOCH,1,'ok',50,60,700,80),
      ('r2','run1','review',1,'p','a','sync',$RECENT_EPOCH,$RECENT_EPOCH,1,'ok',5,6,70,8),
      ('t1','run1','test',1,'p','a','sync',$RECENT_EPOCH,$RECENT_EPOCH,1,'ok',1,2,30,4),
      ('old1','run1','review',1,'p','a','sync',$OLD_EPOCH,$OLD_EPOCH,1,'ok',999,999,9999,999);
  "
}

# --- three-way split with all sources present --------------------------------

FIXTURE_BASE="$TMP_ROOT/full"
mkdir -p "$FIXTURE_BASE"
PROJECTS=$(make_fixture "$FIXTURE_BASE")
NM_DB="$FIXTURE_BASE/state.sqlite"

if command -v sqlite3 >/dev/null 2>&1; then
  make_nm_db "$NM_DB"

  # Point own-root at the exact directory whose encoded name is own-encoded-root:
  # encode_path replaces every non-alnum byte with '-', and this path's basename
  # already is alnum-only, so the own directory is "own-encoded-root" itself.
  OUT=$(FM_TOKEN_REPORT_OWN_ROOT="own-encoded-root" \
        FM_TOKEN_REPORT_PROJECTS_DIR="$PROJECTS" \
        FM_TOKEN_REPORT_NM_DB="$NM_DB" \
        bash "$SCRIPT" --since 1h --json) || fail "full-fixture run exited nonzero"

  echo "$OUT" | jq -e '.own.input_tokens == 100 and .own.output_tokens == 200 and .own.cache_read_tokens == 3000 and .own.cache_creation_tokens == 400 and .own.sessions == 1' >/dev/null \
    || fail "own totals wrong (window filter or own-dir match failed): $OUT"

  echo "$OUT" | jq -e '.crews.input_tokens == 16 and .crews.output_tokens == 28 and .crews.cache_read_tokens == 400 and .crews.cache_creation_tokens == 52 and .crews.worktrees == 2 and .crews.sessions == 2' >/dev/null \
    || fail "crew totals wrong (no-mistakes worktree leaked in, or window filter wrong): $OUT"

  echo "$OUT" | jq -e '(.crews.by_worktree | length) == 2' >/dev/null \
    || fail "expected exactly two crew worktrees in by_worktree, no-mistakes dir excluded: $OUT"

  echo "$OUT" | jq -e '.pipeline.present == true and .pipeline.input_tokens == 56 and .pipeline.output_tokens == 68 and .pipeline.cache_read_tokens == 800 and .pipeline.invocations == 3' >/dev/null \
    || fail "pipeline totals wrong (window filter or step aggregation failed): $OUT"

  echo "$OUT" | jq -e '[.pipeline.by_step[].step] == ["review","test"]' >/dev/null \
    || fail "pipeline per-step breakdown missing/wrong: $OUT"

  echo "$OUT" | jq -e '.weights.output == 5 and .weights.cache_read == 0.1' >/dev/null \
    || fail "weights not disclosed in JSON output: $OUT"

  # Weighted share is a stated heuristic, not free-floating: recompute it from
  # the raw totals with the same disclosed weights and require exact agreement.
  echo "$OUT" | jq -e '
    (.own.input_tokens*.weights.input + .own.output_tokens*.weights.output + .own.cache_read_tokens*.weights.cache_read + .own.cache_creation_tokens*.weights.cache_creation | round) == .own.weighted
  ' >/dev/null || fail "own weighted total does not match disclosed weights: $OUT"

  pass "three-way split: own/crew/pipeline totals, window filter, no-mistakes exclusion"

  # Table output states the same disclosed weights and does not blow up.
  TABLE=$(FM_TOKEN_REPORT_OWN_ROOT="own-encoded-root" \
          FM_TOKEN_REPORT_PROJECTS_DIR="$PROJECTS" \
          FM_TOKEN_REPORT_NM_DB="$NM_DB" \
          bash "$SCRIPT" --since 1h) || fail "table-mode run exited nonzero"
  case "$TABLE" in
    *"not prices"*) ;;
    *) fail "table output missing the not-a-price disclosure" ;;
  esac
  case "$TABLE" in
    *"crews (2 worktrees)"*) ;;
    *) fail "table output missing crew worktree count: $TABLE" ;;
  esac
  pass "table output discloses weights and crew worktree count"
else
  echo "skip: sqlite3 not found (pipeline assertions skipped)"
fi

# --- both sources absent: zero, not a failure ---------------------------------

EMPTY_BASE="$TMP_ROOT/empty"
mkdir -p "$EMPTY_BASE/claude-projects"
OUT=$(FM_TOKEN_REPORT_OWN_ROOT="$EMPTY_BASE/nowhere" \
      FM_TOKEN_REPORT_PROJECTS_DIR="$EMPTY_BASE/claude-projects" \
      FM_TOKEN_REPORT_NM_DB="$EMPTY_BASE/no-such.sqlite" \
      bash "$SCRIPT" --since 1h --json)
RC=$?
[ "$RC" -eq 0 ] || fail "absent sources should exit 0, got $RC"
echo "$OUT" | jq -e '.own.input_tokens == 0 and .crews.input_tokens == 0 and .pipeline.present == false and .pipeline.input_tokens == 0' >/dev/null \
  || fail "absent sources should report zero, not fail: $OUT"
pass "missing crews and missing pipeline database both report zero without failing"

# --- argument handling ---------------------------------------------------------

bash "$SCRIPT" --help | grep -q "fm-token-report.sh" || fail "--help did not print usage"
pass "--help prints usage"

if bash "$SCRIPT" --since not-a-window >/dev/null 2>&1; then
  fail "invalid --since should exit nonzero"
fi
pass "invalid --since window is rejected"

if bash "$SCRIPT" --nope >/dev/null 2>&1; then
  fail "unknown flag should exit nonzero"
fi
pass "unknown flag is rejected"

exit 0
