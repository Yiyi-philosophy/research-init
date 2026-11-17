---
name: engineering-review
description: Run a risk-proportionate, independent, read-only engineering review of a code change with an automated reviewer (the local Codex CLI by default). Choose a review mode (0 skip, 1 focused, 2 standard, 3 high-assurance), send a task-aware prompt, triage the findings independently and close the cycle within the 3-call limit. Use automatically after implementing a code change and before committing it. Not for formal reviews of research artifacts (use research-review).
---

# Engineering review

An independent check of a code change by a reviewer other than the implementing agent. It is not Evidence, not a research review and not an authorization (`workflow/WORKFLOW.md` §3, §9). The implementing agent runs it without asking the researcher: read-only calls to the designated reviewer, within the 3-call limit, are part of every authorized engineering task (§3, "The one standing permission"). That covers no other model call or service. If the task instruction excludes reviewer calls, record `engineering review: not run (excluded by instruction)`.

Goal: catch real problems without turning a small research task into a defensive-engineering project. The reviewer advises; the implementing agent decides and is accountable for the decision.

## 1. Choose the mode

Before calling the reviewer, choose the mode from what the change actually does, not from keywords:

| Mode | Typical change | Review |
| --- | --- | --- |
| **0 Skip** | Documentation, formatting, simple config, a small isolated change already covered by deterministic tests | Run the relevant checks; no reviewer call |
| **1 Focused** | One-off diagnostic, small experiment script, temporary data transformation, isolated research utility | Does it do the task? Are the scientific inputs and outputs right? Realistic correctness or security failures? Unnecessary complexity; could it be done with fewer moving parts? |
| **2 Standard** | Maintained multi-module code, agent execution logic, evaluation components, data-processing infrastructure, persistent experiment tools | Correctness and regressions, interfaces and contracts, evidence integrity, relevant security boundaries, test coverage, maintainability and unnecessary complexity |
| **3 High-assurance** | Authorization or credential boundaries, production execution, external financial side effects, persistent services on untrusted input, destructive or irreversible operations | An explicit threat model, authorization correctness, failure and recovery, data integrity, significant edge cases, realistic adversaries |

Weigh: the task's purpose; actual exposure and trust boundaries; persistence and reversibility; impact of failure; deployment environment; complexity and expected lifetime. Choose the mode that the riskiest part of the change needs.

- Calling an LLM or reading an API key does not by itself make a change mode 3. A one-off script that sends fixed requests to the operator's own endpoint with a key from a local file is mode 1: protect the key, nothing more general.
- A temporary script is not harmless by default. Anything that can do material irreversible harm (deleting or overwriting data, writing into recorded evidence, changing a frozen or hash-bound input, spend or side effects beyond what was authorized) is at least mode 2 for that part. In mode 1, whatever could waste a call that cannot be repeated, or silently skip one arm, counts as a realistic correctness failure.
- Raise the mode if a finding shows the risk is larger than assumed; never lower it to escape a finding.
- Record it in one line: `Review mode: 1 (one-off two-call diagnostic; key read from a local file; outputs local)`. Mode 0: `Engineering review: mode 0, not run (<reason>)`. Ordinary mode selection needs no researcher approval.

## 2. Prepare

