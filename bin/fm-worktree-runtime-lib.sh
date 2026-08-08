# shellcheck shell=bash
# Provisioning of a task worktree's runtime needs (AGENTS.md section 7's
# "actually run the app" gap): an assigned dev port pair, a private copy of
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
# Firstmate is the sole port decision-maker: the BACKEND_PORT/FRONTEND_PORT
# pair arrives as explicit input, resolved by firstmate at intake exactly like
# --model/--effort/--backend (bin/fm-spawn.sh's --backend-port/--frontend-port
# flags), never picked by this library or by fm-spawn.sh itself. There is no
# scan-then-decide step here at all, so the port-collision race that a prior
# in-process "avoid every other live task's pair" scheme was exposed to (a
# sibling task's own state/<id>.meta not existing yet when this ran) is
# removed by design, not mitigated by a lock: this library only validates and
# writes the pair it is given, and refuses loudly - failing the spawn - on
# anything malformed or already bound, rather than silently choosing another.
#
# Usage: . bin/fm-worktree-runtime-lib.sh
#
# Public entry point:
#   fm_worktree_runtime_provision <worktree-root> <project-root> <backend-port> <frontend-port>
#     Copies code/web/backend/.wrangler/state/v3 (minus backup snapshots),
#     code/web/backend/.dev.vars, and code/web/frontend/.env[.production] from
#     the project into the worktree - each independently best-effort: a
#     missing source is skipped silently, a copy failure is a stderr warning,
#     never a spawn failure. The copied frontend/.env additionally gets its
#     VITE_BACKEND_URL rewritten to the given backend-port when one is given,
#     so a worktree copy never points a directly-launched vite dev server at
#     the project's main port (scripts/dev-frontend.sh already overrides this
#     at launch, so nothing is broken today without this - it just removes a
#     stale value that would otherwise sit in the file as a trap).
#     Then, when both ports are given, validates and writes them to
#     code/web/.ports.worktree; a bad or already-bound pair is the one
#     deliberate exception to best-effort here and makes this function return
#     non-zero, which the caller must treat as a spawn failure. Both ports
#     empty is a silent no-op (no ports contract for this spawn).
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
# stripped, or nothing when absent/empty. Used to read the project's own
# KEY=value port file (code/web/.ports.main).
fm_worktree_runtime_kv() {  # <file> <key>
  local file=$1 key=$2
  [ -f "$file" ] || return 0
  grep "^${key}=" "$file" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '[:space:]'
}

# Echo <file>'s <key> value only when it is present and a positive integer;
# otherwise echo nothing. Used to read code/web/.ports.main's own ports.
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

# Rewrite frontend/.env's VITE_BACKEND_URL to the worktree's own assigned
# backend port. scripts/dev-frontend.sh already exports the correct value at
# launch (an env var set at process start wins over the .env file), so this
# is not fixing a broken dev flow - but the copied file itself would
# otherwise keep the project's main-port value verbatim, and several frontend
# source files fall back to a hardcoded "http://localhost:8802" via
# `?? "http://localhost:8802"` when VITE_BACKEND_URL is unset. That fallback
# means DROPPING the line would reproduce the exact same wrong value for
# anyone who starts vite directly instead of through the launcher, so
# rewriting it to the real assigned port is the only shape that actually
# removes the trap. frontend/.env.production is never touched here: its
# VITE_BACKEND_URL points at the real deployed Workers backend, unrelated to
# any local dev port.
fm_worktree_runtime_rewrite_backend_url() {  # <env-file> <backend-port>
  local file=$1 backend_port=$2 tmp
  [ -n "$backend_port" ] || return 0
  case "$backend_port" in
    [1-9] | [1-9][0-9]*) ;;
    *) return 0 ;;
  esac
  grep -q '^VITE_BACKEND_URL=' "$file" 2>/dev/null || return 0
  tmp="$file.tmp.$$"
  if sed "s|^VITE_BACKEND_URL=.*|VITE_BACKEND_URL=http://localhost:${backend_port}|" "$file" > "$tmp" 2>/dev/null \
    && mv "$tmp" "$file" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  echo "warning: fm-spawn: failed to rewrite VITE_BACKEND_URL in $file to the assigned backend port" >&2
}

# Copy the project's gitignored dev env files into the worktree, one at a
# time, skipping any that do not exist in the project.
fm_worktree_runtime_copy_env_files() {  # <worktree-web> <project-web> <backend-port>
  local wt_web=$1 proj_web=$2 backend_port=$3 rel
  for rel in backend/.dev.vars frontend/.env frontend/.env.production; do
    [ -f "$proj_web/$rel" ] || continue
    mkdir -p "$wt_web/$(dirname "$rel")" 2>/dev/null || {
      echo "warning: fm-spawn: could not create directory for $rel in $wt_web" >&2
      continue
    }
    cp -p "$proj_web/$rel" "$wt_web/$rel" 2>/dev/null || {
      echo "warning: fm-spawn: failed to copy $rel into $wt_web" >&2
      continue
    }
    [ "$rel" = frontend/.env ] && fm_worktree_runtime_rewrite_backend_url "$wt_web/$rel" "$backend_port"
  done
}

