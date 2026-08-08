#!/usr/bin/env bash
# fm-token-report.sh - read-only report of where this fleet's tokens go.
#
# Splits token volume into three sources over a recent window:
#   - firstmate's own session (this repo's own ~/.claude/projects/<dir>)
#   - crews (every other ~/.claude/projects/<dir>, one per spawned worktree)
#   - the no-mistakes pipeline (~/.no-mistakes/state.sqlite, agent_invocations)
#
# Session totals are read by streaming each session's *.jsonl line by line
# (jq's `inputs`, never `-s`/slurp) and summing every record whose
# `.message.usage` is present and whose `.timestamp` falls at or after the
# window cutoff. Pipeline totals are read with a single read-only SQL query.
# Nothing is written back to ~/.claude/ or ~/.no-mistakes/ - sqlite3 is opened
# with -readonly and jq only ever reads.
#
# Firstmate's own project directory is the Claude Code path-encoding (every
# non-alphanumeric byte replaced with '-') of this script's own repo root, so
# the split is correct whichever checkout is running it. A ~/.claude/projects
# directory whose name contains "no-mistakes" is a pipeline worker's own
# Claude session (spawned inside a no-mistakes worktree) and is excluded from
# the crew bucket - it would double-count work the sqlite query already
# reports. Every remaining directory is one crew worktree.
#
# Any source that is absent (no crews spawned yet, no pipeline database, an
# unreadable directory) reports zero for that source; the script never fails
# because one source is missing.
#
# The weighted total is a disclosed VOLUME heuristic, not a price: it weights
# raw input/cache-write/cache-read/output tokens by fixed, printed multipliers
# so sources with a very different token mix (crews emit far more output
# tokens than the pipeline) can be compared on one number. It does not know
# what any model costs and must never be read as a bill.
#
# Normalized metrics (added to compare a config change like autoCompactThreshold
# without the comparison being polluted by how much work happened to be in the
# window):
#
#   1. Cost per turn - cache_read / turns, for the own and crew branches only.
#      A turn is a transcript message whose .message.usage.cache_read_input_tokens
#      is present. The pipeline has no transcripts, so it is normalized instead
#      by validation run (metric 3, below), not by turn.
#   2. Per-session turn count and context growth rate - for the own and crew
#      branches, one row per session (jsonl file) with at least
#      SESSION_MIN_TURNS in-window turns: turn count, first in-window context
#      size, last in-window context size, and (last - first) / turns as the
#      growth-per-turn rate. This absorbs the ad hoc jq fragment that used to
#      live in data/token-baseline.md.
#      Compaction handling: a session that auto-compacts mid-window has its
#      context size drop between two turns, so the naive (last - first) /
#      turns rate can read negative or artificially low even though the
#      session kept growing between compactions. This script reports that
#      naive rate exactly as specified - reconstructing a compaction-free
#      growth curve (e.g. summing only positive deltas) would silently
#      redefine "rate" away from the numbers data/token-baseline.md already
#      recorded by hand with this same naive formula, and this tool's job is
#      to match that baseline, not to improve on it. Instead every session row
#      also carries a "compacted" flag (true if context ever dropped between
#      two consecutive in-window turns), so a reader knows when a session's
#      rate is not directly comparable to an uncompacted one.
#   3. Cost per validation run - agent_invocations grouped by run_id: the
#      per-run cache_read sum and the median of those sums across runs, plus
#      the same median with the test/ci steps excluded (those two steps are
#      currently disabled fleet-wide). started_at in agent_invocations is
#      SECONDS, not milliseconds - the same $CUTOFF_EPOCH used for the
#      existing per-step pipeline query applies unchanged.
#
# Usage:
#   fm-token-report.sh [--since <window>] [--json] [--help]
#
# Flags:
#   --since <window>   how far back to look; <N>h, <N>d, or <N>m (default: 24h)
#   --json             print the same data as one JSON object instead of a table
#   -h, --help         print this usage
#
# Read-only environment overrides (for tests; unset in normal use):
#   FM_TOKEN_REPORT_OWN_ROOT       path treated as firstmate's own repo root
#   FM_TOKEN_REPORT_PROJECTS_DIR   path treated as ~/.claude/projects
#   FM_TOKEN_REPORT_NM_DB          path treated as ~/.no-mistakes/state.sqlite
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Volume weights, disclosed in every report. Directional only (output costs
# far more than cached input; a cache write costs a bit more than fresh
# input; a cache read costs a small fraction of it) - not a price list.
readonly W_INPUT=1 W_CACHE_CREATION=1.25 W_CACHE_READ=0.1 W_OUTPUT=5

# Minimum in-window turns for a session to appear in the per-session growth
# breakdown; mirrors the >=20 cutoff the manual jq fragment used, since a
# session with only a handful of turns has too few points for a meaningful
# growth rate.
readonly SESSION_MIN_TURNS=20

usage() {
  sed -n '2,/^set -u/p' "$SCRIPT_DIR/fm-token-report.sh" | sed '$d' | sed 's/^# \{0,1\}//'
}

die() {
  echo "fm-token-report.sh: $*" >&2
  exit 1
}

parse_window_seconds() {  # <spec> -> echoes seconds, or fails
  local spec=$1 num=${1%[hdm]} unit=${1: -1}
  case "$spec" in
    *h|*d|*m) ;;
    *) return 1 ;;
  esac
  case "$num" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$unit" in
    h) echo $((num * 3600)) ;;
    d) echo $((num * 86400)) ;;
    m) echo $((num * 60)) ;;
  esac
}

