# Skill Provenance

## Vendored from `mattpocock/skills`

- Repository: `https://github.com/mattpocock/skills`
- Commit: `d81f3a183412e71a5b1e84ca21bc1a35eea03a60` (resolved from `main` on 2026-10-02)
- License: MIT; see [LICENSE.mattpocock-skills](LICENSE.mattpocock-skills), copied from upstream `LICENSE`

| Local skill | Upstream path | Local changes |
| --- | --- | --- |
| `grilling` | `skills/productivity/grilling/SKILL.md` | None |
| `domain-modeling` | `skills/engineering/domain-modeling/SKILL.md` | Description rewritten for research semantics; project rules first (Protocol and `research/decisions/` instead of `GLOSSARY.md` and `docs/adr/`); examples changed to research terms; decisions delegated to `record-decision`; upstream file-structure section reduced to an "only on explicit request" note |
| `grill-with-docs` | `skills/engineering/grill-with-docs/SKILL.md` | Description no longer advertises ADRs or a glossary; multi-harness fallback removed (Claude Code only); project destination rules |

`GLOSSARY-FORMAT.md` and `ADR-FORMAT.md` are unchanged copies from `skills/engineering/domain-modeling/` at the same commit; they are used only when the user explicitly asks for those upstream artifacts.

To update: copy the new upstream files at a pinned commit, re-apply the local changes above, update the commit here and in `workflow/lock.yaml`, and note it in `workflow/CHANGELOG.md`.

## Local skills

| Skill | Origin | Notes |
| --- | --- | --- |
| `resmon` | The researcher's own `monitor-machines` tool, copied 2026-11-02 and renamed | `resmon.sh` unchanged. `SKILL.md`: name and headings renamed; the test reference now explains that upstream `tests/run.sh` is not vendored. The separate `README.md` was dropped (it duplicated `SKILL.md`). Update by copying the new version over `workflow/skills/resmon/` and recording the date here |
| `remote-run`, `research-review`, `record-decision`, `project-init` | Written for this template (workflow 0.4.0, updated 0.5.0) | Procedures extracted from the former `init.md`, `AGENTS.md` and `docs/REMOTE-COMPUTE.md` |

## Discovery basis

- Agent Skills specification: `https://agentskills.io/specification`
- Claude Code skills: `https://code.claude.com/docs/en/skills` (project skills in `.claude/skills/<skill>/SKILL.md`; symlinked skill folders are supported)
