#!/usr/bin/env bash
# tests/fm-project.test.sh - the read-only project door's resolution and freshness contract.
#
# The reason this script exists at all is a silent failure: a CodeGraph index does
# not follow the working tree, and a stale index answers a real symbol with "No
# results found" while `codegraph status` reports nothing pending. An empty answer
# reads as "that code does not exist", which is how an incomplete sweep gets
# written. So the guarantee under test is not "the command runs" but "a read verb
# refreshes the index before it answers, and says so out loud when it cannot".
#
# The codegraph binary is stubbed here on purpose: these assertions are about
# fm-project.sh's own ordering, resolution, and refusal behavior, which must hold
# on any machine whether or not codegraph is installed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-project.sh"
TMP_ROOT=$(fm_test_tmproot fm-project)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects"
cat > "$HOME_DIR/data/projects.md" <<'MD'
- alpha [direct-PR] - GitHub example/alpha a registered project (added 2026-08-26)
- beta [local-only] - GitHub example/beta another one (added 2026-08-26)
MD

fm_git_init_commit "$HOME_DIR/projects/alpha"
mkdir -p "$HOME_DIR/projects/alpha/src"
printf 'export function alphaSymbol() {}\n' > "$HOME_DIR/projects/alpha/src/thing.ts"

# A codegraph stub that records every invocation in order. Recording the ORDER is
# the point: an answer served before its refresh is exactly the stale-answer bug.
CALLS="$TMP_ROOT/codegraph-calls"
: > "$CALLS"
cat > "$FAKEBIN/codegraph" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$CALLS'
case "\$1" in
  init) mkdir -p "\$2/.codegraph" ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/codegraph"

run() {
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$SCRIPT" "$@"
}

# --- resolution -------------------------------------------------------------

got=$(run alpha path) || fail "path verb failed for a registered project"
[ "$got" = "$HOME_DIR/projects/alpha" ] \
  || fail "expected the home clone, got: $got"
pass "a registered project resolves to firstmate's own clone"

# A crewmate edits an isolated worktree, not firstmate's clone. Answering it from
# the wrong checkout would describe code it is not looking at, so the caller's own
# repository wins whenever it IS that project.
OWN="$TMP_ROOT/elsewhere/alpha"
fm_git_init_commit "$OWN"
got=$(cd "$OWN" && PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$SCRIPT" alpha path) \
  || fail "path verb failed from inside a same-named checkout"
[ "$got" = "$(cd "$OWN" && pwd -P)" ] \
  || fail "the caller's own checkout did not win; got: $got"
pass "a caller inside its own copy of the project is answered from that copy"

# A differently-named checkout must not capture the lookup.
OTHER="$TMP_ROOT/elsewhere/unrelated"
fm_git_init_commit "$OTHER"
got=$(cd "$OTHER" && PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$SCRIPT" alpha path) \
  || fail "path verb failed from an unrelated checkout"
[ "$got" = "$HOME_DIR/projects/alpha" ] \
  || fail "an unrelated checkout captured the lookup; got: $got"
pass "an unrelated checkout does not capture the lookup"

run nosuch path >/dev/null 2>&1 \
  && fail "an unresolvable project was accepted instead of refused"
pass "an unresolvable project is refused rather than guessed"

# --- freshness: the whole reason this command exists -------------------------

: > "$CALLS"
run alpha query alphaSymbol >/dev/null 2>&1 \
  || fail "query verb failed"
first=$(head -1 "$CALLS")
case "$first" in
  sync* | init*) ;;
  *) fail "the index was read before it was refreshed; first call was: $first" ;;
esac
grep -q '^query alphaSymbol' "$CALLS" \
  || fail "the query itself never reached codegraph"
pass "a read verb refreshes the index before it answers"

for verb in explore node callers callees impact; do
  : > "$CALLS"
  run alpha "$verb" alphaSymbol >/dev/null 2>&1 || fail "$verb verb failed"
  case "$(head -1 "$CALLS")" in
    sync* | init*) ;;
    *) fail "$verb answered from an unrefreshed index" ;;
  esac
done
pass "every structural read verb refreshes first"

# A project with no index yet must be initialized, not silently answered empty.
# This is the captain's standing default of 2026-08-26.
fm_git_init_commit "$HOME_DIR/projects/beta"
: > "$CALLS"
run beta query anything >/dev/null 2>&1 || fail "query failed on an unindexed project"
case "$(head -1 "$CALLS")" in
  init*) ;;
  *) fail "a project with no index was not initialized; first call was: $(head -1 "$CALLS")" ;;
esac
pass "a project with no index is initialized rather than answered empty"

# ...and the second call syncs, because the index now exists.
: > "$CALLS"
run beta query anything >/dev/null 2>&1 || fail "second query failed"
case "$(head -1 "$CALLS")" in
  sync*) ;;
  *) fail "an existing index was re-initialized instead of synced" ;;
esac
pass "an existing index is synced, not rebuilt"

# --- a failed refresh must be loud ------------------------------------------
#
# Serving a possibly-stale answer in silence is the exact failure mode this
# command was built to remove, so a refusal to refresh has to reach the caller.
cat > "$FAKEBIN/codegraph" <<'SH'
#!/usr/bin/env bash
case "$1" in
  sync|init) echo "index locked" >&2; exit 1 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/codegraph"
err=$(run alpha query alphaSymbol 2>&1 >/dev/null || true)
case "$err" in
  *STALE*) ;;
  *) fail "a failed refresh did not warn that the answer may be stale; got: $err" ;;
esac
pass "a failed refresh warns loudly instead of serving a silent answer"

# --- the index must never dirty the clone -----------------------------------
#
# An untracked .codegraph/ makes fleet sync report the clone as stuck and puts a
# directory nobody asked for into every status listing.
dirty=$(git -C "$HOME_DIR/projects/beta" status --porcelain | grep -c codegraph || true)
[ "$dirty" = 0 ] \
  || fail "the index showed up as an uncommitted change in the clone"
git -C "$HOME_DIR/projects/beta" check-ignore -q .codegraph \
  || fail "the index was not excluded locally, so it will dirty the clone"
pass "the index is excluded locally and never dirties the clone"

# --- text search stays out of the index -------------------------------------
#
# Comments, prose, and configuration are not symbols. The index answers those
# with a confident nothing, so this verb must read the files directly.
printf '// a comment mentioning wireProtocolNote\n' >> "$HOME_DIR/projects/alpha/src/thing.ts"
: > "$CALLS"
out=$(run alpha grep wireProtocolNote 2>/dev/null || true)
case "$out" in
  *wireProtocolNote*) ;;
  *) fail "grep did not find text that exists in the tree" ;;
esac
pass "text search reads the files, not the index"

# --- reading a file stays inside the project --------------------------------

run alpha read ../../../etc/passwd >/dev/null 2>&1 \
  && fail "a path escaping the project was read"
pass "a path escaping the project is refused"

out=$(run alpha read src/thing.ts 2>/dev/null) || fail "read verb failed"
case "$out" in
  *alphaSymbol*) ;;
  *) fail "read did not return the file body" ;;
esac
pass "a file inside the project is read with line numbers"

# --- listing -----------------------------------------------------------------

out=$(run list 2>/dev/null) || fail "list verb failed"
case "$out" in
  *alpha*beta*) ;;
  *) fail "list did not show the registered projects" ;;
esac
pass "list shows the registered projects"
