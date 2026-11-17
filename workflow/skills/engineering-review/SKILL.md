---
name: engineering-review
description: Run an independent, read-only engineering review of a code change with an automated reviewer (the local Codex CLI by default), fix its findings and close it within the 3-call limit. Use automatically after implementing any nontrivial code change (execution, evidence-producing, validation, launch or credential paths, scripts, multi-file changes) and before committing it. Not for formal reviews of research artifacts (use research-review).
---

# Engineering review

An independent check of a code change by a reviewer other than the implementing agent. It is not Evidence, not a research review and not an authorization (`workflow/WORKFLOW.md` §3, §9). The implementing agent runs it without asking the researcher: read-only calls to the designated reviewer, within the 3-call limit, are part of every authorized engineering task (§3, "The one standing permission"). That covers no other model call or service. If the task instruction excludes reviewer calls, record `engineering review: not run (excluded by instruction)`.

## When

Run it before committing a **nontrivial** code change:

- code that runs experiments, calls models, produces, validates or records evidence, or computes hashes;
- launch, authorization, credential, sandbox or data-access paths;
- `scripts/`, test infrastructure, or a change spanning several modules.

Skip it for typos, wording, formatting, status and documentation updates, and one-line fixes already covered by a test outside the paths listed above. When unsure, run it.

## Procedure

1. **Prepare.** Run the tests first. The scope under review must cover everything that will be committed: a local commit range (`git diff <base>..HEAD`), or the working tree against `HEAD` (`git add -N <new files>`, then `git diff HEAD`, so staged changes and new files are included). Check with `git status --short` that nothing to be committed is outside it. Count the calls already completed in this cycle (§9), including any whose output was discarded: at most 3 without the researcher's authorization.
2. **Find the reviewer.** `command -v codex`. If it is not on `PATH`, look for it where the machine installs CLI tools (for example a Node version manager's environment). If none is available, do not fake a review: write `engineering review: not run (<reason>)` in the commit message and the final report, and continue.
3. **Call it read-only**, with the output saved outside the repository (scratch directory):

   ```bash
   codex exec --sandbox read-only -C <repo> -o <scratch>/eng-review-<N>.md "<prompt>"
   ```

   Prompt: what changed and why (one paragraph), the exact diff command to read, the files or hashes that must not change (frozen Protocols, Decisions, evidence, hash-bound inputs), and the request: *"Review for correctness bugs, regressions, missing or weak tests, security of credentials and execution boundaries, and any change to scientific semantics or to hash-bound files. Report each finding as BLOCKER / IMPORTANT / MINOR with file:line and a concrete failure scenario. Do not modify files."*
4. **Triage** each finding: fix it with the smallest compatible change, or reject it with a one-line reason. Fix every `BLOCKER` and `IMPORTANT`; `MINOR` at your judgment. If a fix would change scientific semantics, a frozen Protocol, a Decision, recorded evidence or a hash-bound input, do not make it: stop and ask the researcher.
5. **Retest**, then re-review (the next call) only if a `BLOCKER` or `IMPORTANT` was fixed or the fixes were nontrivial. The cycle ends at a passing review: no open `BLOCKER` or `IMPORTANT`.
6. **Limit.** If the 3rd call still leaves a `BLOCKER` or `IMPORTANT` open, stop calling, report the open findings and ask the researcher. A 4th call needs their explicit authorization in chat.
7. **Record** in the commit message (and the active plan, if the change belongs to one):

   ```text
   Engineering review: codex, agent_call 2/3, passing; F1 fixed, F2 fixed, F3 rejected (<reason>)
   ```

   Do not commit the raw reviewer output unless it is worth keeping; it never goes to `research/reviews/`.

## Rules

- The reviewer only reads; the implementing agent makes every change.
- Never present a self-review, or a review that failed to run, as independent.
- A passing engineering review means "no open engineering finding", never "scientifically valid".
