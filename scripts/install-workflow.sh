#!/usr/bin/env bash
# Install this research workflow template into a project directory, or update one.
#
#   install-workflow.sh <target-dir>            new or existing project: add the workflow, never overwrite files
#   install-workflow.sh --update <target-dir>   refresh template-owned files; project-owned files are never touched
#
# Run it from a clone of the template (e.g. /tmp/research-init/scripts/install-workflow.sh ~/my-project).
# This script and its test stay in the template repository; they are not copied into projects.
set -euo pipefail

src="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/project-config.sh
source "$src/scripts/lib/project-config.sh"

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-2}"; }
usage() { sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

update=0
case "${1:-}" in
  --update) update=1; shift ;;
  -h|--help|"") usage; exit 0 ;;
esac
(($# == 1)) || { usage >&2; exit 2; }
target="$1"

git -C "$src" rev-parse --git-dir >/dev/null 2>&1 || die "run this from a git clone of the template: $src"
version="$(awk '/^  version:/ { gsub(/"/, "", $2); print $2; exit }' "$src/workflow/lock.yaml")"
commit="$(git -C "$src" rev-parse --short=12 HEAD)"
[[ -z "$(git -C "$src" status --porcelain)" ]] || printf 'warning: template clone has uncommitted changes; recording commit %s anyway\n' "$commit" >&2

mkdir -p -- "$target"
target="$(cd -- "$target" && pwd -P)"
[[ "$target" != "$src" ]] || die "target is the template clone itself"
if ((update)); then
  [[ -f "$target/project.yaml" && -f "$target/workflow/lock.yaml" ]] || die "--update needs a project that already has the workflow: $target"
fi

# Ownership. Template-owned paths are replaced on --update; project-owned skeleton files are only ever created.
# Template-only: the template's own README and LICENSE, the installer and its test.
is_template_only() { case "$1" in README.md|LICENSE|scripts/install-workflow.sh|tests/test-install-workflow.sh) return 0 ;; esac; return 1; }
is_template_owned() {
  case "$1" in
    AGENTS.md|docs/REMOTE-COMPUTE.md|workflow/*|scripts/*|tests/*) return 0 ;;
  esac
  return 1
}
is_skeleton() {
  case "$1" in
    project.yaml|docs/CURRENT.md|meta/status.yaml|meta/workflow-friction.md|research/PROPOSAL.md) return 0 ;;
  esac
  return 1
}

slug="$(project_config_get "$target/project.yaml" project slug)"
added=() updated=() skipped=()
copy() { mkdir -p -- "$(dirname -- "$target/$1")"; cp -p -- "$src/$1" "$target/$1"; }

while IFS= read -r -d '' f; do
  is_template_only "$f" && continue
  # project-init only goes into projects that have not been initialized yet
  [[ "$f" == workflow/skills/project-init/* && -n "$slug" ]] && continue
  if is_template_owned "$f"; then
    if [[ ! -e "$target/$f" ]]; then copy "$f"; added+=("$f")
    elif cmp -s -- "$src/$f" "$target/$f"; then :
    elif ((update)); then copy "$f"; updated+=("$f")
    else skipped+=("$f")
    fi
  elif is_skeleton "$f"; then
    if [[ ! -e "$target/$f" ]]; then copy "$f"; added+=("$f")
    elif ((!update)) && ! cmp -s -- "$src/$f" "$target/$f"; then skipped+=("$f")
    fi
  fi
done < <(git -C "$src" ls-files -z)

# README: a placeholder that /project-init replaces; an existing README is kept.
if [[ ! -e "$target/README.md" ]]; then
  printf '<!-- rw:template: replaced by /project-init -->\n# New research project\n\nRun /project-init in Claude Code to set up this project (see AGENTS.md).\n' > "$target/README.md"
  added+=(README.md)
fi

# .gitignore: append the template's rules that the project does not have yet.
touch "$target/.gitignore"
missing="$(grep -vE '^[[:space:]]*(#|$)' "$src/.gitignore" | while IFS= read -r rule; do
  grep -qxF -- "$rule" "$target/.gitignore" || printf '%s\n' "$rule"; done)"
if [[ -n "$missing" ]]; then
  { [[ ! -s "$target/.gitignore" ]] || printf '\n# research workflow template\n'; printf '%s\n' "$missing"; } >> "$target/.gitignore"
  printf 'appended to .gitignore: %s\n' "$(printf '%s' "$missing" | tr '\n' ' ')"
fi

"$target/scripts/install-agent-skills.sh" >/dev/null

# Record which template version and commit the project now follows.
if project_config_set "$target/project.yaml" template version "\"$version\"" 2>/dev/null &&
   project_config_set "$target/project.yaml" template commit "$commit" 2>/dev/null; then :
else
  printf 'warning: project.yaml has no template section; add template.version "%s" and template.commit %s by hand\n' "$version" "$commit" >&2
fi

if ! git -C "$target" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$target" init -q
  printf 'initialized a new git repository in %s\n' "$target"
fi

report() { local label="$1"; shift; (($#)) || return 0; printf '%s (%d):\n' "$label" "$#"; printf '  %s\n' "$@"; }
printf '%s workflow template v%s (%s) -> %s\n' "$( ((update)) && echo Updated || echo Installed)" "$version" "$commit" "$target"
printf 'added %d file(s)\n' "${#added[@]}"
report updated "${updated[@]+"${updated[@]}"}"
report "skipped, already exist with different content (merge by hand if needed)" "${skipped[@]+"${skipped[@]}"}"

if ((update)); then
  printf '\nnext: read %s/workflow/CHANGELOG.md for required actions, then run tests/run.sh and commit.\n' "$target"
elif [[ -z "$slug" ]]; then
  printf '\nnext: in Claude Code, run /project-init in %s\n' "$target"
  printf '      (an agent already in a session: read workflow/skills/project-init/SKILL.md there and follow it)\n'
fi
