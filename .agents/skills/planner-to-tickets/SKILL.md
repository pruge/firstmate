---
name: planner-to-tickets
description: >-
  Decomposition procedure for a feature-authoring secondmate turning a spec or captain conversation into a ticket set.
  Load it before writing or substantially revising tickets, and before handing any ticket set to firstmate for dispatch.
  Forked from the captain-only mattpocock to-tickets skill; adds measured sizing, a concrete verticality test, worker-tier and captain-verification marking, and a close-out that keeps rules from re-accumulating.
user-invocable: false
metadata:
  internal: true
---

# planner-to-tickets

## When to use this

Load this before writing a ticket set, before substantially revising one, and before handing any ticket set over for dispatch.

It runs after `planner-to-spec`.
A ticket set with no spec behind it is a spec written in fragments, and its decisions end up scattered across tickets where nobody can review them together.

## Provenance, and what this fork changed

This is a fork of the `to-tickets` skill in the mattpocock-skills plugin, which is captain-only for the same reason `to-spec` is.

| Upstream | Here | Why the delta |
| --- | --- | --- |
| Locked to the human | Model-invocable | This secondmate's window is the captain conversation. |
| "Sized to fit a single fresh context window" | Sizing is measured, and the dangerous direction is over-splitting | Upstream pushes only toward smaller. Measurement on this fleet found the opposite failure is the common and expensive one. Section 3 owns this. |
| No worker-tier signal | Tickets that exceed the default worker tier are marked, with a mandatory reason | The dispatcher needs a batching input it can verify. An unexplained tier claim cannot be checked, so it becomes obedience rather than judgement. |
| No human-verification signal | Tickets needing the captain's own eyes are marked | Some changes cannot be judged correct by a test. Without a marker, they get torn down before the captain sees them. |
| Quiz the user, then publish | Quiz the captain, then publish only after captain approval | Approval is a gate here, not a formality. |
| Verticality as a rule | Verticality as a test with a named failure mode | The rule alone did not hold. Section 2 owns the test and the incident behind it. |

Re-read upstream before assuming a rule here is still current.

## 1. Work from what is verified

Read the spec in full, including its verified-facts table and its open questions.
An open question the spec left to the captain is not yours to close inside a ticket.

Refresh the working copy and index before citing anything, exactly as `planner-to-spec` section 1 requires.
Re-check every citation immediately before handover; line numbers drift under other people's merges, and a wrong line number in a ticket sends the implementer to the wrong place with full confidence.

Look for prefactoring that would make the real change easy, and sequence it as its own preceding ticket.
Make the change easy, then make the easy change.

## 2. Vertical slices, and the test that actually catches a horizontal one

Each ticket cuts a narrow but complete path through every layer it needs — data, server, interface, tests — and is demonstrable on its own.
Never slice one layer horizontally.
Horizontal slices carry the full per-ticket fixed cost while producing something that cannot ship alone, and the gaps between them are where handoffs get lost.

Stating the rule is not enough; it failed here even while being followed in name.
Apply this test to every ticket, out loud, before the set is handed over:

> **When this ticket is done: who does what, on which screen, and can that person reach that screen today?**

The incident: a ticket to open publishing to farm owners was written with the note "the screen already exists". The screen that existed was the *administrator's*. Farm owners log in on an entirely different surface with no path to it at all, so the ticket would have shipped an interface nobody could reach. The rule was quoted correctly and the slice was still horizontal.

**The word that gets skipped is "who".** A screen existing is not the same as the actor reaching it.
When the answer is that the actor cannot reach it today, the ticket is not ready: either it must carry the entry path, or it is blocked on the work that builds one.

## 3. Sizing: over-splitting is the expensive mistake

Verticality is the *direction* of the cut. This is the *size*.

Every ticket carries a fixed cost that does not shrink with the work, while worker cost grows with roughly the square of the work's length. So splitting pays only above a threshold, and below it costs more than it saves.

