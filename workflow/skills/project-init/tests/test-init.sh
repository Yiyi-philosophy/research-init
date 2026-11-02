#!/usr/bin/env bash
# End-to-end: copy the template into a scratch git repo, configure, finalize, and check the result.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd -P)"
tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

proj="$tmp/proj"
rsync -a --exclude=/.git/ --exclude=/output/ "$repo_root/" "$proj/"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git -C "$proj" init -q && git -C "$proj" add -A && git -C "$proj" commit -qm template
init="$proj/workflow/skills/project-init/init.sh"

"$proj/scripts/check-workflow.sh" >/dev/null || fail "template state does not pass the checks"
if "$init" configure --name X --slug 'Bad Slug' >/dev/null 2>&1; then fail "invalid slug accepted"; fi
if "$init" finalize >/dev/null 2>&1; then fail "finalize ran before configure"; fi

"$init" configure --name "Demo Project" --slug demo --host gpu-box >/dev/null
source "$proj/scripts/lib/project-config.sh"
[[ "$(project_config_get "$proj/project.yaml" project name)" == "Demo Project" ]] || fail "project.name not set"
[[ "$(project_config_get "$proj/project.yaml" project slug)" == demo ]] || fail "project.slug not set"
[[ "$(project_config_get "$proj/project.yaml" remote host)" == gpu-box ]] || fail "remote.host not set"
[[ "$(project_config_get "$proj/project.yaml" template commit)" =~ ^[0-9a-f]{12}$ ]] || fail "template.commit not recorded"
grep -q '^phase: bootstrap' "$proj/meta/status.yaml" || fail "phase not bootstrap"
grep -rq 'rw:template' "$proj/README.md" "$proj/docs/CURRENT.md" "$proj/research/PROPOSAL.md" && fail "template marker left behind"
grep -q '^# Research Proposal — Demo Project$' "$proj/research/PROPOSAL.md" || fail "proposal heading not set"
out="$("$proj/scripts/check-workflow.sh")" || fail "checks fail after configure: $out"
grep -q 'bootstrap not finalized' <<<"$out" || fail "missing finalize warning"
if "$init" configure --name Again --slug again >/dev/null 2>&1; then fail "configure ran twice"; fi
RW_SSH=false "$proj/scripts/remote" sync --dry-run 2>&1 | grep -q 'project.slug is not set' &&
  fail "remote still thinks the project is uninitialized"

out="$("$init" finalize)" || fail "finalize failed: $out"
[[ ! -e "$proj/workflow/skills/project-init" ]] || fail "skill not removed"
[[ ! -L "$proj/.claude/skills/project-init" ]] || fail "skill link not pruned"
grep -q '0 warning(s) \[mode: project\]' <<<"$out" || fail "unexpected check result: $out"

printf 'ok: project-init tests\n'
