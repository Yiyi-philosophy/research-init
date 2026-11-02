---
name: domain-modeling
description: Build and sharpen the project's domain model. Use when research terminology or scientific semantics are being defined, challenged or changed; record resolved semantics in the Protocol and resolved decisions in research/decisions/.
---

# Domain Modeling

Actively build and sharpen the project's domain model as you design. This is the *active* discipline: challenging terms, inventing edge-case scenarios, and writing semantics and decisions down the moment they crystallise. (Merely *reading* the Protocol for vocabulary is not this skill: that's a one-line habit any skill can do. This skill is for when you're changing the model, not just consuming it.)

## Project-local research rules

- Record scientific terms and semantic boundaries in the relevant `Protocol`, normally `research/PROTOCOL.md`.
- Record important research decisions in `research/decisions/` with the `record-decision` skill, not in `docs/adr/`.
- Do not create `docs/adr/` or `GLOSSARY.md` by default. Create either only when the user explicitly requests that upstream artifact (see the last section).

## During the session

### Challenge against the Protocol

When the user uses a term that conflicts with the existing language in the Protocol, call it out immediately. "Your Protocol defines 'held-out set' as X, but you seem to mean Y. Which is it?"

### Sharpen fuzzy language

When the user uses vague or overloaded terms, propose a precise canonical term. "You're saying 'accuracy': do you mean top-1 on the validation split or on the frozen test split? Those are different things."

### Discuss concrete scenarios

When domain relationships are being discussed, stress-test them with specific scenarios. Invent scenarios that probe edge cases and force the user to be precise about the boundaries between concepts.

### Cross-reference with code

When the user states how something works, check whether the code agrees. If you find a contradiction, surface it: "Your evaluation script averages over seeds, but you just said results are reported per seed. Which is right?"

### Update project research records inline

When a scientific term or semantic boundary is resolved, update the relevant `Protocol` right there. When an important research decision is resolved, record it right there with `record-decision`. Don't batch these up: capture them as they happen. A `Frozen` Protocol is never edited in place; a semantic change to it goes through a Decision and a new Protocol version.

### Record durable research decisions

Only record a decision when all three are true:

1. **Hard to reverse**: the cost of changing your mind later is meaningful
2. **Surprising without context**: a future reader will wonder "why did they do it this way?"
3. **The result of a real trade-off**: there were genuine alternatives and you picked one for specific reasons

If any of the three is missing, skip the decision record.

## Upstream artifacts (only on explicit request)

If the user explicitly requests a `GLOSSARY.md`, keep it devoid of implementation details and use [GLOSSARY-FORMAT.md](./GLOSSARY-FORMAT.md); do not use it as a spec, scratch pad, or repository for implementation decisions. If the user explicitly requests an ADR, use [ADR-FORMAT.md](./ADR-FORMAT.md). In both cases keep the project's research records authoritative and create files lazily, only when there is something to write.
