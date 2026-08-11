---
name: next
description: Report what work can start now on a project, using the gootte development-order tool as the ordering authority rather than reading tickets by hand. Use when the captain invokes /next, asks "what's next", asks what can be dispatched now, or asks what can run in parallel.
user-invocable: true
metadata:
  internal: true
---

# next

Report what can start now, and say plainly which of it is worth dispatching.

## Why this exists

Reading `ORDER.md` and ticket `Status:` lines by hand produces wrong answers.
The plan holds *why* the order is what it is; the tickets hold *state*; only a synthesis of the two is the actual order, and a person doing that synthesis in their head gets it wrong.
That happened here on 2026-08-11: a ticket body said "01 is not my prerequisite" and it was true about build order, while the plan put 01 first because 02 can only be judged after 01 lands.
Both statements were correct and the hand-read was still wrong.

**The order comes from gootte. How many to stand up is firstmate's call.**

## 1. Ask

```sh
data/tools/gootte.sh next <project>     # what can go in parallel now
data/tools/gootte.sh order <project>    # the full step table, when the picture is unclear
data/tools/gootte.sh doctor             # where it is reading from
```

That script is the only supported way to reach gootte from firstmate.
Do not run `pnpm gootte`, do not `cd` into a clone, and do not read `ORDER.md` to reconstruct the order.

It is home-local, under the gitignored `data/`, because it points at this captain's own gootte checkout.
If it is absent or refuses, say exactly that and what would fix it.
🔴 A failed lookup is a blocker to report, never a licence to fall back to reading tickets by hand - that fallback is the exact mistake this skill exists to prevent.

## 2. Check the answer against reality before repeating it

The tool prints which working copy answered. Read that line.
gootte reads the captain's own copy; crewmates work from the fleet's clones.
When the two have diverged, the order is still right but a ticket body a crewmate will read may differ - check before dispatching, and say so if it matters.

Then reconcile each candidate against what is already happening:

- Work already in flight, from the live task records.
- Queued and held backlog items, from `tasks-axi ready --include-held`.
- A candidate the captain has explicitly parked.

A candidate that is already being worked is not a candidate. Drop it and say why.

## 3. Apply the one thing gootte does not know

gootte counts what is *technically* unblocked. It does not count **captain attention**.

A ticket carrying a captain-verification section holds its worker and its working copy until the captain has actually looked, and **the captain looks at one screen at a time**.
The tool marks those candidates with 👁.
Eight parallel-capable tickets where seven need the captain's eyes is not eight dispatchable tickets - it is a queue in front of one person.

So: take the order from gootte, then decide the count yourself, and state the count you chose and why.
Prefer a candidate that closes a feature over one that opens a new front, and prefer one that needs no captain eyes when eyes are already queued.

## 4. Report

Lead with the recommendation, not the listing. In the captain's own words, per `AGENTS.md` section 9:

- What can start now, and which one you would start.
- The reason, taken from gootte's own `why` line - that reason is the most valuable thing the tool produces, and it is what stops a wrong pick.
- What is already under way, so the captain sees the whole board.
- How many captain-verification items are queued, and in what order they will arrive.
- Any mismatch gootte reported, in plain language.

Dispatch only on the captain's word, or under this project's standing autonomy, exactly as `AGENTS.md` section 7 requires.
This skill decides ordering; it does not create dispatch authority.

## 5. When gootte is missing something, say so

The captain's standing instruction is to raise gaps rather than work around them.
When gootte cannot answer something the decision needed, write it down with the concrete evidence and route it to gootte's own planning, the same as any other finding.