Measured on this fleet, 2026-08-08:

| Quantity | Value |
| --- | --- |
| One validation pipeline run, per ticket | ~10,000,000 tokens (median) |
| Worker start-up context, per fresh session | ~29,313 tokens |
| Per-turn context growth | ~1,300 tokens |
| **Break-even** | **~180–200 worker turns** |

| Ticket size | Splitting it in two |
| --- | --- |
| Very large (~360 turns) | saves ~34M tokens — split it |
| Median (~190 turns) | roughly break-even — split only for another reason |
| Small (~100 turns) | costs ~6.8M tokens — leave it whole |

These numbers are measured on one fleet at one date, and the underlying baseline lives with the fleet that measured it.
Treat the *shape* as durable and the *values* as perishable: re-measure before relying on them, and if a project's pipeline cost differs by an order of magnitude, the threshold moves with it.

Turns cannot be counted at authoring time, so judge by these instead.

**Split when:**
- there is more than one independently shippable behaviour in it;
- one ticket contains understanding an unfamiliar subsystem *and* changing it *and* migrating its callers — separate the groundwork from the work;
- a migration inside it breaks into batches.

**Leave it whole when:**
- it is one behaviour carried end to end, even across many files;
- it is an implementation and that implementation's tests — never separate these;
- it is an implementation and that implementation's documentation — likewise;
- the only argument for splitting is that many files are touched.

**File count is not a size signal.** When one behaviour runs through many files, splitting by file is a horizontal cut wearing a vertical costume.

## 4. Wide refactors are the exception

A change whose blast radius fans across the codebase — renaming a shared column, retyping a shared symbol — cannot land green as a vertical slice.

Sequence it as expand, migrate, contract.
Expand first: add the new form beside the old so nothing breaks.
Then migrate callers in batches sized by blast radius, each batch its own ticket blocked by the expand, with the old form still present so each batch stays green.
Contract last: delete the old form in a ticket blocked by every migrate batch.

## 5. Blocking edges

Give each ticket the tickets that must complete before it can start.
A ticket with no blockers can start immediately, and say so plainly — a dispatchable ticket buried in a blocked set does not get dispatched.

When two tickets must land in a specific order for safety rather than for mechanics, state the ordering *and the direction of the danger*.
"A before B" is a fact; "B before A opens the isolation hole that A closes" is a reason, and a reason survives a reshuffle that a fact does not.

Do not merge a dispatchable ticket into a blocked one to keep a pair together.
That trades a small coordination risk for a certain delay of the half that could have shipped today.

## 6. Mark the tickets that exceed the default worker tier

Tickets are written to be executable by the default worker tier without further design.
Removing ambiguity from the plan is the author's job, not the implementer's.

Add an execution-model section **only** to tickets that tier cannot carry, and **always with the reason** — specifically, what the plan could not close.

An unexplained tier claim cannot be verified by the dispatcher, so it stops being a judgement and becomes something to obey. A reason makes it checkable.

Silence is the default. A ticket with no such section is a default-tier ticket, and no marker is required to say so.

Acceptable reasons name what stayed open at planning time: a shape that only settles once real consumers are moved, a decision the plan genuinely could not close, or a set of changes that must be held consistent in one head at once.
"There are many files" is not a reason. But "these files cannot be split into batches because they must stay consistent with each other, so they must be held at once" is a reason — the difference is whether it explains *why* one head is required.

Two situations look alike and call for opposite responses. **Judgement density** is a new abstraction whose shape only settles by touching the code, and it warrants the higher tier. **Wide context** is one behaviour spread across many files; if those files divide naturally into migration batches, split by batch instead, and only when they cannot be divided does the tier go up.

Before marking, check yourself: wanting to mark a ticket is often a sign the author has not finished their own work. Every ticket looks hard from inside the moment of writing it. Raise the tier only when the decision genuinely cannot be made without touching code.

