# Workflow Changelog

Template-level changes. Projects read this when merging template updates (see `workflow/WORKFLOW.md` §2). Entries marked **Action** need project-side work after the merge.

## 0.6.0 — 2026-11-02

First public release as `research-init` (MIT).

- README: agent instructions, so "see https://github.com/Yiyi-philosophy/research-init and initialize the current project" works from any project; manual steps use the public HTTPS URL.
- `remote.host` has no default any more: set it per project (`init.sh configure --host`); `scripts/remote` refuses to run without it. The host-specific "Known hosts" notes were replaced by generic host requirements.
- `workflow/lock.yaml` records the template repository URL.
- **Action (projects on 0.5.0 or earlier):** set `remote.host` in `project.yaml` if the project uses remote compute (it previously defaulted to a specific host).

## 0.5.0 — 2026-11-02

Copy-based install and update.

- New `scripts/install-workflow.sh <dir>`: installs the workflow into a new or existing project from a clone of the template (for example in `/tmp`), never overwriting files; creates a git repository if there is none; appends missing `.gitignore` rules; records `template.version` / `template.commit`. `--update <dir>` refreshes template-owned files of an existing project. The script and its test stay in the template repository.
- Upgrades use `--update` instead of `git merge template/main`: `.gitattributes` (`merge=ours`) and `init.sh configure --origin` were removed.
- `init.sh configure` keeps an existing `README.md` / `docs/CURRENT.md` and keeps the template commit recorded by the installer.
- **Action (projects on 0.4.0):** delete `.gitattributes` and the local `merge.ours.driver` git setting if you do not use them otherwise; remove the `template` git remote if it was only used for upgrades.

## 0.4.0 — 2026-11-02

The repository becomes a reusable template: clone it, run `/project-init`, research.

- **Template/project split.** Ownership table in `WORKFLOW.md` §2; project-owned paths marked `merge=ours` in `.gitattributes`; project identity and deployment config moved to `project.yaml`.
- **One-time bootstrap.** New user-invoked skill `project-init` (with `init.sh configure` / `finalize`) replaces the bootstrap part of `init.md` and deletes itself when done.
- **Docs restructured and translated to English.** `init.md` → `workflow/WORKFLOW.md` (stable spec); `grill-setup.md` → `workflow/skills/README.md`; `workflow-lock.yaml` → `workflow/lock.yaml`; `AGENTS.md` cut to routing and hard rules. The language rule is now English-only.
- **Procedures moved into skills.** New skills `remote-run` (job launch and supervision), `research-review` (formal/closure reviews), `record-decision` (decision records, Protocol amendments). Fill-in formats in `workflow/templates/`.
- **Vendored skills aligned with project rules.** `domain-modeling` and `grill-with-docs` descriptions no longer advertise ADRs or `GLOSSARY.md`; the multi-harness fallback was removed.
- **Remote compute generalized.** `scripts/d-nv` → `scripts/remote`, host and paths read from `project.yaml`. Prefix `fe`/`FE` → `rw`/`RW`: markers `__RW_*__`, env `RW_RUN_ID`, stamp `.rw-sync`, config overrides `RW_*` (were `DNV_*`). Per-project namespace on a shared host: code mirror `~/<slug>`, runs `~/rw-runs/<slug>/<run_id>/`, tmux sessions `rw-<slug>-<run_id>`. Commands that touch the namespace refuse to run until `project.slug` is set.
- **Checks.** New `scripts/check-workflow.sh` (identity/phase, status references, review and decision file names, skill front matter and links, relative Markdown links) and `tests/run.sh`. `.gitignore` added (`/output/`). Skill links in `.claude/skills/` are committed; the installer discovers skills automatically and prunes links to removed skills.
- **Action (projects created from 0.3):** move `DNV_*` environment variables to `RW_*`, rename the remote runs and workdir to the new layout or set `remote.workdir` / `remote.runs_root` in `project.yaml`, and update watch patterns from `__FE_` to `__RW_`.

## 0.3 — 2026-11-02

Inherited from the project this template was extracted from (rationale recorded there in `meta/workflow-friction.md`).

- Claude Code is the only supported harness; `.agents/skills/` and the Codex `agents/openai.yaml` were removed (other harnesses lack the `Monitor` tool that remote supervision needs).
- The parallel research worker pipeline (`run-research-worker(s)`, worker task/result schemas) was paused: infrastructure had arrived before any real need.
- Remote compute via a single adapter script (tmux + log + exit markers), with every long job supervised by a background `Monitor`.
- Code sync to the remote host by `rsync -c --delete-after` of the working tree instead of git push/pull; provenance by a `commit` / `dirty` / `tree` fingerprint stamped into each run.
- Fixed output directories `results/` and `output/`, pulled back automatically when a watched job ends.
- `resmon` resource supervision (the researcher's own `monitor-machines` tool) started automatically for each job.
- Formal reviews in `research/reviews/<artifact>/` with immutable, round-numbered records.

## 0.2 and earlier

- 0.2: bootstrap of the minimal research entry points (Proposal, status, current view, active plan).
- 0.1: `grilling`, `domain-modeling` and `grill-with-docs` vendored from `mattpocock/skills` (historical baseline tag `workflow-grill-v0.1` in the originating project).
