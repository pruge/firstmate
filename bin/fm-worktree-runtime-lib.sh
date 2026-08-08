# shellcheck shell=bash
# Best-effort provisioning of a task worktree's runtime needs (AGENTS.md
# section 7's "actually run the app" gap): a dev port pair, a private copy of
# the project's local dev database, and the gitignored dev env files.
#
# `git worktree` only carries tracked files, so a project that keeps its dev
# database, .dev.vars, and .env files gitignored (as jinwooauto's code/web
# does) hands a fresh crew nothing to run the app against, and its own
# scripts/ports.sh has no code/web/.ports.worktree to read. This library
# copies what the project's OWN clone under projects/<project> (never the
# captain's separately running dev checkout) actually has and skips what it
# does not, so a project with no such layout - firstmate's own worktrees
# included - is untouched.
#
# Usage: . bin/fm-worktree-runtime-lib.sh
#
# Public entry point:
#   fm_worktree_runtime_provision <worktree-root> <project-root> <state-dir> <task-id>
#     Copies code/web/backend/.wrangler/state/v3 (minus backup snapshots),
#     code/web/backend/.dev.vars, and code/web/frontend/.env[.production] from
#     the project into the worktree, then assigns and writes a fresh
#     code/web/.ports.worktree BACKEND_PORT/FRONTEND_PORT pair that collides
#     with neither code/web/.ports.main nor any other live task's assigned
#     pair for the same project. Every step is independently best-effort: a
#     missing source is skipped silently, a copy or write failure is a
#     stderr warning, and this function always returns 0 so a project with
#     none of this layout never fails a spawn.
#
# Data flows one way only: this always copies FROM the project's clone INTO
# the worktree. Nothing here ever writes back into the project, so nothing a
# crew does to its copy can dirty the next crew's starting point; teardown
# discarding the worktree is what discards that copy. A fresh copy is taken
# on every call, overwriting whatever a recycled worktree still holds.
#
# The web root is fixed at "code/web" because that is jinwooauto's actual
# layout, not a general contract: nothing here claims other projects share
# it, and the existence checks below are what keep a project without this
# layout a no-op rather than a spawn failure.
FM_WORKTREE_RUNTIME_WEB_REL="code/web"

# Echo <file>'s last "<key>=<value>" line with surrounding whitespace
# stripped, or nothing when absent/empty. Used for both state/<id>.meta
# fields and the project's own KEY=value port files.
fm_worktree_runtime_kv() {  # <file> <key>
  local file=$1 key=$2
  [ -f "$file" ] || return 0
  grep "^${key}=" "$file" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '[:space:]'
}

# Echo <file>'s <key> value only when it is present and a positive integer;
# otherwise echo nothing. Ports are the only KEY=value pairs this library
# trusts from either the project's own files or a sibling task's meta, so
# every read of one goes through this guard.
fm_worktree_runtime_port() {  # <file> <key>
  local v
  v=$(fm_worktree_runtime_kv "$1" "$2")
  case "$v" in
    '' | *[!0-9]* | 0) return 0 ;;
  esac
  printf '%s' "$v"
}

