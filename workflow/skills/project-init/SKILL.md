---
name: project-init
description: One-time bootstrap of a project that just received the research workflow (via scripts/install-workflow.sh or a template clone) - sets identity and remote config, writes the project's state files, drafts the Proposal with the researcher, then deletes this skill.
disable-model-invocation: true
---

# Project init

Run once, in a project whose `meta/status.yaml` says `phase: template` (normally right after `scripts/install-workflow.sh` copied the workflow in). The last step deletes this skill, so later sessions never see it. Project/template ownership and upgrades: `workflow/WORKFLOW.md` §2.

## 1. Collect (one round of questions, each with a recommended answer)

- **Project name** (human-readable).
- **Slug**: `[a-z0-9-]`, recommended: derived from the name. It namespaces everything on the shared remote host (`~/<slug>`, `~/rw-runs/<slug>/`, `rw-<slug>-*`), so it must be unique among projects on that host.
- **Research goal**, in the researcher's own words: question, motivation, hypotheses, success criteria, constraints, data. Whatever they have now; the rest stays open.
- **Remote compute**: whether the project needs it, and if so the host's ssh alias from `~/.ssh/config` (`--host`). Leave it unset when there is no remote host.
- **Repository**: the project's git remote, if it should be pushed (`git remote -v`; add one with `git remote add origin <url>` only with the researcher's go-ahead).

## 2. Configure

```bash
workflow/skills/project-init/init.sh configure --name "<name>" --slug <slug> [--host <alias>] [--workdir <path>]
```

This sets `project.yaml` (identity, template version and commit, remote), writes `README.md` and `docs/CURRENT.md` (only where they are missing or still template placeholders; an existing project's README is kept), sets the `research/PROPOSAL.md` heading, moves `meta/status.yaml` to `phase: bootstrap`, and installs skill links.

## 3. Draft the research entry points with the researcher

- `research/PROPOSAL.md`: fill in only what the researcher stated. Put everything unknown under *Open questions*. Never infer scientific semantics.
- List the open questions that need a researcher decision. Grill (`/grill-with-docs`) only for questions the repository cannot answer that affect direction, evaluation semantics or a trade-off; record outcomes with `record-decision`.
- Do not create `research/PROTOCOL.md` unless the semantics are already stable (format: `workflow/templates/protocol.md`).
- If the goal is clear enough, write the first plan in `plans/active/<name>.md` (format: `workflow/templates/plan.md`) and set `active_plan`. Otherwise leave `active_plan: null`.
- Update `meta/status.yaml` (`current_objective`, `artifacts.proposal.status: draft`, `next_action`) and `docs/CURRENT.md` together.

## 4. Check the environment (only if remote compute is needed now)

Confirm the `Monitor` tool is available, then run `scripts/remote check` and `scripts/remote status`. Report problems as they are; an unreachable host does not block initialization.

## 5. Finalize

```bash
workflow/skills/project-init/init.sh finalize
```

This deletes `workflow/skills/project-init/`, prunes its `.claude/skills/` link and runs `scripts/check-workflow.sh`, which must pass. Then commit (`Initialize <name> with research workflow template v<version>`) and push to `origin`. If there is no remote yet or the push fails, say so.

## Done when

A new agent can answer the readiness questions in `workflow/WORKFLOW.md` §14 from `AGENTS.md` and `docs/CURRENT.md` alone.
