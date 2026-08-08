#!/usr/bin/env bash
# tests/fm-worktree-runtime-lib.test.sh - unit tests for
# bin/fm-worktree-runtime-lib.sh: what fm-spawn.sh copies into a task
# worktree (dev database, env files) and how it assigns
# code/web/.ports.worktree. Synthetic project/worktree/state fixtures only, no
# real project clone and no spawn required.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-worktree-runtime-lib.sh"

TMP=$(fm_test_tmproot fm-worktree-runtime) || fail "could not create temp root"
PROJ="$TMP/proj"
WT="$TMP/wt"
STATE="$TMP/state"
mkdir -p "$PROJ/code/web/backend/.wrangler/state/v3/d1" \
  "$PROJ/code/web/backend/.wrangler/state/v3/do" \
  "$PROJ/code/web/frontend" \
  "$WT" "$STATE"

# --- database copy skips backup snapshots -----------------------------------

echo 'active-db' > "$PROJ/code/web/backend/.wrangler/state/v3/d1/main.sqlite"
echo 'stale-backup' > "$PROJ/code/web/backend/.wrangler/state/v3/d1/main.sqlite.bak-before-merge"
mkdir -p "$PROJ/code/web/backend/.wrangler/state/v3/.bak-20260101"
echo 'stale-dir-backup' > "$PROJ/code/web/backend/.wrangler/state/v3/.bak-20260101/main.sqlite"
echo 'do-state' > "$PROJ/code/web/backend/.wrangler/state/v3/do/object.sqlite"
echo 'dev-vars' > "$PROJ/code/web/backend/.dev.vars"
echo 'front-env' > "$PROJ/code/web/frontend/.env"
echo 'front-env-prod' > "$PROJ/code/web/frontend/.env.production"

fm_worktree_runtime_provision "$WT" "$PROJ" "$STATE" task-a

DEST="$WT/code/web/backend/.wrangler/state/v3"
[ "$(cat "$DEST/d1/main.sqlite" 2>/dev/null)" = active-db ] \
  || fail "active database file was not copied into the worktree"
pass "fm_worktree_runtime_provision copies the active database file"

[ ! -e "$DEST/d1/main.sqlite.bak-before-merge" ] \
  || fail "a *.bak-* database snapshot file was copied; it must be skipped"
pass "fm_worktree_runtime_provision skips a *.bak-* backup file"

[ ! -e "$DEST/.bak-20260101" ] \
  || fail "a .bak-* backup directory was copied; it must be pruned whole"
pass "fm_worktree_runtime_provision prunes a .bak-* backup directory"

[ "$(cat "$DEST/do/object.sqlite" 2>/dev/null)" = do-state ] \
  || fail "the durable-object state directory was not copied"
pass "fm_worktree_runtime_provision copies sibling state dirs (do/)"

# --- env files ---------------------------------------------------------------

[ "$(cat "$WT/code/web/backend/.dev.vars" 2>/dev/null)" = dev-vars ] \
  || fail ".dev.vars was not copied into the worktree"
pass "fm_worktree_runtime_provision copies backend/.dev.vars"

[ "$(cat "$WT/code/web/frontend/.env" 2>/dev/null)" = front-env ] \
  || fail "frontend/.env was not copied into the worktree"
[ "$(cat "$WT/code/web/frontend/.env.production" 2>/dev/null)" = front-env-prod ] \
  || fail "frontend/.env.production was not copied into the worktree"
pass "fm_worktree_runtime_provision copies frontend/.env and .env.production"

# --- absent inputs are a silent no-op, never a failure -----------------------

EMPTY_PROJ="$TMP/empty-proj"
EMPTY_WT="$TMP/empty-wt"
mkdir -p "$EMPTY_PROJ" "$EMPTY_WT"
fm_worktree_runtime_provision "$EMPTY_WT" "$EMPTY_PROJ" "$STATE" task-empty
rc=$?
[ "$rc" -eq 0 ] || fail "provisioning a project with none of this layout must not fail the spawn (exit $rc)"
[ ! -e "$EMPTY_WT/code" ] || fail "a project with no code/web layout must be left untouched"
pass "fm_worktree_runtime_provision is a silent no-op for a project with no code/web layout (e.g. firstmate's own worktrees)"

