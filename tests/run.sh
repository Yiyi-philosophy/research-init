#!/usr/bin/env bash
# Run every test: workflow consistency, tests/test-*.sh, and tests shipped inside skills.
set -uo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
failed=0

run() {
  local name="$1"; shift
  printf '== %s\n' "$name"
  if "$@"; then printf -- '-- pass: %s\n' "$name"; else printf -- '-- FAIL: %s\n' "$name"; failed=$((failed + 1)); fi
}

run check-workflow "$repo_root/scripts/check-workflow.sh"
for t in "$repo_root"/tests/test-*.sh "$repo_root"/workflow/skills/*/tests/test-*.sh; do
  [[ -f "$t" ]] || continue
  name="${t#"$repo_root"/}"
  if [[ "$name" == tests/test-remote.sh ]] && ! command -v tmux >/dev/null; then
    printf '== %s\n-- skip: tmux is not installed on this machine\n' "$name"; continue
  fi
  run "$name" bash "$t"
done

((failed == 0)) || { printf '%d test group(s) failed\n' "$failed"; exit 1; }
printf 'all tests passed\n'