# Return 0 iff <port> is confirmed free right now via lsof. Any uncertainty -
# lsof reporting something other than a clean "in use"/"not in use" answer, or
# lsof itself being unavailable - is treated as NOT confirmed free (fail
# closed), mirroring fm_lock_lsof_holder's convention in bin/fm-lock-lib.sh: an
# unproven answer is never treated as license to proceed.
fm_worktree_runtime_port_is_free() {  # <port>
  local port=$1 output status
  if output=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>&1); then
    return 1
  else
    status=$?
  fi
  if [ "$status" -eq 1 ] && [ -z "$output" ]; then
    return 0
  fi
  return 1
}

# Validate and write an explicit BACKEND_PORT/FRONTEND_PORT pair - chosen by
# firstmate at intake, never by this library - to code/web/.ports.worktree.
# Both empty is a silent no-op (no ports contract for this spawn). Any
# validation failure (non-integer, non-positive, equal to each other, equal to
# code/web/.ports.main's own pair, or already bound) prints a clear error and
# returns non-zero; the caller must fail the spawn rather than fall back to
# choosing a different pair.
fm_worktree_runtime_write_ports() {  # <worktree-root> <project-root> <backend-port> <frontend-port>
  local wt=$1 proj=$2 backend_port=$3 frontend_port=$4
  local wt_web="$wt/$FM_WORKTREE_RUNTIME_WEB_REL" proj_web="$proj/$FM_WORKTREE_RUNTIME_WEB_REL"

  if [ -z "$backend_port" ] && [ -z "$frontend_port" ]; then
    return 0
  fi
  if [ -z "$backend_port" ] || [ -z "$frontend_port" ]; then
    echo "error: fm-spawn: backend-port and frontend-port must both be given, or neither (got backend='$backend_port' frontend='$frontend_port')" >&2
    return 1
  fi
  case "$backend_port" in
    [1-9] | [1-9][0-9]*) ;;
    *) echo "error: fm-spawn: backend-port must be a positive integer, got '$backend_port'" >&2; return 1 ;;
  esac
  case "$frontend_port" in
    [1-9] | [1-9][0-9]*) ;;
    *) echo "error: fm-spawn: frontend-port must be a positive integer, got '$frontend_port'" >&2; return 1 ;;
  esac
  if [ "$backend_port" = "$frontend_port" ]; then
    echo "error: fm-spawn: backend-port and frontend-port must differ, both were '$backend_port'" >&2
    return 1
  fi

  local main_file="$proj_web/.ports.main" backend_main frontend_main
  if [ -f "$main_file" ]; then
    backend_main=$(fm_worktree_runtime_port "$main_file" BACKEND_PORT)
    frontend_main=$(fm_worktree_runtime_port "$main_file" FRONTEND_PORT)
    if [ -n "$backend_main" ] && [ "$backend_port" = "$backend_main" ]; then
      echo "error: fm-spawn: backend-port $backend_port collides with $main_file's own BACKEND_PORT" >&2
      return 1
    fi
    if [ -n "$frontend_main" ] && [ "$frontend_port" = "$frontend_main" ]; then
      echo "error: fm-spawn: frontend-port $frontend_port collides with $main_file's own FRONTEND_PORT" >&2
      return 1
    fi
  fi

  fm_worktree_runtime_port_is_free "$backend_port" || {
    echo "error: fm-spawn: backend-port $backend_port is not confirmed free; refusing to write $wt_web/.ports.worktree" >&2
    return 1
  }
  fm_worktree_runtime_port_is_free "$frontend_port" || {
    echo "error: fm-spawn: frontend-port $frontend_port is not confirmed free; refusing to write $wt_web/.ports.worktree" >&2
    return 1
  }

  mkdir -p "$wt_web" || {
    echo "error: fm-spawn: could not create $wt_web for port assignment" >&2
    return 1
  }
  {
    printf 'BACKEND_PORT=%s\n' "$backend_port"
    printf 'FRONTEND_PORT=%s\n' "$frontend_port"
  } > "$wt_web/.ports.worktree" || {
    echo "error: fm-spawn: failed to write $wt_web/.ports.worktree" >&2
    return 1
  }
}

# Public entry point. The copy steps are independently best-effort (a missing
# source is a silent skip, a copy failure is a stderr warning) and never fail
# this function on their own. The port-write step is the one deliberate
# exception: this function returns non-zero when it fails, and the caller
# (bin/fm-spawn.sh) must treat that as a spawn failure rather than a warning.
fm_worktree_runtime_provision() {  # <worktree-root> <project-root> <backend-port> <frontend-port>
  local wt=$1 proj=$2 backend_port=$3 frontend_port=$4
  local wt_web="$wt/$FM_WORKTREE_RUNTIME_WEB_REL" proj_web="$proj/$FM_WORKTREE_RUNTIME_WEB_REL"
  [ -d "$proj_web" ] || return 0
  fm_worktree_runtime_copy_state_v3 "$wt_web" "$proj_web"
  fm_worktree_runtime_copy_env_files "$wt_web" "$proj_web" "$backend_port"
  fm_worktree_runtime_write_ports "$wt" "$proj" "$backend_port" "$frontend_port"
}
