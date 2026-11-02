# Research Workflow

The stable specification of this research workflow template: what the research objects are, where each one lives, and the invariants agents must keep. Procedures live in skills (`workflow/skills/`), fill-in formats in `workflow/templates/`. Read this file when a task touches workflow rules; the always-loaded summary is `AGENTS.md`.

The workflow serves the research, not the other way round. Add structure only when a real need appears.

## 1. Principles

- **Minimal context.** A new agent reads `AGENTS.md` and `docs/CURRENT.md`, then only what the task needs.
- **Explicit decisions.** Choices the repository cannot answer are made by the researcher and written down, never left in chat.
- **Frozen scientific semantics, mutable plans.** What counts as a valid result is fixed before the result is seen; how the work gets done can change freely.
- **Evidence-backed gates.** Progress claims rest on produced, verifiable results.
- **Single current state.** Exactly one machine-readable place says where the project is.
- **The researcher owns scientific judgment; agents own information hygiene, state sync and traceability.**

### Language

- All documentation is written in English.
- File and directory names, schema fields, config keys, code and commands are English identifiers.
- Flowcharts go in fenced `text` code blocks.

## 2. Template and project

This repository is a template. A project gets the workflow by running `scripts/install-workflow.sh <project-dir>` from a clone of the template (new or existing directory), then `/project-init` once in the project; the skill configures `project.yaml`, writes the project's state files and then deletes itself. Quick start: `README.md` of the template.

| Owner | Paths | Changes come from |
| --- | --- | --- |
| Template | `AGENTS.md`, `workflow/**`, `docs/REMOTE-COMPUTE.md`, `scripts/**`, `tests/**`, `.claude/skills/` links | the template repository |
| Project | `README.md`, `project.yaml`, `docs/CURRENT.md`, `meta/**`, `research/**`, `plans/**`, `experiments/**`, `evidence/**`, `results/**`, everything else | the project itself |

The installer only creates project-owned files that are missing, and appends the template's `.gitignore` rules to the project's. The template's own `README.md` and `LICENSE`, `scripts/install-workflow.sh` and its test stay in the template repository. Do not customize template-owned files inside a project: the next update replaces them.

### Upgrading a project from the template

```bash
git clone --depth 1 https://github.com/Yiyi-philosophy/research-init.git /tmp/research-init
/tmp/research-init/scripts/install-workflow.sh --update <project-dir>
```

- `--update` replaces template-owned files, never touches project-owned ones, does not bring `project-init` back into an initialized project, and records the new `template.version` / `template.commit` in `project.yaml`.
- It does not delete files the template removed; `workflow/CHANGELOG.md` lists those under **Action**.
- Then read the changelog, run `tests/run.sh` in the project, and commit.

Improvements that are not project-specific belong in the template repository, not in a project fork.

## 3. Lifecycle

Default lifecycle. Not every task runs every step:

```text
Idea
  ↓
Repository Search / Triage
  ↓
Human Decision Needed?
  ├── No → Continue
  └── Yes → Grill
               ↓
            Decision
               ↓
            Protocol
               ↓
             Review
               ↓
     Artifact-specific next transition
               ↓
              Plan
               ↓
         Implementation
               ↓
              Run
               ↓
            Evidence
               ↓
              Gate
               ↓
             Status
```

Simple tasks take the shortest valid path:

```text
Bug → Fix → Test → Evidence
```

Add `Grill`, `Decision`, `Review` or a new `Protocol` only when the task involves an important research judgment, a change of scientific semantics, or an irreversible design choice.

## 4. Research objects

