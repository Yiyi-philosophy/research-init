# Skills

`workflow/skills/` is the only source of skills for this repository. Claude Code discovers them through symlinks in `.claude/skills/`, created by `scripts/install-agent-skills.sh` and committed with the repository.

| Skill | Source | Invocation | Use it to |
| --- | --- | --- | --- |
| `project-init` | local | user only: `/project-init` | Turn a fresh template clone into a project; deletes itself when done |
| `remote-run` | local | automatic | Launch and supervise long jobs on the remote host (`scripts/remote` + Monitor `watch` + `resmon`) |
| `resmon` | researcher's own tool | automatic | Background resource guard for one job; used by `remote-run` |
| `research-review` | local | automatic or `/research-review` | Write formal and closure reviews in `research/reviews/<artifact>/` |
| `record-decision` | local | automatic or `/record-decision` | Record or supersede a researcher decision, amend a frozen Protocol |
| `grill-with-docs` | vendored, modified | user only: `/grill-with-docs` | Interview the researcher and record outcomes as they resolve |
| `grilling` | vendored | automatic or `/grilling` | Stress-test a plan or decision in rounds |
| `domain-modeling` | vendored, modified | automatic or `/domain-modeling` | Sharpen research terminology and semantics into the Protocol |

Vendored provenance, pinned commit and local changes: [UPSTREAM.md](UPSTREAM.md).

## Conventions

- One directory per skill. `SKILL.md` starts with YAML front matter: `name` (equal to the directory name) and `description` (what the skill does and when to use it; this is what triggers it).
- Set `disable-model-invocation: true` for skills with one-time or hard-to-reverse effects, so only the user can start them.
- Keep procedures in skills and stable rules in `workflow/WORKFLOW.md`; link instead of copying. Shared fill-in formats live in `workflow/templates/`.
- Scripts a skill owns live in its directory; their tests go in `<skill>/tests/test-*.sh`, which `tests/run.sh` runs.
- Vendored skills keep local changes minimal, and every change is listed in `UPSTREAM.md`.
- Write skills in English.

## Editing

1. Edit or add files under `workflow/skills/<skill>/`, never through `.claude/skills/`.
2. Run `scripts/install-agent-skills.sh`. It links new skills, prunes links to removed ones, and never touches unknown entries.
3. Run `scripts/check-workflow.sh`. It verifies front matter and links.
4. A change that applies to every project goes into the template repository and `workflow/CHANGELOG.md`.
