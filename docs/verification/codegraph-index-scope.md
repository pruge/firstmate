# CodeGraph index scope

Audience: maintainer verification.

This record supports the CodeGraph guidance in `bin/fm-brief.sh`'s `CODEGRAPH_SECTION` and the automated indexing behavior in `bin/fm-codegraph-sync-lib.sh` (documented in `docs/architecture.md`).
It records the measured basis for defaulting to one index per repository instead of pre-splitting by subtree.
Task chronology and the full question-by-question results stay in the private task report; this file distills only the facts the default rests on.

## Measurement

Verified 2026-08-09 against CodeGraph 1.5.0, on `jinwooauto` (2,003 files, 31,815 nodes, 79,485 edges, whole-tree build 7.67s, commit `aa47961ab83bc7faaf12b3a5f01c38112c6cf98d`).

Seven questions were run against a whole-tree index and against indexes split at two granularities (by top-level subtree, and further by package within one subtree):

- Every exact-symbol-name query resolved the right symbol at rank 1 regardless of index size, across a 140x range (224 to 31,815 nodes). No case of one subtree's symbols outranking another's turned up.
- Splitting further than the top-level subtree boundary - by package - broke real cross-package questions: a definition-and-consumer question answered completely from the subtree-level index but returned nothing relevant, or dropped a real consuming file out of the top results, when scoped to a single package.
- The whole-tree index's one measured advantage was surfacing a concept mirrored across two languages (TypeScript and Kotlin) in a single query; a split index only ever showed its own side, with no signal a mirror existed.
- Build time and disk cost were a wash between one whole-tree index and the sum of several split indexes; the real added cost of splitting is operational, since every edit needs a sync in each index that covers it, and nothing warns when one is skipped.

## What this does and does not establish

The default is one index, init'd at the repository root only when a repository holds no index anywhere.
Splitting is not justified by "avoiding symbol competition" - that mechanism did not occur once across the measured shapes.
This measurement covers exactly one repository.
It does not establish that a much larger repository never benefits from splitting - re-measure before reintroducing subtree-scoped init if one appears, rather than trusting this record past its scope or asserting the opposite unqualified claim ("competition never happens") from it.

## Regression coverage

`tests/fm-brief.test.sh` pins that `CODEGRAPH_SECTION` inits only at the repository root when no index exists anywhere, and that it no longer claims splitting avoids symbol competition.
