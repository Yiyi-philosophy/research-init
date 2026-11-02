<!-- rw:template: replaced by /project-init -->
# research-init

A lightweight, agent-friendly research workflow for Claude Code. It keeps decisions, protocols, plans, runs, evidence and reviews traceable, and runs long jobs on a supervised remote host. Install it into any project, new or existing.

## Initialize a project with Claude Code

Open Claude Code in your project and say:

> See https://github.com/Yiyi-philosophy/research-init and initialize the current project.

Claude follows the [agent instructions](#agent-instructions) below. To do it by hand, follow the steps after that.

## Agent instructions

You are asked to initialize, or update, the current project with this workflow. Run the commands from the project's root directory.

1. Find the project root and check its state:

   ```bash
   git rev-parse --show-toplevel 2>/dev/null || pwd
   ```

   If `workflow/lock.yaml` already exists there, the workflow is installed: do an **update** (step 3, `--update`) instead of a new install, and skip step 5.

2. Clone this repository into a fresh temporary directory:

   ```bash
   tmp="$(mktemp -d)" && git clone --depth 1 https://github.com/Yiyi-philosophy/research-init.git "$tmp/research-init"
   ```

3. Install into the project root (new install), or update it:

   ```bash
   "$tmp/research-init/scripts/install-workflow.sh" .
   ```

   ```bash
   "$tmp/research-init/scripts/install-workflow.sh" --update .
   ```

   The installer never overwrites project files. Show the user the *skipped* list; existing files such as `AGENTS.md` or `README.md` are merged only with their agreement. If the project has a `CLAUDE.md`, make sure it imports the workflow rules with an `@AGENTS.md` line.

4. Remove the temporary clone:

   ```bash
   rm -rf "$tmp"
   ```

5. Read `workflow/skills/project-init/SKILL.md` in the project and follow it from step 1. Skills installed during a session may not be available as slash commands until the next session, so read the file instead of waiting for `/project-init`.

6. For an update: read `workflow/CHANGELOG.md` for required actions, run `tests/run.sh`, and commit.

## Manual steps: new project

1. Clone the template into a temporary directory:

   ```bash
   git clone --depth 1 https://github.com/Yiyi-philosophy/research-init.git /tmp/research-init
   ```

2. Install the workflow into your project directory. It is created if missing, and a git repository is initialized if there is none:

   ```bash
   /tmp/research-init/scripts/install-workflow.sh ~/projects/my-study
   ```

3. Open the project in Claude Code and run `/project-init`:

   ```bash
   cd ~/projects/my-study && claude
   ```

   It asks for the project name, slug, research goal and remote host, writes the project's config and state files, drafts the Proposal with you, commits, and then removes itself. Without Claude Code: `workflow/skills/project-init/init.sh configure --name "My Study" --slug my-study`, fill in `research/PROPOSAL.md`, then `workflow/skills/project-init/init.sh finalize`.

4. Push it to your project's repository:

   ```bash
   git remote add origin <your-repo-url> && git push -u origin HEAD
   ```

5. Remove the temporary clone:

   ```bash
   rm -rf /tmp/research-init
   ```

To pin a release, add `--branch vX.Y.Z` to the clone in step 1.

**Existing project:** same steps, pointing step 2 at the existing directory. Existing files are kept and listed as *skipped*, and the template's `.gitignore` rules are appended to yours.

**Update to a newer version:** clone again (step 1), then run `/tmp/research-init/scripts/install-workflow.sh --update ~/projects/my-study`. Only template-owned files (`AGENTS.md`, `workflow/`, `scripts/`, `tests/`, `docs/REMOTE-COMPUTE.md`) are replaced; research files are never touched. Then read `workflow/CHANGELOG.md`, run `tests/run.sh`, and commit.

## What a project gets

| Path | Owner | Purpose |
| --- | --- | --- |
| [AGENTS.md](AGENTS.md) | template | Rules loaded by the agent every session |
| [workflow/WORKFLOW.md](workflow/WORKFLOW.md) | template | Workflow specification: objects, sources of truth, invariants |
| [workflow/skills/](workflow/skills/README.md) | template | Skills (canonical source), linked into `.claude/skills/` |
| [workflow/templates/](workflow/templates) | template | Fill-in formats: decision, review, plan, protocol, experiment, friction entry |
| [docs/REMOTE-COMPUTE.md](docs/REMOTE-COMPUTE.md) | template | Remote host runbook for `scripts/remote` |
| `scripts/`, `tests/` | template | `remote`, `check-workflow.sh`, `install-agent-skills.sh`; `tests/run.sh` |
| [project.yaml](project.yaml) | project | Identity and deployment config |
| [docs/CURRENT.md](docs/CURRENT.md), [meta/status.yaml](meta/status.yaml) | project | Current state (view and SSOT) |
| `research/`, `plans/`, `results/` | project | Proposal, Protocol, decisions, reviews, plans, evidence |

## Requirements

Claude Code; `bash`, `git` and `rsync` locally. Remote compute is optional and needs an ssh-reachable Linux host with `tmux` ([details](docs/REMOTE-COMPUTE.md)).

## Developing the template

```bash
tests/run.sh
```

Runs `scripts/check-workflow.sh` and all script tests (the remote adapter test needs `tmux`). Record changes in [workflow/CHANGELOG.md](workflow/CHANGELOG.md), bump `workflow/lock.yaml`, and tag the release (`vX.Y.Z`).

## License

[MIT](LICENSE). The vendored skills from `mattpocock/skills` are MIT-licensed as well ([provenance](workflow/skills/UPSTREAM.md)).
