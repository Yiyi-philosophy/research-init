---
artifact: research/PROTOCOL.md
reviewed_commit: <commit>
# baseline_review: research/reviews/<artifact>/<YYYYMMDD-artifact-reviewer-rN>.md   # required when review_type is closure_review
reviewer: <reviewer>
invoked_by: agent # agent | human (agent: counts toward the 3-call limit per review cycle, WORKFLOW.md §9)
agent_call: 1 # only when invoked_by: agent; number of this call within the review cycle
review_type: formal_research_review # formal_research_review | closure_review
round: 1
date: "YYYY-MM-DD"
outcome: READY_AFTER_CHANGES # READY_FOR_GRILL | READY_AFTER_CHANGES | BLOCKED | <other explicit outcome>
---

# <Artifact> review — round <N>

## Scope

<What was reviewed (paths, commit) and what was out of scope.>

## Findings

### F1 — <title>

- Severity: IMPORTANT # BLOCKER | IMPORTANT | MINOR | REJECTED
- Location: <path:line or section>
- Finding: <what is wrong, with evidence>
- Smallest compatible fix: <proposed fix>

<!-- Closure review: for each baseline finding state CLOSED / NOT_CLOSED with evidence,
     then list any new BLOCKER or IMPORTANT introduced by the fix. -->

## Outcome

<Outcome and the artifact-specific next transition.>
