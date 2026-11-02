#!/usr/bin/env bash
# One-time initialization of a project cloned from the research workflow template.
#   init.sh configure --name NAME --slug SLUG [--host ALIAS] [--workdir PATH]
#   init.sh finalize        # delete this skill, prune its link, run the workflow checks
set -euo pipefail

skill_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$skill_dir/../../.." && pwd -P)"
cd "$repo_root"
# shellcheck source=../../../scripts/lib/project-config.sh
source scripts/lib/project-config.sh

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-2}"; }
status_phase() { awk '/^phase:/ { sub(/^phase:[ \t]*/, ""); sub(/[ \t]+#.*$/, ""); print; exit }' meta/status.yaml; }
# set_top FILE KEY VALUE: replace a top-level scalar, keeping its trailing comment.
set_top() {
  local tmp; tmp="$(mktemp)"
  awk -v key="$2" -v val="$3" '
    $0 ~ "^" key ":" && !done { c = ""; if (match($0, /[ \t]+#.*$/)) c = substr($0, RSTART); print key ": " val c; done = 1; next }
    { print }' "$1" > "$tmp" && cat "$tmp" > "$1"; rm -f -- "$tmp"
}

configure() {
  local name="" slug="" host="" workdir=""
  while (($#)); do
    case "$1" in
      --name) name="${2:-}"; shift 2 ;;
      --slug) slug="${2:-}"; shift 2 ;;
      --host) host="${2:-}"; shift 2 ;;
      --workdir) workdir="${2:-}"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [[ -n "$name" ]] || die "--name is required"
  [[ "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "--slug must match [a-z0-9][a-z0-9-]*: '$slug'"
  [[ -z "$(project_config_get project.yaml project slug)" && "$(status_phase)" == template ]] ||
    die "this repository is already initialized (project.slug is set or phase is not template)" 1

  local version commit today
  version="$(awk '/^  version:/ { gsub(/"/, "", $2); print $2; exit }' workflow/lock.yaml)"
  # scripts/install-workflow.sh records the template commit; a direct clone of the template uses its own HEAD.
  commit="$(project_config_get project.yaml template commit)"
  [[ -n "$commit" ]] || commit="$(git rev-parse --short=12 HEAD 2>/dev/null || echo null)"
  today="$(date +%Y-%m-%d)"

  project_config_set project.yaml project name "\"$name\""
  project_config_set project.yaml project slug "$slug"
  project_config_set project.yaml template version "\"$version\""
  project_config_set project.yaml template commit "$commit"
  [[ -z "$host" ]] || project_config_set project.yaml remote host "$host"
  [[ -z "$workdir" ]] || project_config_set project.yaml remote workdir "$workdir"

  set_top meta/status.yaml phase bootstrap
  set_top meta/status.yaml next_action define_research_proposal

  # Project files are (re)written only while they are missing or still the template placeholder,
  # so an existing project's README is kept.
  replaceable() { [[ ! -s "$1" ]] || grep -q 'rw:template' "$1"; }

  replaceable README.md && cat > README.md <<README
# $name

Research project created from the research workflow template (v$version, $today).

- Current state: [docs/CURRENT.md](docs/CURRENT.md)
- Agent rules: [AGENTS.md](AGENTS.md)
- Workflow specification: [workflow/WORKFLOW.md](workflow/WORKFLOW.md)
- Remote compute: [docs/REMOTE-COMPUTE.md](docs/REMOTE-COMPUTE.md)
README
  grep -q 'docs/CURRENT.md' README.md || printf 'note: README.md was kept; consider linking docs/CURRENT.md and AGENTS.md from it\n'

  replaceable docs/CURRENT.md && cat > docs/CURRENT.md <<CURRENT
# Current State

## Project

**$name** (\`$slug\`), initialized $today from workflow template v$version. The research goal is not yet recorded.

## Authoritative sources

- Machine-readable state: \`meta/status.yaml\` (this file is its view; update both together)
- Proposal: \`research/PROPOSAL.md\` (not started)
- Protocol: \`research/PROTOCOL.md\` (not started)
- Decisions: \`research/decisions/\` (none)
- Active plan: none
- Evidence: none

## Phase

\`bootstrap\`: project entry points are being set up.

## Next

1. Record the research question, hypotheses, success criteria and constraints in \`research/PROPOSAL.md\` with the researcher.
2. Create or freeze \`research/PROTOCOL.md\` only when the semantics are stable and an experiment needs them.
3. Run experiments only after the first plan exists in \`plans/active/\`.
CURRENT

  local tmp; tmp="$(mktemp)"
  awk -v title="# Research Proposal — $name" '/rw:template/ { next } /^# Research Proposal$/ { print title; next } { print }' \
    research/PROPOSAL.md > "$tmp" && cat "$tmp" > research/PROPOSAL.md; rm -f -- "$tmp"

  scripts/install-agent-skills.sh >/dev/null
  printf 'configured %s (%s) from template v%s at %s\n' "$name" "$slug" "$version" "$commit"
  printf 'next: draft research/PROPOSAL.md with the researcher, then: %s finalize\n' "${skill_dir#"$repo_root"/}/init.sh"
}

finalize() {
  [[ -n "$(project_config_get project.yaml project slug)" && "$(status_phase)" != template ]] ||
    die "run configure first" 1
  rm -rf -- "$skill_dir"
  scripts/install-agent-skills.sh >/dev/null
  printf 'removed workflow/skills/project-init\n'
  scripts/check-workflow.sh
}

case "${1:-}" in
  configure) shift; configure "$@" ;;
  finalize) shift; finalize ;;
  *) printf 'usage: %s configure --name NAME --slug SLUG [--host ALIAS] [--workdir PATH]\n       %s finalize\n' "$0" "$0" >&2; exit 2 ;;
esac
