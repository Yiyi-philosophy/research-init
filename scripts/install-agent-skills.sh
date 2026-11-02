#!/usr/bin/env bash
# Link every canonical skill in workflow/skills/<name>/SKILL.md into .claude/skills/<name>.
# Never copies, never deletes unknown entries; removes only dangling links that point into workflow/skills/.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
canonical_root="$repo_root/workflow/skills"
discovery_root="$repo_root/.claude/skills"

[[ -d "$canonical_root" ]] || { printf 'error: canonical skills directory is missing: %s\n' "$canonical_root" >&2; exit 1; }
if [[ -e "$discovery_root" && ! -d "$discovery_root" ]]; then
  printf 'error: discovery path exists but is not a directory: %s\n' "$discovery_root" >&2; exit 1
fi
mkdir -p -- "$discovery_root"

# Prune links left behind by removed skills (for example project-init after bootstrap).
for entry in "$discovery_root"/*; do
  [[ -L "$entry" && ! -e "$entry" ]] || continue
  case "$(readlink -- "$entry")" in
    ../../workflow/skills/*) rm -f -- "$entry"; printf 'pruned: %s (skill removed)\n' "${entry#"$repo_root"/}" ;;
  esac
done

for skill_md in "$canonical_root"/*/SKILL.md; do
  [[ -f "$skill_md" ]] || continue
  skill="$(basename -- "$(dirname -- "$skill_md")")"
  destination="$discovery_root/$skill"
  target="../../workflow/skills/$skill"
  if [[ -L "$destination" ]]; then
    if [[ "$(readlink -- "$destination")" == "$target" ]]; then
      printf 'ok: .claude/skills/%s\n' "$skill"
    else
      printf 'skip: preserving non-canonical symlink: .claude/skills/%s\n' "$skill" >&2
    fi
  elif [[ -e "$destination" ]]; then
    printf 'skip: preserving existing entry: .claude/skills/%s\n' "$skill" >&2
  else
    ln -s -- "$target" "$destination"
    printf 'linked: .claude/skills/%s -> %s\n' "$skill" "$target"
  fi
done
