#!/usr/bin/env bash
# fm-node-patch-reapply.sh - re-apply firstmate's local node_modules patches to
# globally-installed pi packages after a pi / pi-claude-code-provider update
# reverts them.
#
# Usage:
#   fm-node-patch-reapply.sh [check|apply]
#   fm-node-patch-reapply.sh --help
#
# `check` (default) reports which patches are currently applied and which are
# missing, and exits non-zero if any are missing. It makes no changes.
# `apply` re-applies every missing patch (idempotent: a patch already applied
# is left untouched) and reports the result for each.
#
# Why this exists: firstmate has patched behavior straight into installed
# npm packages under node_modules (never into this repo's own tracked code,
# because these are third-party packages, not firstmate's). Every such patch
# is REVERTED whenever `pi update` or an npm reinstall replaces that package's
# files, because node_modules is not under version control. This script is
# the single place that knows every current patch, what file it touches, and
# how to detect whether it is live right now - so "pi was updated, did my
# patches survive" has one authoritative answer instead of requiring a fresh
# investigation each time.
#
# Each patch below is self-contained: a MARKER string unique to the patch
# (grepped to detect current state) and an apply step that splices a fixed
# insertion block in at a line found by anchor text, via head/tail rather
# than awk string literals, so quoting/regex characters in the inserted code
# cannot break the splicing itself. A patch that cannot find its expected
# anchor text (because the upstream file changed shape) fails loudly naming
# the patch, rather than silently doing nothing or corrupting the file.
#
# This script owns detection and application. It does not decide whether a
# patch is still needed after a pi upgrade might have fixed the underlying
# bug upstream - that judgment call belongs to whoever runs this script, and
# is exactly why `check` reports state without silently reapplying.

set -euo pipefail

SCRIPT_NAME=$(basename "$0")

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [check|apply]
       $SCRIPT_NAME --help

check   report which patches are applied / missing (default; no changes; exits
        non-zero if any patch is missing)
apply   re-apply every missing patch (idempotent)

Patches registered:
  opus-pin            pins pi-claude-code-provider's "opus" alias to a specific
                      Claude model at the argv boundary (claude-args.ts)
  edit-xml-recovery   recovers an edit tool call whose "edits" argument was
                      emitted as an XML-tag-flavored string instead of JSON
                      (pi-coding-agent dist/core/tools/edit.js)

