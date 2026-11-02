---
name: record-decision
description: Record a research decision the researcher made in research/decisions/, or supersede an earlier one, including amendments to a frozen Protocol. Use when a choice that the repository cannot answer has been settled (often during a Grill) and it is hard to reverse, surprising without context, and the result of a real trade-off.
---

# Record a decision

A decision record keeps a researcher's choice out of chat history and explains *why*. Typical examples: prioritising scientific novelty over leaderboard rank; whether external data is allowed; whether a kind of feedback may enter the next iteration; changing a frozen evaluation definition.

## When to record

Record only when all three are true:

1. **Hard to reverse**: changing your mind later costs something real.
2. **Surprising without context**: a future reader would ask "why did they do it this way?"
3. **A real trade-off**: there were genuine alternatives and one was chosen for specific reasons.

Otherwise skip it. Implementation choices (which library, how to structure code) are not research decisions. Scientific semantics themselves (metric definitions, data boundary) belong in the Protocol; the decision records why they were chosen or changed.

The decision must come from the researcher. Never record an agent's recommendation as a decision before the researcher confirms it.

## Steps

1. Number: highest `NNNN` in `research/decisions/` plus one (start at `0001`; create the directory lazily).
2. Write `research/decisions/NNNN-<slug>.md` from `workflow/templates/decision.md`. One short paragraph is often enough; add *Considered options* or *Consequences* only when they add value.
3. Apply the consequences in the same change: update the Protocol (if not frozen), the active plan, and `meta/status.yaml` + `docs/CURRENT.md` if the current objective or next action changed.

## Superseding

Accepted decisions are never deleted or rewritten. To change one, write a new decision that states what it replaces, and set the old record's front matter to `status: superseded by NNNN` (the only edit allowed on an accepted record).

## Amending a frozen Protocol

```text
Protocol v1 (Frozen) → Decision (amendment) → Protocol v2
```

1. Record the amendment decision: what changes, why, and how results produced under v1 are to be read.
2. Preserve v1 (e.g. `research/protocol-history/PROTOCOL-v1.md`) before editing.
3. Write v2 in `research/PROTOCOL.md` with `Version: v2` and `Supersedes:` pointing to v1 and the decision. Re-freeze when ready (a review may be required: skill `research-review`).
4. Update `meta/status.yaml` and `docs/CURRENT.md`.
