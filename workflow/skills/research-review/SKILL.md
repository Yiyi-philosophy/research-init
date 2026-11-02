---
name: research-review
description: Run and record a formal research review or a closure review of a research artifact (Proposal, Protocol, Experiment, Evidence). Use when asked to review a research artifact, to close a previous review's findings, or before freezing a Protocol or accepting Evidence.
---

# Research review

A review is an immutable governance record of an independent check. It is not Evidence and not a Decision: it records judgment and governance state, and it cannot replace experimental results or the researcher's choice of direction.

## What a reviewer checks

- Violations of a frozen contract.
- Changes to scientific semantics.
- Scope creep.
- Authority conflicts (two sources claiming the same truth, e.g. status kept outside `meta/status.yaml`).
- Claims not supported by evidence (`Implemented` / `Tested` / `Experimentally Evaluated` / `Scientifically Supported` conflated; unknown treated as failed).
- Missing reproducibility information (run_id, commit / dirty / tree, data and config refs).

Prefer the **smallest compatible fix** over redesign.

## Formal review

1. Identify the artifact and a stable, readable artifact name (`proposal`, `protocol`, `exp-001`, ...) and the commit under review (`git rev-parse --short=12 HEAD`; the artifact must be committed).
2. Find the round: count existing files in `research/reviews/<artifact>/`; this review is `r<N+1>`.
3. Write `research/reviews/<artifact>/YYYYMMDD-<artifact>-<reviewer>-rN.md` from `workflow/templates/review.md`. Front matter must contain `artifact`, `reviewed_commit`, `reviewer`, `review_type: formal_research_review`, `round`, `date`, `outcome`.
4. Give every finding a severity: `BLOCKER`, `IMPORTANT`, `MINOR` or `REJECTED` (a raised concern judged invalid). Give the review one outcome: `READY_FOR_GRILL`, `READY_AFTER_CHANGES`, `BLOCKED`, or another explicit outcome. Never mix severity and outcome.
5. Update `meta/status.yaml` → `artifacts.<artifact>.review.status` (the outcome) and `latest_review` (the new path), and `docs/CURRENT.md`, in the same change.

## Closure review

After the smallest compatible fixes have been made:

1. Write the next round with `review_type: closure_review` and `baseline_review:` pointing to the review being closed.
2. For each baseline finding, state `CLOSED` or `NOT_CLOSED` with evidence: the fix is real, minimal and correct.
3. Report any new `BLOCKER` or `IMPORTANT` introduced by the fixes.
4. Do not reopen accepted Decisions and do not redesign the artifact. A new direction-level concern is recorded separately and goes through Decision / Protocol.
5. Update `meta/status.yaml` and `docs/CURRENT.md`.

## Next transition after closure

| Artifact | Transition |
| --- | --- |
| Proposal | Grill / Decision |
| Protocol | Freeze |
| Experiment | Gate / Status |
| Evidence | Gate / Status |

## Rules

- Never edit a completed review file. Fixing findings produces the next round.
- File names must match `YYYYMMDD-<artifact>-<reviewer>-rN.md` inside `research/reviews/<artifact>/`; `scripts/check-workflow.sh` enforces it.