epoch_to_iso() {  # <epoch-seconds> -> echoes YYYY-MM-DDTHH:MM:SS.000Z
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z
  else
    date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z
  fi
}

encode_path() {  # <path> -> Claude Code's ~/.claude/projects directory name
  printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'
}

# Streams every *.jsonl in <dir> and prints "input output cache_read
# cache_creation sessions_with_activity turns", tab-separated, for records at
# or after $CUTOFF_ISO. Never slurps a whole file into memory. "turns" counts
# records whose .message.usage.cache_read_input_tokens is present - see the
# cost-per-turn metric documented in the file header.
sum_dir_usage() {  # <dir>
  local dir=$1 file i=0 o=0 cr=0 cc=0 n=0 t=0 row file_i file_o file_cr file_cc file_n file_t
  [ -d "$dir" ] || { printf '0\t0\t0\t0\t0\t0\n'; return 0; }
  shopt -s nullglob
  for file in "$dir"/*.jsonl; do
    row=$(jq -nr --arg cutoff "$CUTOFF_ISO" '
      reduce (inputs
              | select(.timestamp != null and .timestamp >= $cutoff and .message.usage != null)
              | .message.usage) as $u
        ({i:0,o:0,cr:0,cc:0,n:0,t:0};
         {i:  (.i  + ($u.input_tokens // 0)),
          o:  (.o  + ($u.output_tokens // 0)),
          cr: (.cr + ($u.cache_read_input_tokens // 0)),
          cc: (.cc + ($u.cache_creation_input_tokens // 0)),
          n:  (.n  + 1),
          t:  (.t  + (if $u.cache_read_input_tokens != null then 1 else 0 end))})
      | "\(.i)\t\(.o)\t\(.cr)\t\(.cc)\t\(.n)\t\(.t)"
    ' "$file" 2>/dev/null) || row=$'0\t0\t0\t0\t0\t0'
    IFS=$'\t' read -r file_i file_o file_cr file_cc file_n file_t <<<"$row"
    i=$((i + file_i)); o=$((o + file_o)); cr=$((cr + file_cr)); cc=$((cc + file_cc))
    [ "$file_n" -gt 0 ] && n=$((n + 1))
    t=$((t + file_t))
  done
  shopt -u nullglob
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "$o" "$cr" "$cc" "$n" "$t"
}

# Streams every *.jsonl in <dir> and prints one row per session (file) that
# has at least SESSION_MIN_TURNS in-window turns: "session turns first_context
# last_context growth_per_turn compacted", tab-separated. compacted is 1/0.
# See the file header for the compaction-handling rationale.
session_stats_for_dir() {  # <dir>
  local dir=$1 file
  [ -d "$dir" ] || return 0
  shopt -s nullglob
  for file in "$dir"/*.jsonl; do
    jq -nr --arg cutoff "$CUTOFF_ISO" --arg session "$(basename "$file" .jsonl)" --argjson min "$SESSION_MIN_TURNS" '
      [inputs
       | select(.timestamp != null and .timestamp >= $cutoff and .message.usage.cache_read_input_tokens != null)
       | .message.usage.cache_read_input_tokens] as $m
      | if ($m | length) < $min then empty else
          ($m | length) as $n
          | $m[0] as $first
          | $m[-1] as $last
          | ((($last - $first) / $n * 100 | round) / 100) as $rate
          | ([range(1; $n) as $i | select($m[$i] < $m[$i - 1])] | length > 0) as $compacted
          | "\($session)\t\($n)\t\($first)\t\($last)\t\($rate)\t\(if $compacted then 1 else 0 end)"
        end
    ' "$file" 2>/dev/null
  done
  shopt -u nullglob
}

weighted() {  # <input> <output> <cache_read> <cache_creation> -> echoes weighted total
  awk -v i="$1" -v o="$2" -v cr="$3" -v cc="$4" \
      -v wi="$W_INPUT" -v wo="$W_OUTPUT" -v wcr="$W_CACHE_READ" -v wcc="$W_CACHE_CREATION" \
      'BEGIN { printf "%.0f", i*wi + o*wo + cr*wcr + cc*wcc }'
}

share_pct() {  # <part> <total> -> echoes "N.N"
  awk -v p="$1" -v t="$2" 'BEGIN { if (t+0 == 0) { print "0.0" } else { printf "%.1f", (p/t)*100 } }'
}

cr_per_turn() {  # <cache_read> <turns> -> echoes a JSON number literal, or the literal null
  awk -v cr="$1" -v t="$2" 'BEGIN { if (t+0 == 0) { print "null" } else { printf "%.2f", cr/t } }'
}

display_or_na() {  # <cr_per_turn output> -> echoes the value, or "n/a" for null
  [ "$1" = null ] && echo "n/a" || echo "$1"
}

median_of() {  # <values...> -> echoes the median, or nothing if no values given
  [ $# -eq 0 ] && return 0
  printf '%s\n' "$@" | jq -R -s '
    [splits("\n") | select(length > 0) | tonumber] | sort as $s
    | ($s | length) as $n
    | ($n / 2 | floor) as $mid
    | if $n == 0 then empty
      elif $n % 2 == 1 then $s[$mid]
      else ($s[$mid - 1] + $s[$mid]) / 2
      end
  '
}

SINCE=24h
JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --since) [ $# -ge 2 ] || die "--since needs a value"; SINCE=$2; shift 2 ;;
    --since=*) SINCE=${1#--since=}; shift ;;
    --json) JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

WINDOW_SECONDS=$(parse_window_seconds "$SINCE") \
  || die "invalid --since value: $SINCE (expected <N>h, <N>d, or <N>m)"

command -v jq >/dev/null 2>&1 || die "jq is required"

NOW_EPOCH=$(date -u +%s)
CUTOFF_EPOCH=$((NOW_EPOCH - WINDOW_SECONDS))
CUTOFF_ISO=$(epoch_to_iso "$CUTOFF_EPOCH")

OWN_ROOT="${FM_TOKEN_REPORT_OWN_ROOT:-$ROOT}"
PROJECTS_DIR="${FM_TOKEN_REPORT_PROJECTS_DIR:-$HOME/.claude/projects}"
NM_DB="${FM_TOKEN_REPORT_NM_DB:-$HOME/.no-mistakes/state.sqlite}"
OWN_DIR_NAME=$(encode_path "$OWN_ROOT")

# --- firstmate's own session -------------------------------------------------
IFS=$'\t' read -r OWN_I OWN_O OWN_CR OWN_CC OWN_N OWN_T <<<"$(sum_dir_usage "$PROJECTS_DIR/$OWN_DIR_NAME")"

OWN_SESSIONS=()
while IFS=$'\t' read -r sess turns first_ctx last_ctx rate compacted; do
  [ -n "$sess" ] || continue
  OWN_SESSIONS+=("$sess"$'\t'"$turns"$'\t'"$first_ctx"$'\t'"$last_ctx"$'\t'"$rate"$'\t'"$compacted")
done < <(session_stats_for_dir "$PROJECTS_DIR/$OWN_DIR_NAME")

# --- crews, one row per worktree ---------------------------------------------
CREW_I=0 CREW_O=0 CREW_CR=0 CREW_CC=0 CREW_N=0 CREW_T=0
CREW_WORKTREES=0
CREW_ROWS=()
CREW_SESSIONS=()
if [ -d "$PROJECTS_DIR" ]; then
  for entry in "$PROJECTS_DIR"/*/; do
    [ -d "$entry" ] || continue
    name=$(basename "$entry")
    [ "$name" = "$OWN_DIR_NAME" ] && continue
    case "$name" in *no-mistakes*) continue ;; esac
    IFS=$'\t' read -r di do_ dcr dcc dn dt <<<"$(sum_dir_usage "$entry")"
    [ "$dn" -gt 0 ] || continue
    CREW_I=$((CREW_I + di)); CREW_O=$((CREW_O + do_))
    CREW_CR=$((CREW_CR + dcr)); CREW_CC=$((CREW_CC + dcc))
    CREW_N=$((CREW_N + dn)); CREW_T=$((CREW_T + dt)); CREW_WORKTREES=$((CREW_WORKTREES + 1))
    CREW_ROWS+=("$name"$'\t'"$di"$'\t'"$do_"$'\t'"$dcr"$'\t'"$dcc"$'\t'"$dn")
    while IFS=$'\t' read -r sess turns first_ctx last_ctx rate compacted; do
      [ -n "$sess" ] || continue
      CREW_SESSIONS+=("$name"$'\t'"$sess"$'\t'"$turns"$'\t'"$first_ctx"$'\t'"$last_ctx"$'\t'"$rate"$'\t'"$compacted")
    done < <(session_stats_for_dir "$entry")
  done