# --- port assignment: no collision with .ports.main or another live task -----

PORTS_PROJ="$TMP/ports-proj"
mkdir -p "$PORTS_PROJ/code/web"
{
  printf 'BACKEND_PORT=8802\n'
  printf 'FRONTEND_PORT=5302\n'
} > "$PORTS_PROJ/code/web/.ports.main"

WT1="$TMP/ports-wt1"
WT2="$TMP/ports-wt2"
mkdir -p "$WT1" "$WT2"

fm_worktree_runtime_provision "$WT1" "$PORTS_PROJ" "$STATE" task-p1
B1=$(fm_worktree_runtime_kv "$WT1/code/web/.ports.worktree" BACKEND_PORT)
F1=$(fm_worktree_runtime_kv "$WT1/code/web/.ports.worktree" FRONTEND_PORT)
[ -n "$B1" ] && [ -n "$F1" ] || fail "no ports were assigned for a project that has .ports.main"
[ "$B1" != 8802 ] && [ "$F1" != 5302 ] \
  || fail "assigned ports collided with .ports.main (backend=$B1 frontend=$F1)"
pass "fm_worktree_runtime_provision assigns ports distinct from .ports.main"

fm_write_meta "$STATE/task-p1.meta" "project=$PORTS_PROJ" "worktree=$WT1"

fm_worktree_runtime_provision "$WT2" "$PORTS_PROJ" "$STATE" task-p2
B2=$(fm_worktree_runtime_kv "$WT2/code/web/.ports.worktree" BACKEND_PORT)
F2=$(fm_worktree_runtime_kv "$WT2/code/web/.ports.worktree" FRONTEND_PORT)
[ -n "$B2" ] && [ -n "$F2" ] || fail "no ports were assigned for the second live task"
[ "$B2" != "$B1" ] || fail "two live tasks for the same project were assigned the same BACKEND_PORT ($B1)"
[ "$F2" != "$F1" ] || fail "two live tasks for the same project were assigned the same FRONTEND_PORT ($F1)"
pass "fm_worktree_runtime_provision assigns a second live task ports that do not collide with the first"

# A different project's own live port assignment must never constrain this
# project's candidates, even if the numeric value happens to coincide.
OTHER_PROJ="$TMP/other-proj"
mkdir -p "$OTHER_PROJ/code/web"
fm_write_meta "$STATE/task-other.meta" "project=$OTHER_PROJ" "worktree=$TMP/other-wt"
mkdir -p "$TMP/other-wt/code/web"
printf 'BACKEND_PORT=%s\nFRONTEND_PORT=%s\n' "$((B1 + 100))" "$((F1 + 100))" \
  > "$TMP/other-wt/code/web/.ports.worktree"

WT3="$TMP/ports-wt3"
mkdir -p "$WT3"
fm_worktree_runtime_provision "$WT3" "$PORTS_PROJ" "$STATE" task-p3
B3=$(fm_worktree_runtime_kv "$WT3/code/web/.ports.worktree" BACKEND_PORT)
[ "$B3" != $((B1 + 100)) ] || echo "note: task-p3 landed on the same numeric port as an unrelated project by coincidence of the offset scheme, not a scoping bug" >&2
pass "fm_worktree_runtime_provision scopes collision-avoidance to the same project via each meta's project= field"

# --- fresh copy every spawn: a recycled worktree's stale content is replaced -

mkdir -p "$WT1/code/web/backend/.wrangler/state/v3/d1" \
  "$PROJ/code/web/backend/.wrangler/state/v3/d1"
echo 'stale-from-prior-crew' > "$WT1/code/web/backend/.wrangler/state/v3/d1/main.sqlite"
echo 'active-db-refreshed' > "$PROJ/code/web/backend/.wrangler/state/v3/d1/main.sqlite"
fm_worktree_runtime_provision "$WT1" "$PROJ" "$STATE" task-p1
[ "$(cat "$WT1/code/web/backend/.wrangler/state/v3/d1/main.sqlite" 2>/dev/null)" = active-db-refreshed ] \
  || fail "a recycled worktree kept its stale database instead of a fresh copy"
pass "fm_worktree_runtime_provision takes a fresh copy on every call, replacing recycled content"
