#!/usr/bin/env bash
# End-to-end: install from a clean template clone into a new and an existing project, initialize, then update.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# shellcheck source=../scripts/lib/project-config.sh
source "$repo_root/scripts/lib/project-config.sh"
cfg() { project_config_get "$1/project.yaml" "$2" "$3"; }

# A clean "clone" of the template as it is in this working tree.
src="$tmp/rw-template"
rsync -a --exclude=/.git/ --exclude=/output/ "$repo_root/" "$src/"
git -C "$src" init -q && git -C "$src" add -A && git -C "$src" commit -qm template
head="$(git -C "$src" rev-parse --short=12 HEAD)"
install="$src/scripts/install-workflow.sh"

# Refusals
if "$install" "$src" >/dev/null 2>&1; then fail "installed into the template itself"; fi
if "$install" --update "$tmp/empty" >/dev/null 2>&1; then fail "--update accepted a directory without the workflow"; fi

# 1. New project
new="$tmp/projects/new-study"
out="$("$install" "$new")" || fail "install failed: $out"
for f in AGENTS.md scripts/remote workflow/WORKFLOW.md workflow/skills/project-init/init.sh research/PROPOSAL.md meta/status.yaml; do
  [[ -f "$new/$f" ]] || fail "new install is missing $f"
done
[[ -x "$new/scripts/remote" && -x "$new/workflow/skills/project-init/init.sh" ]] || fail "executables lost their mode"
[[ ! -e "$new/scripts/install-workflow.sh" && ! -e "$new/tests/test-install-workflow.sh" && ! -e "$new/LICENSE" ]] || fail "template-only files were copied"
grep -q 'rw:template' "$new/README.md" || fail "placeholder README not written"
[[ -L "$new/.claude/skills/remote-run" ]] || fail "skill links not installed"
git -C "$new" rev-parse --git-dir >/dev/null 2>&1 || fail "no git repository created"
grep -qx '/output/' "$new/.gitignore" || fail ".gitignore not created"
[[ "$(cfg "$new" template commit)" == "$head" ]] || fail "template.commit not recorded"
grep -q 'project-init' <<<"$out" || fail "next steps not printed"
"$new/scripts/check-workflow.sh" >/dev/null || fail "new install does not pass the checks"

# 2. Initialize it
"$new/workflow/skills/project-init/init.sh" configure --name "New Study" --slug new-study >/dev/null
"$new/workflow/skills/project-init/init.sh" finalize >/dev/null || fail "finalize failed in the new project"
[[ "$(cfg "$new" template commit)" == "$head" ]] || fail "init overwrote the template commit"
grep -q '^# New Study$' "$new/README.md" || fail "project README not written"
(cd "$new" && tests/run.sh >/dev/null 2>&1) || fail "tests do not pass inside the new project"

# 3. Update it from a newer template commit
echo "<!-- template change -->" >> "$src/AGENTS.md"
git -C "$src" commit -qam "template change"
head2="$(git -C "$src" rev-parse --short=12 HEAD)"
echo "project content" >> "$new/research/PROPOSAL.md"
echo "local edit" >> "$new/scripts/remote"
out="$("$install" --update "$new")" || fail "update failed: $out"
cmp -s "$src/AGENTS.md" "$new/AGENTS.md" || fail "update did not refresh AGENTS.md"
cmp -s "$src/scripts/remote" "$new/scripts/remote" || fail "update did not restore scripts/remote"
grep -q 'project content' "$new/research/PROPOSAL.md" || fail "update touched project-owned files"
[[ ! -e "$new/workflow/skills/project-init" ]] || fail "update brought project-init back"
[[ "$(cfg "$new" template commit)" == "$head2" ]] || fail "update did not record the new template commit"
[[ "$(cfg "$new" project slug)" == new-study ]] || fail "update changed the project identity"
"$new/scripts/check-workflow.sh" >/dev/null || fail "updated project does not pass the checks"

# 4. Existing project with its own README and .gitignore
old="$tmp/projects/existing"
mkdir -p "$old" && git -C "$old" init -q
printf '# Mine\n' > "$old/README.md"; printf 'node_modules/\n' > "$old/.gitignore"; printf '# My agent rules\n' > "$old/AGENTS.md"
out="$("$install" "$old")" || fail "install into existing project failed: $out"
[[ "$(cat "$old/README.md")" == "# Mine" ]] || fail "existing README overwritten"
grep -q 'AGENTS.md' <<<"$(sed -n '/^skipped/,$p' <<<"$out")" || fail "conflicting AGENTS.md not reported as skipped"
[[ "$(cat "$old/AGENTS.md")" == "# My agent rules" ]] || fail "existing AGENTS.md overwritten"
grep -qx 'node_modules/' "$old/.gitignore" && grep -qx '/output/' "$old/.gitignore" || fail ".gitignore not merged"
"$install" "$old" >/dev/null
[[ "$(grep -cx '/output/' "$old/.gitignore")" == 1 ]] || fail ".gitignore rules appended twice"
"$old/workflow/skills/project-init/init.sh" configure --name Existing --slug existing >/dev/null
[[ "$(cat "$old/README.md")" == "# Mine" ]] || fail "init overwrote the existing README"
grep -q '^# Current State' "$old/docs/CURRENT.md" || fail "CURRENT.md not written"

printf 'ok: install-workflow tests\n'