| Object | Lives in | What it is | Key rule |
| --- | --- | --- | --- |
| Proposal | `research/PROPOSAL.md` | Why the research exists: question, motivation, candidate directions, success criteria, constraints, data boundary, resources | May change freely during exploration |
| Decision | `research/decisions/NNNN-<slug>.md` | A choice the repository cannot answer that the researcher made, and why | Accepted decisions are superseded, never edited away (skill: `record-decision`) |
| Protocol | `research/PROTOCOL.md` (format: `workflow/templates/protocol.md`) | What makes an experiment valid and what results can support a claim: hypothesis, data boundary, metric, baseline, control, failure criteria, evaluation semantics | Once `Frozen`, never silently modified |
| Plan | `plans/active/`, then `plans/archive/` | How the work will be done now | May change often, but cannot change a frozen Protocol |
| Run | remote job `run_id`; manifest in `experiments/<run_id>.yaml` | One real execution | Traceable to Protocol, code, data, config, environment, artifacts |
| Evidence | `results/`, `evidence/`, referenced from `meta/status.yaml` | Real, verifiable outputs: metrics, logs, predictions, checkpoints, hashes, validation reports | "The code is implemented" is not scientific evidence |
| Review | `research/reviews/<artifact>/` | An immutable governance record of an independent check | Not Evidence, not a Decision (skill: `research-review`) |
| Gate | recorded in Plan / status | Whether the current stage may proceed, judged from Evidence | `PASS / PARTIAL / BLOCKED / NOT_EVALUATED` |
| Status | `meta/status.yaml` + `docs/CURRENT.md` | Where the project really is | The only place that holds current state |

### Gate and claim vocabulary

- Gates: `PASS`, `PARTIAL`, `BLOCKED`, `NOT_EVALUATED`. Never convert `unknown → failed` or `not evaluated → negative result`.
- Claims about work are distinct and must not be conflated: `Implemented`, `Tested`, `Experimentally Evaluated`, `Scientifically Supported`.

### Experiment manifests

Introduce `experiments/<run_id>.yaml` (format: `workflow/templates/experiment.yaml`) when the first important experiment appears, not before. Do not build an experiment platform on day one.

## 5. Sources of truth

| Information | Authoritative location |
| --- | --- |
| Project identity, deployment config | `project.yaml` |
| Current state (machine-readable SSOT) | `meta/status.yaml` |
| Current state (human-readable view) | `docs/CURRENT.md` |
| Scientific contract | `research/PROTOCOL.md` |
| Human decisions | `research/decisions/` |
| Current work | `plans/active/` |
| Execution facts | `experiments/`, `results/`, `evidence/` |
| Review governance | `research/reviews/` |
| Code history | Git |
| Remote compute | `docs/REMOTE-COMPUTE.md`, `scripts/remote`, skill `remote-run` |
| Workflow version and pins | `workflow/lock.yaml`, `workflow/CHANGELOG.md` |

Rules:

- Only `meta/status.yaml` and `docs/CURRENT.md` describe "where we are". `AGENTS.md`, `README.md` and `PROPOSAL.md` point to `docs/CURRENT.md` instead of keeping their own status.
- Update `meta/status.yaml` and `docs/CURRENT.md` in the same change.
- Do not create a parallel ADR, glossary or status system.
- Create directories lazily, when there is something to put in them.

### `meta/status.yaml` vocabulary

- `phase`: `template` (uninitialized) → `bootstrap` → `exploration` → `experimentation` → `closed`. Only `template` and `bootstrap` are interpreted by scripts.
- `artifacts.proposal.status`: `not_started | draft | accepted`.
- `artifacts.protocol.status`: `not_started | draft | frozen | superseded`.
- `artifacts.*.review.status`: `NOT_STARTED`, `IN_REVIEW`, or the latest review outcome.
- `active_plan`: a path under `plans/active/`, or `null`.
- `evidence`: list of paths to verified evidence.

`scripts/check-workflow.sh` validates these references.

## 6. Context routing and Grill

```text
AGENTS.md
   ↓
docs/CURRENT.md
   ↓
Active Protocol / Plan
   ↓
Relevant Decisions
   ↓
Evidence / History on demand
```

Never load whole history directories by default.

**Search the repository before asking a person.** Grill (`/grill-with-docs`) only when an open question meets both of these conditions:

1. The repository cannot answer it.
2. It affects at least one of: research direction, evaluation semantics, a frozen contract, or a trade-off only the researcher can make.

Good Grill questions: *Which objective has priority? What result would falsify the hypothesis? Can this information enter the next iteration? Can the evaluation protocol change after observing results?*

Not Grill questions: *How should this parser be implemented? Why did this test fail? Which API should be used?*

Stable Grill outcomes go into `research/decisions/` or the Protocol, the moment they are resolved.