fi

# --- no-mistakes pipeline -----------------------------------------------------
NM_I=0 NM_O=0 NM_CR=0 NM_CC=0 NM_N=0
NM_ROWS=()
NM_PRESENT=0
NM_RUN_TOTAL_CR=()
NM_RUN_FILTERED_CR=()
if [ -f "$NM_DB" ] && command -v sqlite3 >/dev/null 2>&1; then
  NM_PRESENT=1
  while IFS=$'\t' read -r step cnt si so scr scc; do
    [ -n "$step" ] || continue
    NM_I=$((NM_I + si)); NM_O=$((NM_O + so))
    NM_CR=$((NM_CR + scr)); NM_CC=$((NM_CC + scc)); NM_N=$((NM_N + cnt))
    NM_ROWS+=("$step"$'\t'"$cnt"$'\t'"$si"$'\t'"$so"$'\t'"$scr"$'\t'"$scc")
  done < <(sqlite3 -readonly -separator "$(printf '\t')" "$NM_DB" "
    SELECT step_name, COUNT(*),
           COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0),
           COALESCE(SUM(cache_read_tokens),0), COALESCE(SUM(cache_creation_tokens),0)
    FROM agent_invocations
    WHERE started_at >= $CUTOFF_EPOCH
    GROUP BY step_name
    ORDER BY step_name;
  " 2>/dev/null)

  # started_at is SECONDS, not milliseconds - $CUTOFF_EPOCH above already is too.
  while IFS=$'\t' read -r run_id total_cr filtered_cr; do
    [ -n "$run_id" ] || continue
    NM_RUN_TOTAL_CR+=("$total_cr")
    NM_RUN_FILTERED_CR+=("$filtered_cr")
  done < <(sqlite3 -readonly -separator "$(printf '\t')" "$NM_DB" "
    SELECT run_id,
           COALESCE(SUM(cache_read_tokens),0),
           COALESCE(SUM(CASE WHEN step_name NOT IN ('test','ci') THEN cache_read_tokens ELSE 0 END),0)
    FROM agent_invocations
    WHERE started_at >= $CUTOFF_EPOCH
    GROUP BY run_id
    ORDER BY run_id;
  " 2>/dev/null)
fi
NM_RUN_COUNT=${#NM_RUN_TOTAL_CR[@]}
NM_RUN_CR_MEDIAN=$(median_of "${NM_RUN_TOTAL_CR[@]+"${NM_RUN_TOTAL_CR[@]}"}")
NM_RUN_CR_MEDIAN_FILTERED=$(median_of "${NM_RUN_FILTERED_CR[@]+"${NM_RUN_FILTERED_CR[@]}"}")

OWN_W=$(weighted "$OWN_I" "$OWN_O" "$OWN_CR" "$OWN_CC")
CREW_W=$(weighted "$CREW_I" "$CREW_O" "$CREW_CR" "$CREW_CC")
NM_W=$(weighted "$NM_I" "$NM_O" "$NM_CR" "$NM_CC")
TOTAL_W=$((OWN_W + CREW_W + NM_W))
OWN_PCT=$(share_pct "$OWN_W" "$TOTAL_W")
CREW_PCT=$(share_pct "$CREW_W" "$TOTAL_W")
NM_PCT=$(share_pct "$NM_W" "$TOTAL_W")

OWN_CR_PER_TURN=$(cr_per_turn "$OWN_CR" "$OWN_T")
CREW_CR_PER_TURN=$(cr_per_turn "$CREW_CR" "$CREW_T")

if [ "$JSON" -eq 1 ]; then
  {
    printf '{"schema":"fm-token-report.v1","generated":"%s","since":"%s","cutoff":"%s",' \
      "$(epoch_to_iso "$NOW_EPOCH")" "$SINCE" "$CUTOFF_ISO"
    printf '"weights":{"input":%s,"cache_creation":%s,"cache_read":%s,"output":%s},' \
      "$W_INPUT" "$W_CACHE_CREATION" "$W_CACHE_READ" "$W_OUTPUT"
    printf '"own":{"root":%s,"input_tokens":%s,"output_tokens":%s,"cache_read_tokens":%s,"cache_creation_tokens":%s,"sessions":%s,"weighted":%s,"share_pct":%s,"turns":%s,"cache_read_per_turn":%s},' \
      "$(jq -Rn --arg v "$OWN_ROOT" '$v')" "$OWN_I" "$OWN_O" "$OWN_CR" "$OWN_CC" "$OWN_N" "$OWN_W" "$OWN_PCT" "$OWN_T" "$OWN_CR_PER_TURN"
    printf '"crews":{"input_tokens":%s,"output_tokens":%s,"cache_read_tokens":%s,"cache_creation_tokens":%s,"sessions":%s,"worktrees":%s,"weighted":%s,"share_pct":%s,"turns":%s,"cache_read_per_turn":%s,"by_worktree":[' \
      "$CREW_I" "$CREW_O" "$CREW_CR" "$CREW_CC" "$CREW_N" "$CREW_WORKTREES" "$CREW_W" "$CREW_PCT" "$CREW_T" "$CREW_CR_PER_TURN"
    first=1
    for row in "${CREW_ROWS[@]+"${CREW_ROWS[@]}"}"; do
      IFS=$'\t' read -r n di do_ dcr dcc dn <<<"$row"
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '{"worktree":%s,"input_tokens":%s,"output_tokens":%s,"cache_read_tokens":%s,"cache_creation_tokens":%s,"sessions":%s}' \
        "$(jq -Rn --arg v "$n" '$v')" "$di" "$do_" "$dcr" "$dcc" "$dn"
    done
    printf ']},'
    printf '"pipeline":{"present":%s,"input_tokens":%s,"output_tokens":%s,"cache_read_tokens":%s,"cache_creation_tokens":%s,"invocations":%s,"weighted":%s,"share_pct":%s,"by_step":[' \
      "$([ "$NM_PRESENT" -eq 1 ] && echo true || echo false)" "$NM_I" "$NM_O" "$NM_CR" "$NM_CC" "$NM_N" "$NM_W" "$NM_PCT"
    first=1
    for row in "${NM_ROWS[@]+"${NM_ROWS[@]}"}"; do
      IFS=$'\t' read -r step cnt si so scr scc <<<"$row"
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '{"step":%s,"invocations":%s,"input_tokens":%s,"output_tokens":%s,"cache_read_tokens":%s,"cache_creation_tokens":%s}' \
        "$(jq -Rn --arg v "$step" '$v')" "$cnt" "$si" "$so" "$scr" "$scc"
    done
    printf ']},'
    printf '"sessions":{"own":['
    first=1
    for row in "${OWN_SESSIONS[@]+"${OWN_SESSIONS[@]}"}"; do
      IFS=$'\t' read -r sess turns first_ctx last_ctx rate compacted <<<"$row"
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '{"session":%s,"turns":%s,"first_context":%s,"last_context":%s,"growth_per_turn":%s,"compacted":%s}' \
        "$(jq -Rn --arg v "$sess" '$v')" "$turns" "$first_ctx" "$last_ctx" "$rate" "$([ "$compacted" -eq 1 ] && echo true || echo false)"
    done
    printf '],"crews":['
    first=1
    for row in "${CREW_SESSIONS[@]+"${CREW_SESSIONS[@]}"}"; do
      IFS=$'\t' read -r wt sess turns first_ctx last_ctx rate compacted <<<"$row"
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '{"worktree":%s,"session":%s,"turns":%s,"first_context":%s,"last_context":%s,"growth_per_turn":%s,"compacted":%s}' \
        "$(jq -Rn --arg v "$wt" '$v')" "$(jq -Rn --arg v "$sess" '$v')" "$turns" "$first_ctx" "$last_ctx" "$rate" "$([ "$compacted" -eq 1 ] && echo true || echo false)"
    done
    printf ']},'
    printf '"pipeline_runs":{"present":%s,"runs":%s,"median_cache_read":%s,"median_cache_read_excl_test_ci":%s}' \
      "$([ "$NM_PRESENT" -eq 1 ] && echo true || echo false)" "$NM_RUN_COUNT" \
      "${NM_RUN_CR_MEDIAN:-null}" "${NM_RUN_CR_MEDIAN_FILTERED:-null}"
    printf '}\n'
  } | jq .
  exit 0
fi

printf 'fm-token-report - window: last %s (since %s)\n' "$SINCE" "$CUTOFF_ISO"
printf 'weighted total = input*%s + cache_creation*%s + cache_read*%s + output*%s\n' \
  "$W_INPUT" "$W_CACHE_CREATION" "$W_CACHE_READ" "$W_OUTPUT"
printf 'these are disclosed VOLUME weights, not prices - this tool does not estimate cost.\n\n'

printf '%-24s %14s %14s %14s %14s %8s %14s %6s\n' \
  source input output cache_read cache_write count weighted share
printf 'firstmate own session    %14s %14s %14s %14s %8s %14s %5s%%\n' \
  "$OWN_I" "$OWN_O" "$OWN_CR" "$OWN_CC" "$OWN_N" "$OWN_W" "$OWN_PCT"
printf 'crews (%s worktrees)%*s%14s %14s %14s %14s %8s %14s %5s%%\n' \
  "$CREW_WORKTREES" "$((17 - ${#CREW_WORKTREES}))" '' "$CREW_I" "$CREW_O" "$CREW_CR" "$CREW_CC" "$CREW_N" "$CREW_W" "$CREW_PCT"
printf 'no-mistakes pipeline     %14s %14s %14s %14s %8s %14s %5s%%\n' \
  "$NM_I" "$NM_O" "$NM_CR" "$NM_CC" "$NM_N" "$NM_W" "$NM_PCT"
[ "$NM_PRESENT" -eq 1 ] || printf '  (no-mistakes database not found at %s: reporting zero)\n' "$NM_DB"

if [ "${#CREW_ROWS[@]}" -gt 0 ]; then
  printf '\nby worktree:\n'
  printf '%-56s %14s %14s %14s %14s %8s\n' worktree input output cache_read cache_write count
  for row in "${CREW_ROWS[@]}"; do
    IFS=$'\t' read -r n di do_ dcr dcc dn <<<"$row"
    printf '%-56s %14s %14s %14s %14s %8s\n' "$n" "$di" "$do_" "$dcr" "$dcc" "$dn"
  done
fi

if [ "${#NM_ROWS[@]}" -gt 0 ]; then
  printf '\nby pipeline step:\n'
  printf '%-24s %14s %14s %14s %14s %8s\n' step input output cache_read cache_write invocations
  for row in "${NM_ROWS[@]}"; do
    IFS=$'\t' read -r step cnt si so scr scc <<<"$row"
    printf '%-24s %14s %14s %14s %14s %8s\n' "$step" "$si" "$so" "$scr" "$scc" "$cnt"
  done
fi

printf '\nper-turn cost (cache_read / turns; a turn is a transcript message with cache_read_input_tokens):\n'
printf '  firstmate own session: %-10s (turns: %s)\n' "$(display_or_na "$OWN_CR_PER_TURN")" "$OWN_T"
printf '  crews:                 %-10s (turns: %s)\n' "$(display_or_na "$CREW_CR_PER_TURN")" "$CREW_T"

if [ "${#OWN_SESSIONS[@]}" -gt 0 ] || [ "${#CREW_SESSIONS[@]}" -gt 0 ]; then
  printf '\nsession growth (sessions with >= %s in-window turns; rate = (last-first)/turns;\n' "$SESSION_MIN_TURNS"
  printf 'compacted = context dropped mid-session, so rate is not directly comparable):\n'
  if [ "${#OWN_SESSIONS[@]}" -gt 0 ]; then
    printf '  firstmate own session:\n'
    printf '  %-40s %8s %14s %14s %10s %10s\n' session turns first last rate compacted
    for row in "${OWN_SESSIONS[@]}"; do
      IFS=$'\t' read -r sess turns first_ctx last_ctx rate compacted <<<"$row"
      printf '  %-40s %8s %14s %14s %10s %10s\n' \
        "$sess" "$turns" "$first_ctx" "$last_ctx" "$rate" "$([ "$compacted" -eq 1 ] && echo yes || echo no)"
    done
  fi
  if [ "${#CREW_SESSIONS[@]}" -gt 0 ]; then
    printf '  crews:\n'
    printf '  %-32s %-40s %8s %14s %14s %10s %10s\n' worktree session turns first last rate compacted
    for row in "${CREW_SESSIONS[@]}"; do
      IFS=$'\t' read -r wt sess turns first_ctx last_ctx rate compacted <<<"$row"
      printf '  %-32s %-40s %8s %14s %14s %10s %10s\n' \
        "$wt" "$sess" "$turns" "$first_ctx" "$last_ctx" "$rate" "$([ "$compacted" -eq 1 ] && echo yes || echo no)"
    done
  fi
fi

printf '\nvalidation runs (agent_invocations grouped by run_id):\n'
if [ "$NM_PRESENT" -eq 1 ]; then
  if [ "$NM_RUN_COUNT" -gt 0 ]; then
    printf '  runs: %s\n' "$NM_RUN_COUNT"
    printf '  median cache_read per run: %s\n' "$NM_RUN_CR_MEDIAN"
    printf '  median cache_read per run (excl. test/ci): %s\n' "$NM_RUN_CR_MEDIAN_FILTERED"
  else
    printf '  no runs in window: reporting none\n'
  fi
else
  printf '  no-mistakes database not found at %s: reporting none\n' "$NM_DB"
fi
