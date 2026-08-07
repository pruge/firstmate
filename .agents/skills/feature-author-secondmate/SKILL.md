---
name: feature-author-secondmate
description: >-
  Agent-only procedure for standing up a persistent feature-authoring secondmate for one project.
  Use when the captain wants a standing conversational partner to draft specs and tickets for a project, as opposed to a one-off investigation or implementation.
  Owns charter scope wording, retired-tool exclusions, authoring discipline, and the captain-direct-conversation contract; delegates every mechanical secondmate step to secondmate-provisioning.
user-invocable: false
metadata:
  internal: true
---

# feature-author-secondmate

## When to use this

Use this when the captain wants a standing secondmate that drafts feature specs and tickets for one project through ongoing conversation with the captain.
Do not use it for a one-off investigation, a one-off spec, or implementation work: those are ordinary scout or ship tasks under `AGENTS.md` section 7.

## Why this structure works

Hard rule 4 in `AGENTS.md` section 1 says crewmates never address the captain, and that all crewmate communication flows through firstmate.
Read alone, that seems to rule out any secondmate whose job is to ask the captain clarifying questions.
The rule's first clause is one-directional: it stops a crewmate from initiating contact with the captain, not the captain from walking into a crewmate's window.
The second clause still stands as the default, so a standing captain-to-secondmate conversation is not the sanctioned routing path; it runs on the rule's third clause, which treats direct captain intervention in a crewmate window as authoritative and reconciled at the next supervision review.
This pattern therefore depends on that after-the-fact reconciliation, and is never a license for the secondmate to open contact with the captain itself.
So the structure that works is: the captain opens the secondmate's window and talks with it directly, and firstmate's job is to feed that secondmate verified facts and read back what it produced, never to relay the conversation.

## Scope the charter narrowly - authoring only

Write the secondmate's `scope:` field as `<project> feature spec and ticket authoring`, not `<project>`.

`AGENTS.md` section 7 routes in-scope work to a secondmate by matching the request against its registered scope.
A scope of `<project>` (broad ownership) pulls implementation requests to the secondmate too, leaving firstmate nothing to do and giving the captain two conversational partners instead of one.
Authoring the document is the secondmate's job; turning it into code stays with firstmate, dispatched to an ordinary ship crewmate the normal way.

## The charter cannot call captain-only skills

A project may mark some of its skills captain-only, for example by locking an authoring or dispatch family such as `to-spec`, `to-tickets`, `implement`, `wayfinder`, `ask-matt`, or `triage` so the model cannot invoke them itself.
Read the project's own skill set to learn which ones it treats that way, rather than assuming any particular name or locking mechanism.
State plainly in the charter: do not attempt to invoke the skills the project has marked captain-only, and do not ask the captain to invoke them either.
If the captain needs one of them run, the captain runs it directly in that window; the secondmate's job is to pick up the resulting conversation and turn it into documents.

## Carry forward retired workflows as an exclusion list

Captain preferences propagate to `data/captain-shared.md` under the `secondmate-provisioning` contract.
State the retirement rule generally in the charter: a workflow or skill the captain has retired may still be installed on the machine, and the secondmate has no history of that retirement, so it will reach for it naturally unless told not to.
Naming every retired command by name in the charter, at seeding time, is the required setup check - not a one-time note but a standing exclusion list the charter carries.

## Authoring discipline (charter body)

State these as the secondmate's drafting standards:

- Write vertical slices - each ticket is a narrow but complete path end to end, never a horizontal slice through one layer only.
- For a broad refactor, expand-migrate-contract: add the new shape, migrate callers in batches, delete the old shape last.
- Sequence groundwork first when structure needs work before the feature can land cleanly, as its own preceding ticket.
- Close every decision the spec can close; the spec should leave no product decision for the implementer to bounce back to a human.
  Escalate any product decision nobody has made yet to the captain rather than inventing an answer.
- Pin the seams: the spec fixes what gets tested at authoring time, because an empty test plan means the implementer tests wherever is convenient.
- Name what is out of scope explicitly; an unstated exclusion keeps resurfacing in review.

## Handoffs must land as a ticket on the receiving side

When a spec pushes work outside its own scope to another feature, that work must become an actual ticket inside the receiving feature's own spec and ticket set.
Recording it only in an "impact" or "downstream" note on the sending side and treating that as done lets the work fall between two features.
This is the reason this skill exists, and field experience shows the failure is real: one feature handed off a state-enforcement requirement to another feature, and that requirement never appeared anywhere in the receiving feature's own spec or tickets.
Shipped as drafted, an operator stopping a worker would have left that worker's app still showing as running.
Make this a drafting completion check: for every item handed off, the secondmate must be able to name the receiving feature's ticket number that carries it.

## What firstmate gives the secondmate

Give it facts confirmed by reading the code, not guesses: whether a named symbol actually exists, its exact file and line, and what precedent already exists in the codebase for the pattern being specified.
An instruction built on an unverified assumption puts the resulting spec on a foundation that does not exist.

## What the secondmate does not do

- It does not write code, and it does not write the authored documents into the project either; both leave through the project's selected delivery path, never as a direct edit inside the secondmate's own `projects/` clone.
- It drafts in conversation and in its own home, so nothing here relaxes hard rule 1 in `AGENTS.md` section 1: a secondmate never edits project files with its own file tools.
- It does not make product decisions alone; a decision that belongs to the captain is marked and left for the captain, never invented.

## How output comes back

The documents ship out through the project's selected delivery path, the same as any other secondmate output.
Firstmate learns the outcome from one marked status line, per `AGENTS.md` section 7 - never by reading the secondmate's conversation window.

## Mechanics this skill delegates

Every mechanical step - charter scaffolding, home seeding, harness pin, launch, recovery, backlog handoff, retirement - is owned by `secondmate-provisioning`.
Load that skill and follow it for creation, seeding, validation, launch, recovery, and teardown of the home described here; this skill only supplies the charter content and scope wording above.
