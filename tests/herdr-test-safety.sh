#!/usr/bin/env bash
# Compatibility source for real-Herdr tests.
# The production owner of the isolation, refuse-default, teardown, and
# fleet-state tripwire contract is bin/fm-herdr-lab.sh.
set -u

# Herdr backend tests drive the real fm-spawn/fm-teardown but do not source
# tests/lib.sh, so exempt them from the gate-lifecycle refusal here too (see
# tests/lib.sh and bin/fm-gate-refuse-lib.sh for why firstmate's own suite,
# which the no-mistakes gate runs from a gate worktree, must be exempt).
export FM_GATE_REFUSE_BYPASS=1

# Same reasoning covers the codegraph spawn gate (bin/fm-codegraph-sync-lib.sh,
# captain override 2026-08-09): fm-spawn.sh refuses a ship/scout spawn when
# `codegraph` is not on PATH, and these suites drive the real fm-spawn.sh
# without sourcing tests/lib.sh's shared stub. Drop an equivalent stub here,
# prepended to PATH before any test below extends the ambient PATH, so every
# real fm-spawn.sh invocation in this family resolves `codegraph` too. Not
# registered for trap-based cleanup: every caller of this file installs its
# own `trap cleanup_all EXIT`, which would clobber one set here.
HERDR_TEST_CODEGRAPH_STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-codegraph-stub.XXXXXX")/fakebin
mkdir -p "$HERDR_TEST_CODEGRAPH_STUB_DIR"
cat > "$HERDR_TEST_CODEGRAPH_STUB_DIR/codegraph" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$HERDR_TEST_CODEGRAPH_STUB_DIR/codegraph"
PATH="$HERDR_TEST_CODEGRAPH_STUB_DIR:$PATH"
export PATH

HERDR_TEST_SAFETY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh"

# herdr_forget_inherited_pane: drop the Herdr PANE identity this test process
# inherited from whatever terminal it was started in.
#
# Herdr injects HERDR_ENV, HERDR_PANE_ID, HERDR_TAB_ID, HERDR_WORKSPACE_ID,
# HERDR_SOCKET_PATH, and HERDR_SESSION into every process it manages a pane for
# (verified 0.7.5 - docs/verification/runtime-backends.md), and a test run from
# inside a Herdr pane inherits all of them. Spawn now treats that pane as the
# authoritative parent to place workers next to, so a leaked identity from the
# developer's own session would follow the test into its isolated lab session
# and be refused there as a cross-session parent - a result that depends on
# where the suite was launched from, not on what it asserts.
#
# Call this before exporting the lab HERDR_SESSION in any suite whose subject is
# the per-home container path. A suite that means to exercise a launcher-bound
# spawn sets HERDR_PANE_ID itself, to a pane it created in its own lab session.
herdr_forget_inherited_pane() {
  unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
}

herdr_refuse_if_default() { # <session>
  fm_herdr_lab_refuse_if_default "$1"
}

herdr_safe_stop_and_delete() { # <session>
  fm_herdr_lab_teardown "$1"
}
