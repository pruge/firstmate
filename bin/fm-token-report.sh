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
# cache_creation sessions_with_activity", tab-separated, for records at or
# after $CUTOFF_ISO. Never slurps a whole file into memory.
sum_dir_usage() {  # <dir>
  local dir=$1 file i=0 o=0 cr=0 cc=0 n=0 row file_i file_o file_cr file_cc file_n
  [ -d "$dir" ] || { printf '0\t0\t0\t0\t0\n'; return 0; }
  shopt -s nullglob
  for file in "$dir"/*.jsonl; do
    row=$(jq -nr --arg cutoff "$CUTOFF_ISO" '
      reduce (inputs
              | select(.timestamp != null and .timestamp >= $cutoff and .message.usage != null)
              | .message.usage) as $u
        ({i:0,o:0,cr:0,cc:0,n:0};
         {i:  (.i  + ($u.input_tokens // 0)),
          o:  (.o  + ($u.output_tokens // 0)),
          cr: (.cr + ($u.cache_read_input_tokens // 0)),
          cc: (.cc + ($u.cache_creation_input_tokens // 0)),
          n:  (.n  + 1)})
      | "\(.i)\t\(.o)\t\(.cr)\t\(.cc)\t\(.n)"
    ' "$file" 2>/dev/null) || row=$'0\t0\t0\t0\t0'
    IFS=$'\t' read -r file_i file_o file_cr file_cc file_n <<<"$row"
    i=$((i + file_i)); o=$((o + file_o)); cr=$((cr + file_cr)); cc=$((cc + file_cc))
    [ "$file_n" -gt 0 ] && n=$((n + 1))
  done
  shopt -u nullglob
  printf '%s\t%s\t%s\t%s\t%s\n' "$i" "$o" "$cr" "$cc" "$n"
}

weighted() {  # <input> <output> <cache_read> <cache_creation> -> echoes weighted total
  awk -v i="$1" -v o="$2" -v cr="$3" -v cc="$4" \
      -v wi="$W_INPUT" -v wo="$W_OUTPUT" -v wcr="$W_CACHE_READ" -v wcc="$W_CACHE_CREATION" \
      'BEGIN { printf "%.0f", i*wi + o*wo + cr*wcr + cc*wcc }'
}

share_pct() {  # <part> <total> -> echoes "N.N"
  awk -v p="$1" -v t="$2" 'BEGIN { if (t+0 == 0) { print "0.0" } else { printf "%.1f", (p/t)*100 } }'
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
IFS=$'\t' read -r OWN_I OWN_O OWN_CR OWN_CC OWN_N <<<"$(sum_dir_usage "$PROJECTS_DIR/$OWN_DIR_NAME")"

# --- crews, one row per worktree ---------------------------------------------
CREW_I=0 CREW_O=0 CREW_CR=0 CREW_CC=0 CREW_N=0
CREW_WORKTREES=0
CREW_ROWS=()
if [ -d "$PROJECTS_DIR" ]; then
  for entry in "$PROJECTS_DIR"/*/; do
    [ -d "$entry" ] || continue
    name=$(basename "$entry")
    [ "$name" = "$OWN_DIR_NAME" ] && continue
    case "$name" in *no-mistakes*) continue ;; esac
    IFS=$'\t' read -r di do_ dcr dcc dn <<<"$(sum_dir_usage "$entry")"
    [ "$dn" -gt 0 ] || continue
    CREW_I=$((CREW_I + di)); CREW_O=$((CREW_O + do_))
    CREW_CR=$((CREW_CR + dcr)); CREW_CC=$((CREW_CC + dcc))
    CREW_N=$((CREW_N + dn)); CREW_WORKTREES=$((CREW_WORKTREES + 1))
    CREW_ROWS+=("$name"$'\t'"$di"$'\t'"$do_"$'\t'"$dcr"$'\t'"$dcc"$'\t'"$dn")
  done
fi

# --- no-mistakes pipeline -----------------------------------------------------
NM_I=0 NM_O=0 NM_CR=0 NM_CC=0 NM_N=0
NM_ROWS=()
NM_PRESENT=0
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
fi

OWN_W=$(weighted "$OWN_I" "$OWN_O" "$OWN_CR" "$OWN_CC")
CREW_W=$(weighted "$CREW_I" "$CREW_O" "$CREW_CR" "$CREW_CC")
NM_W=$(weighted "$NM_I" "$NM_O" "$NM_CR" "$NM_CC")
TOTAL_W=$((OWN_W + CREW_W + NM_W))
OWN_PCT=$(share_pct "$OWN_W" "$TOTAL_W")
CREW_PCT=$(share_pct "$CREW_W" "$TOTAL_W")
NM_PCT=$(share_pct "$NM_W" "$TOTAL_W")

if [ "$JSON" -eq 1 ]; then
  {
    printf '{"schema":"fm-token-report.v1","generated":"%s","since":"%s","cutoff":"%s",' \
      "$(epoch_to_iso "$NOW_EPOCH")" "$SINCE" "$CUTOFF_ISO"
    printf '"weights":{"input":%s,"cache_creation":%s,"cache_read":%s,"output":%s},' \
      "$W_INPUT" "$W_CACHE_CREATION" "$W_CACHE_READ" "$W_OUTPUT"
    printf '"own":{"root":%s,"input_tokens":%s,"output_tokens":%s,"cache_read_tokens":%s,"cache_creation_tokens":%s,"sessions":%s,"weighted":%s,"share_pct":%s},' \
      "$(jq -Rn --arg v "$OWN_ROOT" '$v')" "$OWN_I" "$OWN_O" "$OWN_CR" "$OWN_CC" "$OWN_N" "$OWN_W" "$OWN_PCT"
    printf '"crews":{"input_tokens":%s,"output_tokens":%s,"cache_read_tokens":%s,"cache_creation_tokens":%s,"sessions":%s,"worktrees":%s,"weighted":%s,"share_pct":%s,"by_worktree":[' \
      "$CREW_I" "$CREW_O" "$CREW_CR" "$CREW_CC" "$CREW_N" "$CREW_WORKTREES" "$CREW_W" "$CREW_PCT"
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
    printf ']}}\n'
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
