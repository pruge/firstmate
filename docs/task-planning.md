# Firstmate task planning

Firstmate's planning layer is `.agents/skills/task-planning/SKILL.md`.

It is a Firstmate-native adaptation of three ideas from Matt Pocock's engineering skills:

- **Wayfinder:** map unresolved decisions before implementation is planned.
- **to-spec:** graduate resolved decisions into an implementation contract.
- **to-tickets:** turn the contract into independently executable vertical slices with explicit dependencies.

It intentionally does **not** import Wayfinder's implementation workflow. Firstmate remains the owner of briefs, worktrees, crew spawning, supervision, delivery modes, validation, and merge authority.

## Planning levels

| Level | Use when | Artifacts | Execution |
| --- | --- | --- | --- |
| Simple | narrow, obvious, one crew | none | existing Firstmate lifecycle |
| Planned | clear request, multiple meaningful changes or crews | `spec.md`, `tickets/` | existing Firstmate lifecycle after plan approval |
| Wayfinder-planned | destination or load-bearing decisions are unclear | `wayfinder.md`, `spec.md`, `tickets/` | existing Firstmate lifecycle after plan approval |

The gate is deliberately not mandatory for every task. This keeps small fixes from paying the token and latency cost of full planning.

## Artifact flow

```text
captain request
      |
      v
planning level
  /    |     \
Simple Planned Wayfinder-planned
 |       |          |
 |    spec.md   wayfinder.md
 |       |          |
 |   tickets/  <----+
 |       |
 +-------+---------->
         |
   captain review
         |
         v
 Firstmate brief/spawn
         |
       crews
```

Planning artifacts live under `data/<task-id>/plan/` in the Firstmate home and are private operational evidence unless the captain explicitly asks for project documentation.

## Integration boundaries

The planning skill composes with existing Firstmate procedures rather than replacing them:

- `diagnostic-reasoning` remains authoritative for bug causality and reproduction.
- `decision-hold-lifecycle` and `captain-hold-lifecycle` remain authoritative for unresolved decisions and approval.
- `project-management` remains authoritative for project intake and delivery posture.
- `harness-adapters` and `quota-array-dispatch` remain authoritative for crew runtime/model selection.
- `fm-brief.sh` and `fm-spawn.sh` remain authoritative for implementation execution.

A planning ticket is not a Wayfinder decision ticket. Decision questions are resolved through scout work or captain decisions before they graduate into implementation tickets.

## Token-efficiency rule

Do not invoke the full Wayfinder-style workflow merely because a task exists. Prefer the cheapest workflow that preserves correctness:

1. direct crew for simple work;
2. spec + tickets for clear multi-part work;
3. Wayfinder + spec + tickets only when unresolved decisions can materially change the implementation.

Likewise, ticket existence does not imply a separate review-agent call. Verification is specified per ticket and escalated according to the project's existing delivery mode and risk.
