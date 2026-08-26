#!/usr/bin/env bash
# fm-project.sh - one read-only door to a registered project's code.
#
# Usage: fm-project.sh <project> <verb> [args...]
#        fm-project.sh list
#
# WHY THIS EXISTS
# A CodeGraph index does not follow the working tree. It goes stale silently:
# `codegraph status` can report zero pending changes and no reindex
# recommendation while a symbol that exists in the tree answers "No results
# found". Observed 2026-08-26 on the gootte clone - the index was built
# 2026-08-24, ten merges had landed since, and `query allTickets` returned
# nothing although core/src/project/features.ts defines it. A silent empty
# answer reads as "that code does not exist", which is how an incomplete
# consumer sweep gets written. Re-syncing took 1.6s.
#
# So every read verb below syncs the index BEFORE it answers, and says so out
# loud when the sync fails instead of serving a possibly-stale answer quietly.
# That is this script's whole reason to exist; the shorter command line is a
# side benefit.
#
# WHICH COPY IT READS  (resolution order, first match wins)
#   1. $FM_PROJECT_ROOT, when set - an explicit override for odd layouts.
#   2. The git repository the current directory is inside, when that
#      repository's top-level directory is named <project>. This is what makes
#      a crewmate read ITS OWN worktree rather than firstmate's primary clone:
#      a crew asking about code it is editing must never be answered from a
#      different checkout.
#   3. $FM_HOME/projects/<project> - firstmate's own clone.
# `fm-project.sh <project> path` prints the resolved directory, so the answer
# is always inspectable.
#
# WHAT IT WRITES
# Read-only toward project CONTENT: it never edits, stages, commits, or moves a
# tracked file. It does maintain two local-only artifacts, which is the captain's
# standing instruction of 2026-08-26 ("codegraph is initialized per project by
# default; init it when missing"):
#   - .codegraph/          the index itself, created by `codegraph init`
#   - .git/info/exclude    one `.codegraph/` line, so the index never shows up
#                          as an uncommitted change and never makes fleet sync
#                          report the clone as stuck
# Neither is a tracked file and neither reaches a commit.
#
# VERBS
#   list                       registered projects and their delivery posture
#   <p> path                   print the resolved project directory
#   <p> status                 index freshness plus git branch/dirty state
#   <p> sync                   init when missing, sync when present
#   <p> explore <query...>     relevant symbols' source + call paths
#   <p> node <name>            one symbol's source + caller/callee trail
#   <p> query <search>         symbol search
#   <p> callers <symbol>       who calls it
#   <p> callees <symbol>       what it calls
#   <p> impact <symbol>        blast radius of changing it
#   <p> affected [files...]    test files affected by changed sources
#   <p> files                  indexed file structure
#   <p> grep <pattern> [path]  text search for what the index cannot see -
#                              comments, prose, config, generated files
#   <p> read <path>            print a file with line numbers
#
# The index answers STRUCTURE questions (who calls this, what breaks if I change
# it). It does not answer text questions: comments, documentation, configuration
# keys, and string literals are not symbols. Use `grep` for those. Reaching for
# grep when the question is structural is the failure this command exists to
# make unnecessary; reaching for the index when the question is textual is the
# opposite mistake and returns a confident empty answer.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  sed -n '3,5p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  echo
  echo "Run 'fm-project.sh list' for registered projects, or read this script's header for the full verb list."
}

# Registered project names, one per line. Absent registry prints nothing rather
# than failing: a project can be resolvable on disk before it is registered.
registered_names() {
  [ -f "$REG" ] || return 0
  awk '$1=="-" && $2!="" { print $2 }' "$REG"
}

cmd_list() {
  if [ ! -f "$REG" ]; then
    echo "no registry at $REG"
    return 0
  fi
  cat "$REG"
}

# Resolve <project> to a directory per the header's resolution order.
resolve_project() {
  local name=$1 top
  if [ -n "${FM_PROJECT_ROOT:-}" ]; then
    [ -d "$FM_PROJECT_ROOT" ] || die "FM_PROJECT_ROOT is set but not a directory: $FM_PROJECT_ROOT"
    printf '%s\n' "$FM_PROJECT_ROOT"
    return 0
  fi
  # The caller's own checkout wins when it IS this project, so a crewmate is
  # answered from the code it is editing.
  if top=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$top" ]; then
    if [ "$(basename "$top")" = "$name" ]; then
      printf '%s\n' "$top"
      return 0
    fi
  fi
  if [ -d "$FM_HOME/projects/$name" ]; then
    printf '%s\n' "$FM_HOME/projects/$name"
    return 0
  fi
  die "cannot resolve project \"$name\": not the current checkout and no clone at $FM_HOME/projects/$name"
}