## 7. Mark what the captain must see with their own eyes

Some changes cannot be judged correct by a test: layout, wording, how an interaction feels, anything where the captain is the user.

Add a captain-verification section to those tickets, naming three things in language the captain can act on directly — the screen or app to open, the action to take, and what they should see if it is right. Use the names the captain sees, not internal terms, file paths, or symbol names.

A marked ticket holds its worker and its working copy until the captain has looked, so the marker has a real cost.
Do not scatter it. Mark only where the captain's eyes are genuinely needed.

Where it is a close call, mark it: the cost of the captain looking at something that did not need it is smaller than the cost of shipping something they should have seen.

Do not mark internal structure, refactors, regression-proofing, documentation, or tooling — anything a test can fully judge.

## 8. Quiz the captain before publishing

Present the proposed breakdown as a numbered list. For each ticket give the title, what it delivers end to end, and what blocks it.

Ask directly:
- Is the granularity right — too coarse, too fine?
- Is each blocking edge real, or merely convenient?
- Should any be merged or split further?

Iterate until the captain approves.
Publish only then, and only through the project's selected delivery path.

Answer section 2's reach test out loud for each ticket during this step.
That is the moment a horizontal slice is cheapest to catch, and in the one incident on record it is where the captain caught it rather than the author.

## 9. Ticket shape

One file per ticket, numbered in dependency order with blockers first, in the feature's own issues directory.
Never a single combined file.

Use the project's document language and its established section names. The roles a ticket must carry:

- **What to build** — the end-to-end behaviour, from the user's perspective, not a layer-by-layer implementation list.
- **Blocked by** — the blocking tickets, or an explicit statement that it can start immediately.
- **Status**.
- **What can be demonstrated when it is done** — the concrete observable result, which is section 2's reach test written down.
- **Acceptance criteria** — checkable, each one a behaviour rather than an activity.
- **Tests** — what gets tested and where, including whether this ticket is the first to cover that code.
- **What this ticket does not do** — the neighbouring work it must not absorb.
- **Execution model** — only when section 6 applies.
- **Captain verification** — only when section 7 applies.

Avoid file paths and code snippets that rot, with the same exceptions `planner-to-spec` section 5 names.
Where a message or string will be read by a human user, the exact wording is part of the deliverable — specify it, and specify it in human language.

## 10. Close out, so the next session starts clean

A plan is not finished when the documents land. Finish it:

1. Land the documents through the project's selected delivery path, after captain approval.
2. Close the backlog item.
3. Report the outcome on the status channel, including which tickets are dispatchable now and which are blocked on what.
4. **Clear this plan's correspondence and working notes out of the working area**, so the next session does not inherit them.
5. **If this plan established a durable rule, promote it into this skill or its sibling** rather than leaving it as a local note.

Step 5 is the one that matters most and is the easiest to skip.
Durable rules left as local notes accumulate in a working directory that also receives one-off correspondence, until nobody can tell which files are rules and which are letters — and because that directory is not versioned, re-seeding the home destroys the rules outright.
Promoting the rule is what makes the next session start from doctrine instead of from archaeology.

## Completion checks

Do not hand a ticket set over until all of these hold.

- [ ] **Is each ticket vertical?** Section 2's reach test answered out loud for every one, with "who" named explicitly.
- [ ] **Does any ticket exceed the default worker tier?** If so it is marked, with a reason naming what the plan could not close.
- [ ] **Does the captain need to see anything with their own eyes?** If so it is marked, with the screen, the action, and the expected result in the captain's own language.
- [ ] Sizing was judged by section 3, and nothing was split on file count alone.
- [ ] Every blocking edge is real, and any safety-ordering states the direction of the danger.
- [ ] Every ticket that can start immediately says so.
- [ ] Every handoff out of this feature names the receiving feature's ticket number.
- [ ] Every citation was re-checked against the current default branch.
- [ ] The captain approved the breakdown before publication.