Diffs for reference are kept at config/node-patches/*.diff (informational
only; this script does not read or apply them - each patch below is applied
by anchor-based line splicing so it stays correct even if the diff context
around it has drifted).
EOF
}

MODE="check"
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  check|apply) MODE=${1:-check} ;;
  "") MODE="check" ;;
  *) echo "$SCRIPT_NAME: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

FAIL=0

# splice_after <file> <anchor-line-exact-text> <insert-file>
# Inserts the contents of insert-file immediately after the first line in
# file that exactly matches anchor-line-exact-text. Writes to a temp file and
# returns its path on stdout; caller decides whether to move it into place.
# Fails (return 1) if the anchor is not found.
splice_after() {
  local file=$1 anchor=$2 insert_file=$3
  local line_no
  line_no=$(grep -nF -- "$anchor" "$file" | head -1 | cut -d: -f1)
  if [ -z "$line_no" ]; then
    return 1
  fi
  local tmp
  tmp=$(mktemp)
  head -n "$line_no" "$file" > "$tmp"
  cat "$insert_file" >> "$tmp"
  tail -n "+$((line_no + 1))" "$file" >> "$tmp"
  printf '%s\n' "$tmp"
}

# ---------------------------------------------------------------------------
# Patch: opus-pin
# File:  ~/.pi/agent/npm/node_modules/pi-claude-code-provider/src/claude-args.ts
# ---------------------------------------------------------------------------
OPUS_PIN_FILE="$HOME/.pi/agent/npm/node_modules/pi-claude-code-provider/src/claude-args.ts"
OPUS_PIN_MARKER='const PINNED_CLAUDE_MODELS'
OPUS_PIN_CALLSITE_OLD='...(model === "default" ? [] : ["--model", model]),'
OPUS_PIN_CALLSITE_NEW='...(model === "default" ? [] : ["--model", pinnedClaudeModel(model)]),'

check_opus_pin() {
  if [ ! -f "$OPUS_PIN_FILE" ]; then
    echo "opus-pin: MISSING FILE ($OPUS_PIN_FILE not found - is pi-claude-code-provider installed?)"
    return 1
  fi
  if grep -qF "$OPUS_PIN_MARKER" "$OPUS_PIN_FILE"; then
    echo "opus-pin: applied"
    return 0
  fi
  echo "opus-pin: NOT APPLIED"
  return 1
}

apply_opus_pin() {
  if [ ! -f "$OPUS_PIN_FILE" ]; then
    echo "opus-pin: FAILED - file not found, cannot patch: $OPUS_PIN_FILE"
    return 1
  fi
  if grep -qF "$OPUS_PIN_MARKER" "$OPUS_PIN_FILE"; then
    echo "opus-pin: already applied, no change"
    return 0
  fi
  if ! grep -qF "$OPUS_PIN_CALLSITE_OLD" "$OPUS_PIN_FILE"; then
    echo "opus-pin: FAILED - expected call-site text not found in $OPUS_PIN_FILE; upstream shape may have changed, patch by hand"
    return 1
  fi
  # Find the line "}" that closes the function immediately before
  # "export function providerArgs(" - insert the pin block right after it.
  local export_line
  export_line=$(grep -nF 'export function providerArgs(' "$OPUS_PIN_FILE" | head -1 | cut -d: -f1)
  if [ -z "$export_line" ]; then
    echo "opus-pin: FAILED - 'export function providerArgs(' not found in $OPUS_PIN_FILE; upstream shape may have changed, patch by hand"
    return 1
  fi
  local anchor_line=$((export_line - 1))
  local anchor_text
  anchor_text=$(sed -n "${anchor_line}p" "$OPUS_PIN_FILE")

  local insert
  insert=$(mktemp)
  {
    echo ''
    echo '// LOCAL PATCH (firstmate bin/fm-node-patch-reapply.sh, opus-pin).'
    echo '// The provider passes its pi-visible alias straight through as `claude --model'
    echo "// <alias>\`, and the \`opus\` alias can resolve to a newer default than the"
    echo '// captain has pinned. Pinning happens HERE, at the argv boundary, so every'
    echo "// existing \`pi-claude-code-provider/opus\` reference in firstmate config keeps"
    echo '// working unchanged.'
    echo '// REVERTS on every pi-claude-code-provider package update; re-apply with'
    echo '// bin/fm-node-patch-reapply.sh apply.'
    echo "${OPUS_PIN_MARKER}: Readonly<Record<string, string>> = Object.freeze({"
    echo '  opus: "claude-opus-4-6",'
    echo '});'
    echo ''
    echo 'function pinnedClaudeModel(model: string): string {'
    echo "  return ${OPUS_PIN_MARKER##* }[model] ?? model;"
    echo '}'
  } > "$insert"
  # ${OPUS_PIN_MARKER##* } strips down to just the identifier PINNED_CLAUDE_MODELS
  local tmp
  if ! tmp=$(splice_after "$OPUS_PIN_FILE" "$anchor_text" "$insert"); then
    rm -f "$insert"
    echo "opus-pin: FAILED - could not locate insertion point before providerArgs; patch by hand"
    return 1
  fi
  rm -f "$insert"
  local tmp2
  tmp2=$(mktemp)
  cp "$tmp" "$tmp2"
  rm -f "$tmp"
  python3 - "$tmp2" "$OPUS_PIN_CALLSITE_OLD" "$OPUS_PIN_CALLSITE_NEW" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as fh:
    content = fh.read()
content = content.replace(old, new, 1)
with open(path, "w") as fh:
    fh.write(content)
PYEOF
  if ! grep -qF "$OPUS_PIN_MARKER" "$tmp2" || ! grep -qF "$OPUS_PIN_CALLSITE_NEW" "$tmp2"; then
    rm -f "$tmp2"
    echo "opus-pin: FAILED - substitution did not take at both sites; aborting without writing"
    return 1
  fi
  mv "$tmp2" "$OPUS_PIN_FILE"
  echo "opus-pin: applied"
}

# ---------------------------------------------------------------------------
# Patch: edit-xml-recovery
# File:  ~/.nvm/versions/node/*/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/tools/edit.js
# ---------------------------------------------------------------------------
find_pi_coding_agent_edit_js() {
  local f
  for f in "$HOME"/.nvm/versions/node/*/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/tools/edit.js; do
    [ -f "$f" ] && printf '%s\n' "$f" && return 0
  done
  return 1
}

EDIT_XML_MARKER='function extractXmlStyleEdit'
EDIT_XML_ANCHOR_FN_START='function isSingleEditInput(value) {'
EDIT_XML_ANCHOR_CATCH='        catch { }'
EDIT_XML_CATCH_NEW='        catch {
            const recovered = extractXmlStyleEdit(args.edits);
            if (recovered) {
                args.edits = [recovered];
            }
        }'

check_edit_xml_recovery() {
  local f
  if ! f=$(find_pi_coding_agent_edit_js); then
    echo "edit-xml-recovery: MISSING FILE (pi-coding-agent edit.js not found under ~/.nvm)"
    return 1
  fi
  if grep -qF "$EDIT_XML_MARKER" "$f"; then
    echo "edit-xml-recovery: applied ($f)"
    return 0
  fi
  echo "edit-xml-recovery: NOT APPLIED ($f)"
  return 1
}

apply_edit_xml_recovery() {
  local f
  if ! f=$(find_pi_coding_agent_edit_js); then
    echo "edit-xml-recovery: FAILED - pi-coding-agent edit.js not found under ~/.nvm"
    return 1
  fi
  if grep -qF "$EDIT_XML_MARKER" "$f"; then
    echo "edit-xml-recovery: already applied, no change"
    return 0
  fi
  if ! grep -qF "$EDIT_XML_ANCHOR_FN_START" "$f"; then
    echo "edit-xml-recovery: FAILED - expected anchor 'isSingleEditInput' not found in $f; upstream shape may have changed, patch by hand"
    return 1
  fi
  if ! grep -qF "$EDIT_XML_ANCHOR_CATCH" "$f"; then
    echo "edit-xml-recovery: FAILED - expected 'catch { }' call site not found in $f; upstream shape may have changed, patch by hand"
    return 1
  fi
  cp "$f" "${f}.pre-patch-bak"

  # Find the closing "}" of isSingleEditInput to insert the new function after it.
  local fn_start_line close_line total
  fn_start_line=$(grep -nF "$EDIT_XML_ANCHOR_FN_START" "$f" | head -1 | cut -d: -f1)
  total=$(wc -l < "$f" | tr -d ' ')
  close_line=""
  local i=$((fn_start_line + 1))
  while [ "$i" -le "$total" ]; do
    local content
    content=$(sed -n "${i}p" "$f")
    if [ "$content" = "}" ]; then
      close_line=$i
      break
    fi
    i=$((i + 1))
  done
  if [ -z "$close_line" ]; then
    echo "edit-xml-recovery: FAILED - could not find closing brace of isSingleEditInput; patch by hand"
    return 1
  fi

  local insert
  insert=$(mktemp)
  cat > "$insert" <<'PATCHEOF'

// Firstmate patch (bin/fm-node-patch-reapply.sh, edit-xml-recovery): recovers
// a single edit that a model emitted as an XML-tag-flavored pseudo-JSON
// mash-up instead of a clean edits array, e.g.:
//   \n<parameter name="oldText">RAW_OLD_TEXT",\n   "newText": "RAW_NEW_TEXT"\n }
// Best-effort and safe: downstream validateEditInput +
// applyEditsToNormalizedContent still require an exact oldText match against
// the real file, so a wrong extraction here falls through to the same clean
// "text not found" error instead of corrupting a file.
// REVERTS on every pi-coding-agent package update; re-apply with
// bin/fm-node-patch-reapply.sh apply.
function extractXmlStyleEdit(text) {
    const m = /<parameter\s+name=["']oldText["']>([\s\S]*?)",\s*"newText"\s*:\s*"([\s\S]*?)"\s*\}?\s*$/.exec(text);
    if (!m)
        return null;
    const unescape = (s) => s.replace(/\\n/g, "\n").replace(/\\"/g, "\"").replace(/\\\\/g, "\\");
    return { oldText: unescape(m[1]), newText: unescape(m[2]) };
}
PATCHEOF

  local tmp
  tmp=$(mktemp)
  head -n "$close_line" "$f" > "$tmp"
  cat "$insert" >> "$tmp"
  tail -n "+$((close_line + 1))" "$f" >> "$tmp"
  rm -f "$insert"

  # call-site: hook into the empty catch{} inside prepareEditArguments's edits-as-string branch
  # .js suffix matters: this package.json declares "type": "module", so `node
  # --check` on an extensionless mktemp path fails with ERR_UNKNOWN_FILE_EXTENSION.
  local tmp2
  tmp2=$(mktemp).js
  if ! (line_no=$(grep -nF "$EDIT_XML_ANCHOR_CATCH" "$tmp" | head -1 | cut -d: -f1); \
        [ -n "$line_no" ] && \
        head -n "$((line_no - 1))" "$tmp" > "$tmp2" && \
        printf '%s\n' "$EDIT_XML_CATCH_NEW" >> "$tmp2" && \
        tail -n "+$((line_no + 1))" "$tmp" >> "$tmp2"); then
    rm -f "$tmp" "$tmp2"
    echo "edit-xml-recovery: FAILED - could not splice catch-block call site; patch by hand"
    return 1
  fi
  rm -f "$tmp"

  local check_out
  check_out=$(node --check "$tmp2" 2>&1) || {
    cp "$tmp2" /tmp/fm-node-patch-debug.js
    rm -f "$tmp2"
    echo "edit-xml-recovery: FAILED - patched file has a syntax error, not writing (backup untouched at ${f}.pre-patch-bak, bad output saved to /tmp/fm-node-patch-debug.js): $check_out"
    return 1
  }
  if ! grep -qF "$EDIT_XML_MARKER" "$tmp2" || ! grep -qF "extractXmlStyleEdit(args.edits)" "$tmp2"; then
    rm -f "$tmp2"
    echo "edit-xml-recovery: FAILED - substitution did not take at both sites; aborting without writing"
    return 1
  fi
  mv "$tmp2" "$f"
  echo "edit-xml-recovery: applied ($f)"
}

# ---------------------------------------------------------------------------
if [ "$MODE" = "check" ]; then
  check_opus_pin || FAIL=1
  check_edit_xml_recovery || FAIL=1
  exit "$FAIL"
fi

# apply
apply_opus_pin || FAIL=1
apply_edit_xml_recovery || FAIL=1
exit "$FAIL"