# Keep the index out of git's way. Local-only: .git/info/exclude is never
# committed and never alters a tracked ignore file.
ensure_index_excluded() {
  local dir=$1 gitdir ex
  gitdir=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 0
  case "$gitdir" in
    /*) ;;
    *) gitdir="$dir/$gitdir" ;;
  esac
  ex="$gitdir/info/exclude"
  mkdir -p "$gitdir/info" 2>/dev/null || return 0
  grep -qxF '.codegraph/' "$ex" 2>/dev/null && return 0
  printf '.codegraph/\n' >>"$ex" 2>/dev/null || true
}

# Bring the index up to date: init when absent, sync when present.
# Prints nothing on success so a read verb's output stays clean; on failure it
# warns loudly to stderr, because the caller is about to read a possibly stale
# answer and must not mistake it for the truth.
freshen_index() {
  local dir=$1 quiet=${2:-quiet} out rc=0
  if ! command -v codegraph >/dev/null 2>&1; then
    echo "warn: codegraph is not installed; answers below come from the raw files only" >&2
    return 1
  fi
  ensure_index_excluded "$dir"
  if [ -d "$dir/.codegraph" ]; then
    out=$(codegraph sync "$dir" 2>&1) || rc=$?
  else
    out=$(codegraph init "$dir" 2>&1) || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    echo "warn: could not refresh the index for $dir - the answer below may be STALE, and a missing result is NOT proof the code is absent" >&2
    printf '%s\n' "$out" | tail -5 >&2
    return 1
  fi
  [ "$quiet" = quiet ] || printf '%s\n' "$out"
  return 0
}

# One codegraph read verb, always against a freshened index.
run_indexed() {
  local dir=$1 verb=$2
  shift 2
  [ "$#" -ge 1 ] || die "$verb needs an argument"
  freshen_index "$dir" || true
  codegraph "$verb" "$@" -p "$dir"
}

cmd_grep() {
  local dir=$1
  shift
  [ "$#" -ge 1 ] || die "grep needs a pattern"
  local pattern=$1
  shift
  # Text search deliberately does NOT touch the index: this verb exists for the
  # questions the index cannot answer at all.
  if command -v rg >/dev/null 2>&1; then
    (cd "$dir" && rg --line-number --color never -- "$pattern" "$@")
  else
    (cd "$dir" && grep -rn --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.codegraph -- "$pattern" "${@:-.}")
  fi
}

cmd_read() {
  local dir=$1 rel=$2 target base
  base=$(cd "$dir" && pwd -P)
  target=$(cd "$dir" && cd "$(dirname "$rel")" 2>/dev/null && pwd -P)/$(basename "$rel") || die "no such path: $rel"
  case "$target" in
    "$base"/*) ;;
    *) die "refusing to read outside $base: $rel" ;;
  esac
  [ -f "$target" ] || die "not a file: $rel"
  nl -ba -w6 -s'  ' "$target"
}

cmd_status() {
  local dir=$1
  echo "path:   $dir"
  if [ -d "$dir/.git" ] || [ -f "$dir/.git" ]; then
    echo "branch: $(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    echo "dirty:  $(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ') file(s)"
  fi
  if command -v codegraph >/dev/null 2>&1; then
    freshen_index "$dir" || true
    codegraph status "$dir"
  else
    echo "index:  codegraph not installed"
  fi
}

main() {
  [ "$#" -ge 1 ] || {
    usage
    exit 2
  }
  case "$1" in
    -h | --help | help)
      usage
      exit 0
      ;;
    list)
      cmd_list
      exit 0
      ;;
  esac

  [ "$#" -ge 2 ] || {
    usage
    exit 2
  }
  local name=$1 verb=$2 dir
  shift 2
  dir=$(resolve_project "$name")

  case "$verb" in
    path) printf '%s\n' "$dir" ;;
    status) cmd_status "$dir" ;;
    sync) freshen_index "$dir" loud ;;
    explore | node | query | callers | callees | impact) run_indexed "$dir" "$verb" "$@" ;;
    files)
      freshen_index "$dir" || true
      codegraph files -p "$dir" "$@"
      ;;
    affected)
      freshen_index "$dir" || true
      codegraph affected -p "$dir" "$@"
      ;;
    grep) cmd_grep "$dir" "$@" ;;
    read)
      [ "$#" -ge 1 ] || die "read needs a path"
      cmd_read "$dir" "$1"
      ;;
    *) die "unknown verb \"$verb\"; read this script's header for the verb list" ;;
  esac
}

main "$@"
