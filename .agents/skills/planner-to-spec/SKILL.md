---
name: planner-to-spec
description: >-
  Authoring procedure for a feature-authoring secondmate turning a captain conversation into a feature spec.
  Load it before creating or substantially revising a spec document, and before deciding that an existing spec can receive a handed-off requirement.
  Forked from the captain-only mattpocock to-spec skill and adapted for an agent that already talks with the captain directly.
user-invocable: false
metadata:
  internal: true
---

# planner-to-spec

## When to use this

Load this before writing or substantially revising a feature spec.

Do not load it for a one-off answer, an investigation report, or a ticket set.
Tickets have their own skill, `planner-to-tickets`, and it runs after this one.

## Provenance, and what this fork changed

This is a fork of the `to-spec` skill in the mattpocock-skills plugin.
That skill is deliberately captain-only: it carries `disable-model-invocation: true` because it pauses for a human, so an agent that invokes it stalls there.
This fork exists so the same craft is available to a secondmate whose entire working mode is already a conversation with the captain.

| Upstream | Here | Why the delta |
| --- | --- | --- |
| Locked to the human | Model-invocable | This secondmate's window is the captain conversation, so there is nothing to stall on. |
| "Do NOT interview the user" | Synthesize the conversation, then escalate what it did not close | Upstream assumes the interview already happened somewhere else. Here it happens in this window, and a product decision nobody has made must reach the captain rather than be invented. |
| No fact-refresh step | Refresh the working copy and its index first | The spec cites files, symbols, and line numbers. A stale copy makes those citations silently wrong, and a reader has no way to detect it. |
| Long user-story list | Dropped | It duplicates what the problem statement and the ticket table already carry, in a form that rots faster. |
| Publishes to an issue tracker | Lands in the project's own docs tree | The spec lives beside the code it describes and leaves through the project's selected delivery path. |
| No invariants section | Invariants are required | A spec that does not name the invariants it depends on lets a later ticket break one without anyone noticing. |

Re-read upstream before assuming a rule here is still current.
When upstream changes, decide the delta again rather than diverging quietly.

## 1. Refresh the facts before writing anything

Bring the working copy and its index to the current default branch, then explore from the index rather than from grep where the project has one.
Where a project has no index, or its language is unsupported, read the code directly and say so.

A spec stands on what the code actually is today.
Anything asserted but not verified must be marked as unverified inside the document itself, not silently smoothed over.
When a fact matters and cannot be checked, ask for it rather than assuming it.

## 2. Close what can be closed; escalate what cannot

Close every product decision the conversation can close, and record the closed answer in the spec so no implementer has to bounce it back to a human.

A decision nobody has made yet is not yours to invent.
Mark it in the document as open, name who owns it, and raise it.
An invented answer is worse than an open question, because an open question is visible and an invented one is not.

Where the spec rests on a decision the captain stated, quote it verbatim in the document.
Paraphrase drifts, and the paraphrase is what later readers inherit.

## 3. Pin the seams

Decide at authoring time what gets tested and at what level.
Prefer existing seams to new ones, and prefer the highest seam that still proves the behaviour.
Fewer seams across a codebase is better.

An empty test plan means the implementer tests wherever is convenient, which is how a spec ends up verified in a place that does not fail when the behaviour breaks.

When the code a ticket will change has no covering test today, say so in the spec.
That absence is a fact about the work, and the ticket that first covers it should know it is the first.

## 4. Name what is out of scope

State exclusions explicitly.
An unstated exclusion resurfaces in every review until someone writes it down.

Where the spec pushes work outside its own scope onto another feature, section 6 governs; a note is not a handoff.

## 5. Structure

Use the project's own document language and its established section names.
The roles below are what a spec must carry; the exact headings are a project convention, not this skill's to fix.

- **Status** — where the initiative stands, dated, including which parts already landed.
- **Why this document exists** — only when that needs explaining, such as a spec rewritten after its predecessor was purged. Skip it otherwise.
- **Captain decisions** — verbatim, when the spec rests on one.
- **Problem statement** — the problem from the user's perspective, not the implementation's.
- **What already stands** — a table of code-verified facts with the date they were verified. This is the anti-hallucination device; it is the section a later reader checks first.
- **Tickets** — the ticket table with each ticket's blocking state. `planner-to-tickets` owns the tickets themselves.
- **Open questions** — decisions left to the captain, marked as such.
- **Invariants** — the properties the feature must preserve, each named so a ticket can cite it.
- **Out of scope**.
- **Verification status** — what is covered by tests today, what is not, and which ticket closes each gap. This is where the pinned seams from section 3 are recorded.

Avoid file paths and code snippets that will rot.
The exception is a snippet that encodes a decision more precisely than prose can, such as a type shape, a schema, or a state machine; inline only the decision-rich part.

Line-and-symbol citations are the deliberate exception to that rule: they are how a reader verifies the facts table.
They do rot, so re-check every one against the current default branch immediately before handing the document over.

## 6. A handoff is not real until the receiving side has a ticket number

When a spec pushes work outside its own scope to another feature, that work must become an actual ticket inside the receiving feature's own spec and ticket set.

Recording it only as an "impact" or "downstream" note on the sending side, and treating that as done, lets the work fall between two features.
This failure is not hypothetical here: one feature handed a state-enforcement requirement to another, the requirement never appeared in the receiving feature's tickets, and as drafted an operator stopping a worker would have left that worker's app still showing as running.
A second instance followed the same shape, where a permission finding was recorded as "owned by a later checkpoint" while that checkpoint had no ticket set at all.

Make it a completion check: for every item handed off, you must be able to name the receiving feature's ticket number that carries it.
If the receiving feature has no place to put it, creating that place is part of this work.

When the receiving ticket is blocked and the handed-off item is not, do not merge them to keep them together.
Merging traps the shippable half behind the blocked one.
Bind them with an explicit ordering requirement instead, and state which direction is dangerous.

## 7. Retired surfaces

A workflow, document surface, or skill the captain has retired may still exist on the machine and in the repository, so it will be reached for naturally unless excluded.
The authoritative list is the propagated captain-preferences file in this home; read it and recheck it rather than trusting any list written once.

Do not update, cite, or revive a retired surface.
When a spec would otherwise touch one, say that it is retired and route around it.

## 8. Where the document lands

Specs land in the project's own documentation tree, never as an ad-hoc file in this home.

Hard rule 1 in `AGENTS.md` section 1 governs project writes unchanged, and nothing here relaxes it.
The document leaves through the project's selected delivery path, and it goes only after the captain approves it.

## Completion checks

Do not hand a spec over until all of these hold.

- [ ] The working copy and index were refreshed before the facts were read, and every citation was re-checked against the current default branch.
- [ ] Anything unverified is marked as unverified inside the document.
- [ ] Every product decision the conversation could close is closed and recorded; every one it could not is marked open with its owner named.
- [ ] Captain decisions the spec rests on are quoted verbatim.
- [ ] The test seams are pinned, and coverage gaps are named with the ticket that closes each.
- [ ] Out of scope is explicit.
- [ ] Every handoff can name the receiving feature's ticket number.
- [ ] No retired surface is updated or cited.
