# Agent Rules

This repository follows the research workflow in `workflow/WORKFLOW.md`. Keep this file short: it is loaded every session.

## Start of every session

1. Read `docs/CURRENT.md` (machine-readable source: `meta/status.yaml`).
2. If `meta/status.yaml` says `phase: template`, the repository is an uninitialized template: tell the user to run `/project-init`, and do no research work until it has run.
3. Load only what the task needs: the relevant Protocol / Decision / Plan, then Evidence and history on demand. Read `workflow/WORKFLOW.md` when the task touches workflow rules.

## Where things live

| What | Where |
| --- | --- |
| Current state | `meta/status.yaml` (SSOT), `docs/CURRENT.md` (view); update both together |
| Scientific semantics | `research/PROTOCOL.md` |
| Researcher decisions | `research/decisions/` (skill `record-decision`) |
| Formal reviews | `research/reviews/<artifact>/` (skill `research-review`) |
| Current work | `plans/active/` |
| Project identity, deployment config | `project.yaml` |
| Skills (canonical source) | `workflow/skills/`, index in `workflow/skills/README.md` |

## Rules

- Search the repository before asking. Grill (`/grill-with-docs`) only when the repository cannot answer a question and the answer affects research direction, evaluation semantics, a frozen contract, or a researcher trade-off.
- Do not create a parallel ADR, glossary or status system.
- Never silently change a `Frozen` Protocol; amend it through a Decision and a new Protocol version.
- Keep `Implemented`, `Tested`, `Experimentally Evaluated` and `Scientifically Supported` distinct. Unknown is not failed; not evaluated is not negative.
- Long jobs (about 2 minutes or more, or detached) run on the remote host only through the `remote-run` skill (`scripts/remote` + Monitor `watch` + `resmon`). Without the Monitor tool, do not start long remote jobs.
- Change code only in this working tree; the remote host is a mirror. Jobs write only to `results/` (tracked) and `output/` (ignored).
- Host names, ports and paths are deployment config (`project.yaml`, `docs/REMOTE-COMPUTE.md`); never put them into Protocol, Decision or Evidence semantics.
- Edit skills only in `workflow/skills/`, then run `scripts/install-agent-skills.sh`.
- Write documentation in English.
- At the end of every task: run `scripts/check-workflow.sh` (and `tests/run.sh` if scripts changed), commit the task's changes and `git push` to the current branch on origin. If the push fails, say so in the result; never skip it silently.
