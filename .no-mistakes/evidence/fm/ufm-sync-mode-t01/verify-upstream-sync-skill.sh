#!/usr/bin/env bash
# Focused acceptance-criteria verification for the updatefirstmate upstream-sync
# skill change. The SKILL.md file IS the delivered interface: the agent harness
# loads this exact text as the skill's trigger description and procedure body.
set -u
ROOT="${1:?usage: verify-upstream-sync-skill.sh <repo-root>}"
FILE="$ROOT/.agents/skills/updatefirstmate/SKILL.md"
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "PASS: $1"; }
bad()  { fail=$((fail+1)); echo "FAIL: $1"; }
has()  { if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }

python3 - "$FILE" <<'PY' && ok "frontmatter parses as valid YAML with name updatefirstmate" || bad "frontmatter YAML"
import re, sys, yaml
text = open(sys.argv[1]).read()
m = re.match(r'^---\n(.*?)\n---\n', text, re.S)
data = yaml.safe_load(m.group(1))
assert data['name'] == 'updatefirstmate'
desc = data['description']
assert 'pull-only upstream sync' in desc
assert '`kunchenguid/firstmate`' in desc
assert '"sync upstream"' in desc
assert 'bring in upstream commits' in desc
PY

has "$FILE" '## Upstream sync (kunchenguid/firstmate -> pruge/firstmate)' "new section has exact required title"

python3 - "$FILE" <<'PY' && ok "new section placed before ## Safety" || bad "section placement before ## Safety"
import re, sys
text = open(sys.argv[1]).read()
assert text.index('## Upstream sync (kunchenguid/firstmate -> pruge/firstmate)') < text.index('\n## Safety\n')
PY

# Nine numbered procedure steps inside the new section.
python3 - "$FILE" <<'PY' && ok "new section contains exactly nine numbered procedure steps" || bad "nine numbered steps"
import re, sys
text = open(sys.argv[1]).read()
sec = text.split('## Upstream sync (kunchenguid/firstmate -> pruge/firstmate)')[1].split('\n## Safety')[0]
steps = re.findall(r'^(\d+)\. \*\*', sec, re.M)
assert [int(n) for n in steps] == list(range(1, 10)), steps
PY

has "$FILE" 'git remote add upstream https://github.com/kunchenguid/firstmate.git' "step 2: upstream remote add command"
has "$FILE" 'git fetch upstream main'                                              "step 2: fetch upstream main"
has "$FILE" 'git rev-list --left-right --count main...upstream/main'              "step 3: divergence quantification command"
has "$FILE" 'git switch -c sync/upstream-<YYYY-MM-DD>'                            "step 4: dated sync branch command"
has "$FILE" 'git merge upstream/main'                                             "step 5: merge upstream/main"
has "$FILE" 'UNION policy'                                                        "step 5: UNION conflict policy named"
has "$FILE" 'planning-family skills'                                              "step 5: keeps planning-family skills"
has "$FILE" 'documentation-audiences entries'                                     "step 5: keeps documentation-audiences entries"
has "$FILE" 'Never delete downstream-only files.'                                 "step 5: never delete downstream-only files"
has "$FILE" 'prefer upstream unless doing so erases a planning-family reference'  "step 5: prefer-upstream carve-out"
has "$FILE" 'bin/fm-lint.sh'                                                      "step 6: local lint validation"
has "$FILE" 'bin/fm-test-run.sh'                                                  "step 6: local full test validation"
has "$FILE" 'git push no-mistakes sync/upstream-<date>'                           "step 7: push through the gate only"
has "$FILE" 'merge commit'                                                        "step 8: merge-commit authority"
has "$FILE" 'never squash'                                                        "step 8: squash forbidden"
has "$FILE" 'orphan upstream ancestry and break future syncs'                     "step 8: squash rationale recorded"
has "$FILE" 'bin/fm-update.sh'                                                    "step 9: post-landing refresh flow"
has "$FILE" 're-reads `AGENTS.md` when told, and nudges secondmates'              "step 9: refresh outcomes stated"

has "$FILE" '**Upstream sync is pull-only.**'                       "Safety: pull-only line present"
has "$FILE" 'Nothing is ever pushed to `kunchenguid/firstmate`'     "Safety: nothing pushed to upstream"

echo
echo "result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