1. Run the tests. The scope under review must cover everything that will be committed: a local commit range (`git diff <base>..HEAD`), or the working tree against `HEAD` (`git add -N <new files>`, then `git diff HEAD`). Check with `git status --short` that nothing to be committed is outside it.
2. Count the calls already completed in this cycle (§9), including any whose output was discarded: at most 3 without the researcher's authorization.
3. Find the reviewer: `command -v codex`; if it is not on `PATH`, look where the machine installs CLI tools (for example a Node version manager's environment). If none is available, do not fake a review: record `engineering review: not run (<reason>)` and continue.

## 3. Call the reviewer (read-only)

```bash
codex exec --sandbox read-only -C <repo> -o <scratch>/eng-review-<N>.md "<prompt>"
```

Fill in this prompt; keep each context field to a line or two:

```text
Engineering review, mode <N> (<Focused|Standard|High-assurance>).
Objective: <what the task must achieve, and for whom>.
Scope: <files / components changed>. Diff: run `<exact diff command>`.
Lifetime and deployment: <one-off | maintained | persistent service>; <where it runs, who runs it>.
Trust and security boundaries: <what is trusted, what is not, which secrets exist and where they live>.
Scientific invariants: <frozen Protocols, Decisions, evidence, hash-bound inputs that must not change>.
Out of scope: <what this change deliberately does not handle>.
<Mode 3 only: Threat model: assets, actors, entry points, the harm to prevent.>

Review the implementation proportionately to the selected mode and the actual task requirements.
Prioritize correctness, material security risks, scientific integrity and simplicity.
For every finding, explain the concrete failure scenario, prerequisites, impact and the smallest adequate remedy.
Do not demand production-grade defensive infrastructure for a disposable research experiment unless there is a credible material risk.
Distinguish verified bugs, realistic risks and optional hardening opportunities.
Treat unnecessary complexity and excessive defensive programming as potential engineering defects.
Prefer simplifying or removing unnecessary functionality over adding another layer of guards.
Do not modify files, run other agents or call other services. Return findings for the implementing agent to evaluate.

Return, concisely:
Review mode: <N>.
Findings: F1, F2, ... each with file:line; severity BLOCKER / IMPORTANT / MINOR; verified bug or realistic risk; evidence or reproducible scenario; preconditions and impact; smallest remedy; confidence and assumptions.
Optional hardening: H1, H2, ... (not required for acceptance), kept apart from the findings.
Overall: ACCEPTABLE / ACCEPTABLE_AFTER_CHANGES / BLOCKED.
```

## 4. Triage every finding yourself

Do not adopt the reviewer's severity or remedy automatically. For each `BLOCKER` and `IMPORTANT` decide:

1. Is it factually correct (check the code, reproduce it if that is cheap)?
2. Is the failure credible under the task's actual assumptions and deployment, and what concrete harm follows?
3. Is the severity proportionate, and is the issue within the task's scope?
4. What is the simplest sufficient correction? Could removing functionality or narrowing the surface solve it better?
5. Would the fix add more code, failure modes or maintenance than the problem warrants?
6. Does the fix touch scientific validity, a frozen or hash-bound input, or an authorization boundary?

| Disposition | When |
| --- | --- |
| **FIX** | Valid and material: apply the smallest adequate fix |
| **SIMPLIFY** | Resolve it by removing complexity or narrowing the surface (fewer features, fewer persisted fields, no custom framework) |
| **REJECT** | Incorrect, unsupported, or outside the actual threat model; give the concrete reason it cannot happen here, not just "unlikely" |
| **ACCEPT LIMITED RISK** | Real but small and within the task's authority; record the residual risk. Not for the severity floor below, and not in mode 3 (escalate instead) |
| **ESCALATE** | A genuine unresolved security, scientific or authorization issue, or a fix that would touch a frozen Protocol, a Decision, recorded evidence or a hash-bound input: stop and ask the researcher |

**Severity floor.** A finding that is correct and credible under the actual deployment and concerns credential exposure, an unauthorized action, evidence corruption or a scientific-contract violation keeps its severity and is fixed, simplified away or escalated. Never dismiss a verified safety issue silently. `MINOR` findings and optional hardening are at your judgment; by default leave hardening out of a mode-1 change.

## 5. Re-review, and when to stop

- Re-review (the next call) only when another look will meaningfully reduce risk: a fix to a `BLOCKER` / `IMPORTANT` was nontrivial or touched a security, evidence or authorization boundary, or the mode is 3. In modes 1–2 a small fix covered by a new test may close without a re-review; say so in the record.
- A re-review is a closure check, not a fresh audit. Give it the same context, the previous findings with your dispositions and the diff of the fixes. Ask whether each `FIX` / `SIMPLIFY` resolves its finding and whether the fixes introduced a material new problem. Do not widen the scope into new hypothetical cases.
- If findings keep landing on the same defensive subsystem, stop patching it. Reconsider the design and prefer removing or narrowing it (for example, do not persist what you would otherwise have to redact).
- **Passing** means that after triage no material `BLOCKER` or `IMPORTANT` remains open under the task's actual acceptance criteria. A `REJECT` with a recorded reason and an `ACCEPT LIMITED RISK` close a finding; an `ESCALATE` does not. Passing does not mean that arbitrary malicious input has been proven harmless. Never bypass a genuine `BLOCKER` to finish.
- **Limit.** If the 3rd call still leaves a material `BLOCKER` or `IMPORTANT` open, stop calling, report the open findings and ask the researcher. A 4th call needs their explicit authorization in chat.

## 6. Record and report

Commit message (and the active plan, if the change belongs to one):

```text
Engineering review: codex, mode 1 (<reason>), agent_call 1/3, passing; F1 FIX, F2 SIMPLIFY, F3 REJECT (<reason>); H1-H2 not taken
```

In the task report, keep it short:

```text
Triage: F1 FIX - <why>; F2 REJECT - <why>; ...
Actions: <the smallest changes made>
Validation: <tests run and results>; residual risk: <none | ...>
Decision: proceed | revise | escalate
```

Do not commit the raw reviewer output unless it is worth keeping; it never goes to `research/reviews/`. Ordinary code changes get no formal review document.

## Calibration

- **One-off two-call LLM diagnostic** (fixed requests, the operator's endpoint, key in a local file, outputs local): mode 1. Expect and fix: wrong or unpinned scientific inputs, the key appearing in a persisted file or log, one arm silently not sent. Reject, or leave as hardening: multi-layer encoding attacks on redaction, a persistent runner, claim and recovery subsystems, cross-run locking. The simple remedy for a leak is usually to not persist headers or request echoes at all.
- **Persistent agent execution system** (long-running, with authorization, credentials, scientific records and external compute): mode 3 for the authorization, credential and evidence-writing paths, mode 2 for the rest. Keep every finding on the authorization and evidence boundaries at full severity; escalate whatever stays unresolved after the 3rd call.

## Rules

- The reviewer only reads; the implementing agent makes every change and every triage decision.
- Never present a self-review, or a review that failed to run, as independent.
- A passing engineering review means "no open material engineering finding", never "scientifically valid".