# Copy code/web/backend/.wrangler/state/v3 from the project into the
# worktree, skipping any path component whose name contains "bak" (case
# insensitive): the project's own d1 snapshots are named like
# "<hash>.sqlite.bak-<label>" and accumulate to well over 100MB against an
# active database of roughly 25MB, so a "*bak*" prune - not just a literal
# leading ".bak-" match - is what actually keeps a fresh worktree copy small.
# A pruned directory is skipped whole; nothing needed to run the app is named
# this way.
fm_worktree_runtime_copy_state_v3() {  # <worktree-web> <project-web>
  local wt_web=$1 proj_web=$2 dest f rel destfile
  local src="$proj_web/backend/.wrangler/state/v3"
  [ -d "$src" ] || return 0
  dest="$wt_web/backend/.wrangler/state/v3"
  mkdir -p "$dest" || {
    echo "warning: fm-spawn: could not create $dest for wrangler state copy" >&2
    return 0
  }
  while IFS= read -r -d '' f; do
    rel=${f#"$src"/}
    destfile="$dest/$rel"
    mkdir -p "$(dirname "$destfile")" 2>/dev/null || {
      echo "warning: fm-spawn: could not create directory for $rel under $dest" >&2
      continue
    }
    cp -p "$f" "$destfile" 2>/dev/null \
      || echo "warning: fm-spawn: failed to copy wrangler state file $rel into $dest" >&2
  done < <(find "$src" -iname '*bak*' -prune -o -type f -print0 2>/dev/null)
}

# Copy the project's gitignored dev env files into the worktree, one at a
# time, skipping any that do not exist in the project.
fm_worktree_runtime_copy_env_files() {  # <worktree-web> <project-web>
  local wt_web=$1 proj_web=$2 rel
  for rel in backend/.dev.vars frontend/.env frontend/.env.production; do
    [ -f "$proj_web/$rel" ] || continue
    mkdir -p "$wt_web/$(dirname "$rel")" 2>/dev/null || {
      echo "warning: fm-spawn: could not create directory for $rel in $wt_web" >&2
      continue
    }
    cp -p "$proj_web/$rel" "$wt_web/$rel" 2>/dev/null \
      || echo "warning: fm-spawn: failed to copy $rel into $wt_web" >&2
  done
}

# Assign a BACKEND_PORT/FRONTEND_PORT pair that collides with neither
# code/web/.ports.main nor any other live task's own code/web/.ports.worktree
# for the SAME project (read via each state/<id>.meta's project= field, so an
# unrelated project's ports never constrain this one), then write
# code/web/.ports.worktree. A project with no .ports.main is not using this
# contract at all, so this is a silent no-op for it - jinwooauto's own
# scripts/ports.sh falls back to .ports.main whenever .ports.worktree is
# absent, so leaving it unwritten is always safe, never a broken state.
#
# The scan-then-write below is a critical section: two tasks for the same
# project can be spawned concurrently (fm-spawn.sh only serializes same-id
# spawns via its per-task SPAWN_TASK_LOCK), and the calling task's own
# state/<id>.meta is not written until well after this function returns, so
# an unlocked scan of *.meta could race another concurrent provision call and
# hand out the same pair to both. A per-project lock directory under
# state_dir (independent of any single task's meta) closes that window.
fm_worktree_runtime_assign_ports() {  # <worktree-root> <project-root> <state-dir> <task-id>
  local wt=$1 proj=$2 state_dir=$3 id=$4
  local wt_web="$wt/$FM_WORKTREE_RUNTIME_WEB_REL" proj_web="$proj/$FM_WORKTREE_RUNTIME_WEB_REL"
  local main_file="$proj_web/.ports.main" backend_main frontend_main
  [ -f "$main_file" ] || return 0
  backend_main=$(fm_worktree_runtime_port "$main_file" BACKEND_PORT)
  frontend_main=$(fm_worktree_runtime_port "$main_file" FRONTEND_PORT)
  if [ -z "$backend_main" ] || [ -z "$frontend_main" ]; then
    echo "warning: fm-spawn: $main_file has no usable BACKEND_PORT/FRONTEND_PORT; skipping port assignment for $id" >&2
    return 0
  fi

  local proj_key port_lock
  proj_key=$(printf '%s' "$proj" | cksum | cut -d' ' -f1)
  port_lock="$state_dir/.ports-$proj_key.lock"
  if declare -F fm_lock_acquire_wait >/dev/null 2>&1 && declare -F fm_lock_release >/dev/null 2>&1; then
    fm_lock_acquire_wait "$port_lock"
    # shellcheck disable=SC2064 # port_lock is fixed for this call; expand it now.
    trap "fm_lock_release '$port_lock' || true" RETURN
  fi

  local used_backend=" $backend_main " used_frontend=" $frontend_main "
  local meta other_proj other_wt other_ports_file ob of
  for meta in "$state_dir"/*.meta; do
    [ -f "$meta" ] || continue
    other_proj=$(fm_worktree_runtime_kv "$meta" project)
    [ "$other_proj" = "$proj" ] || continue
    other_wt=$(fm_worktree_runtime_kv "$meta" worktree)
    [ -n "$other_wt" ] && [ "$other_wt" != "$wt" ] || continue
    other_ports_file="$other_wt/$FM_WORKTREE_RUNTIME_WEB_REL/.ports.worktree"
    ob=$(fm_worktree_runtime_port "$other_ports_file" BACKEND_PORT)
    of=$(fm_worktree_runtime_port "$other_ports_file" FRONTEND_PORT)
    [ -n "$ob" ] && [ -n "$of" ] || continue
    used_backend="$used_backend$ob "
    used_frontend="$used_frontend$of "
  done

  local n=1 cand_b cand_f
  while [ "$n" -le 1000 ]; do
    cand_b=$((backend_main + n * 100))
    cand_f=$((frontend_main + n * 100))
    case "$used_backend" in *" $cand_b "*) n=$((n + 1)); continue ;; esac
    case "$used_frontend" in *" $cand_f "*) n=$((n + 1)); continue ;; esac
    break
  done
  if [ "$n" -gt 1000 ]; then
    echo "warning: fm-spawn: could not find a free port pair for $id after 1000 candidates; skipping port assignment" >&2
    return 0
  fi

  mkdir -p "$wt_web" 2>/dev/null || {
    echo "warning: fm-spawn: could not create $wt_web for port assignment" >&2
    return 0
  }
  {
    printf 'BACKEND_PORT=%s\n' "$cand_b"
    printf 'FRONTEND_PORT=%s\n' "$cand_f"
  } > "$wt_web/.ports.worktree" 2>/dev/null \
    || echo "warning: fm-spawn: failed to write $wt_web/.ports.worktree" >&2
}

# Public entry point. Always returns 0: a project with none of this layout
# (firstmate's own worktrees included) is a silent no-op, and a copy or
# write failure is a warning, never a spawn failure.
fm_worktree_runtime_provision() {  # <worktree-root> <project-root> <state-dir> <task-id>
  local wt=$1 proj=$2 state_dir=$3 id=$4
  local wt_web="$wt/$FM_WORKTREE_RUNTIME_WEB_REL" proj_web="$proj/$FM_WORKTREE_RUNTIME_WEB_REL"
  [ -d "$proj_web" ] || return 0
  fm_worktree_runtime_copy_state_v3 "$wt_web" "$proj_web"
  fm_worktree_runtime_copy_env_files "$wt_web" "$proj_web"
  fm_worktree_runtime_assign_ports "$wt" "$proj" "$state_dir" "$id"
  return 0
}