## 7. Protocol freeze and amendment

A Protocol may stay `Draft` during exploration. Freeze it only when an experiment needs stable semantics, and only after:

- the hypothesis is explicit;
- evaluation is explicit;
- the data boundary is explicit;
- success and failure semantics are explicit;
- the main unresolved decisions are closed.

After freezing:

```text
Implementation may change.
Protocol semantics may not silently change.
```

Changing a frozen Protocol:

```text
Protocol v1 → Decision (amendment) → Protocol v2
```

Never overwrite the previous version: keep it (for example `research/protocol-history/PROTOCOL-v1.md`) and record the version in the new Protocol's header.

## 8. Plans

- `plans/active/` holds only plans that are currently valid.
- When a plan is completed or replaced, move it to `plans/archive/` with a one-line outcome at the top, and update `active_plan`.
- Format: `workflow/templates/plan.md`.

## 9. Reviews

Independent roles may be used: Research Reviewer, Implementation Agent, Closure Agent. A reviewer checks for frozen-contract violations, changed scientific semantics, scope creep, authority conflicts, claims unsupported by evidence, and missing reproducibility information. Prefer the **smallest compatible fix** over redesign.

```text
Formal Review → Smallest Compatible Fix → Closure Review → Artifact-specific next transition
```

| Artifact | Transition after closure |
| --- | --- |
| Proposal | Grill / Decision |
| Protocol | Freeze |
| Experiment | Gate / Status |
| Evidence | Gate / Status |

Severity: `BLOCKER / IMPORTANT / MINOR / REJECTED`. Outcome: `READY_FOR_GRILL / READY_AFTER_CHANGES / BLOCKED` (other explicit outcomes allowed; never mix severity and outcome). File naming, front matter and the closure procedure: skill `research-review`.

## 10. Evidence and history

- Evidence from a remote run is cited with its `run_id`, host and the `commit` / `dirty` / `tree` stamp from `__RW_START__`. A `dirty=yes` result is either reproduced on committed code later or flagged as such in the Evidence.
- If GPUs, data, the environment or a service (including the remote host) is unavailable now, write `Current reproduction unavailable`. Never downgrade existing historical evidence to `Unverified`.
- History is handled by **append, version, supersede, archive**, never by silent rewrite.
- Git holds code history. Evidence holds research facts. Decisions hold why the direction changed.

## 11. Remote compute

Long jobs (about 2 minutes or more, or anything that must outlive the session) run on the remote host via `scripts/remote`, supervised by two background channels: `watch` (job progress, errors, exit) and `resmon` (machine and process resources). Procedure: skill `remote-run`. Configuration and script behavior: `docs/REMOTE-COMPUTE.md`. Host names, ports and paths are deployment config in `project.yaml`; they never enter Protocol, Decision or Evidence semantics.

## 12. Skills

Canonical skill sources live in `workflow/skills/`, linked into `.claude/skills/` by `scripts/install-agent-skills.sh`. Index, invocation modes and editing rules: `workflow/skills/README.md`.

## 13. Evaluating the workflow

This workflow is iterable infrastructure, not a constitution. Record real friction in `meta/workflow-friction.md` (format: `workflow/templates/friction-entry.md`). Watch for:

- agents repeatedly re-reading old documents;
- current state maintained in more than one place;
- questions that were already answered being asked again;
- documents nobody uses;
- reviews that are too heavy;
- information that should be machine-readable;
- workflow rules that a strong model no longer needs.

Keep a workflow component only if it improves at least one of: research quality, reproducibility, agent correctness, context efficiency, decision traceability, iteration speed, handoff quality. Friction that applies to every project should be fixed in the template and recorded in `workflow/CHANGELOG.md`.

## 14. Readiness test

After bootstrap, a new agent should answer these quickly from `AGENTS.md` and `docs/CURRENT.md` plus at most a few linked files:

```text
What is the project?
What is the current objective?
What is authoritative?
What has been decided?
What remains unknown?
Is the protocol draft or frozen?
What is the active plan?
What evidence exists?
What happens next?
```

If answering needs many unrelated files, the documentation is too heavy and should be simplified.
