#!/usr/bin/env bash
# Consistency checks for the research workflow: identity/phase, state references, review and decision names,
# skills and their discovery links, and relative Markdown links. Exits 1 if any check fails.
set -uo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_root" || exit 2
# shellcheck source=lib/project-config.sh
source scripts/lib/project-config.sh

fails=0 warns=0
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
warn() { printf 'WARN: %s\n' "$1"; warns=$((warns + 1)); }
# Top-level scalar from a YAML file, without quotes or trailing comment; null/~ read as empty.
yaml_top() {
  awk -v key="$2" '
    $0 ~ "^" key ":" { v = $0; sub(/^[^:]*:[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v)
      gsub(/^["\047]|["\047]$/, "", v); if (v == "null" || v == "~") v = ""; print v; exit }' "$1"
}

# 1. Identity and phase ------------------------------------------------------------------------
status=meta/status.yaml
[[ -f project.yaml ]] || fail "project.yaml is missing"
[[ -f "$status" ]] || { fail "$status is missing"; printf '%d failure(s)\n' "$fails"; exit 1; }
slug="$(project_config_get project.yaml project slug)"
phase="$(yaml_top "$status" phase)"
if [[ -z "$slug" ]]; then
  mode=template
  [[ "$phase" == template ]] || fail "project.slug is unset but $status phase is '$phase' (expected: template)"
  [[ -f workflow/skills/project-init/SKILL.md ]] || fail "uninitialized template is missing workflow/skills/project-init"
else
  mode=project
  [[ "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "project.slug '$slug' must match [a-z0-9][a-z0-9-]*"
  [[ "$phase" != template ]] || fail "project.slug is set but $status phase is still 'template'"
  [[ ! -e workflow/skills/project-init ]] ||
    warn "bootstrap not finalized: workflow/skills/project-init still exists (run its init.sh finalize)"
  for f in README.md docs/CURRENT.md research/PROPOSAL.md; do
    [[ -f "$f" ]] && grep -q 'rw:template' "$f" && fail "$f still contains the template placeholder (rw:template)"
  done
fi

# 2. State references in meta/status.yaml ------------------------------------------------------
plan="$(yaml_top "$status" active_plan)"
if [[ -n "$plan" ]]; then
  [[ -f "$plan" ]] || fail "$status active_plan does not exist: $plan"
  [[ "$plan" == plans/active/* ]] || fail "$status active_plan must live in plans/active/: $plan"
fi
while read -r kind name a b; do
  case "$kind" in
    artifact)
      [[ "$b" == not_started || -e "$a" ]] || fail "$status artifacts.$name.ref does not exist: $a (status: $b)" ;;
    review)
      [[ -z "$a" || "$a" == null ]] && continue
      [[ -f "$a" ]] || fail "$status artifacts.$name.review.latest_review does not exist: $a"
      [[ "$a" == research/reviews/* ]] || fail "latest_review must live in research/reviews/: $a" ;;
    evidence)
      [[ -e "$name" ]] || fail "$status evidence entry does not exist: $name" ;;
  esac
done < <(awk '
  function val(s) { sub(/^[^:]*:[ \t]*/, "", s); sub(/[ \t]+#.*$/, "", s); gsub(/^["\047]|["\047]$/, "", s); return s }
  /^[^ \t#]/ { block = $0; sub(/:.*/, "", block) }
  block == "artifacts" && /^  [A-Za-z0-9_-]+:/ { name = $1; sub(/:$/, "", name); ref = ""; st = "" }
  block == "artifacts" && /^    ref:/ { ref = val($0) }
  block == "artifacts" && /^    status:/ { st = val($0); print "artifact", name, ref, st }
  block == "artifacts" && /^      latest_review:/ { print "review", name, val($0) }
  block == "evidence" && /^[ \t]*- / { e = $0; sub(/^[ \t]*- [ \t]*/, "", e); sub(/[ \t]+#.*$/, "", e); print "evidence", e }
' "$status")

# 3. Record names: reviews YYYYMMDD-<artifact>-<reviewer>-rN.md, decisions NNNN-<slug>.md ----------
for f in research/reviews/*/*; do
  [[ -e "$f" ]] || continue
  dir="$(basename -- "$(dirname -- "$f")")"; base="$(basename -- "$f")"
  [[ "$base" =~ ^[0-9]{8}-${dir}-[a-z0-9][a-z0-9-]*-r[0-9]+\.md$ ]] ||
    fail "review file name must be YYYYMMDD-$dir-<reviewer>-rN.md: $f"
done

for f in research/decisions/*; do
  [[ -e "$f" ]] || continue
  [[ "$(basename -- "$f")" =~ ^[0-9]{4}-[a-z0-9][a-z0-9-]*\.md$ ]] || fail "decision file name must be NNNN-<slug>.md: $f"
done

# 4. Skills and discovery links -------------------------------------------------------------------
for dir in workflow/skills/*/; do
  skill="$(basename -- "$dir")"; md="$dir/SKILL.md"
  if [[ ! -f "$md" ]]; then fail "skill directory without SKILL.md: $dir"; continue; fi
  [[ "$(head -n 1 "$md")" == --- ]] || { fail "$md must start with YAML front matter"; continue; }
  front="$(awk 'NR == 1 { next } /^---$/ { exit } { print }' "$md")"
  name="$(printf '%s\n' "$front" | awk '/^name:/ { sub(/^name:[ \t]*/, ""); print; exit }')"
  [[ "$name" == "$skill" ]] || fail "$md front matter name '$name' must equal the directory name '$skill'"
  printf '%s\n' "$front" | grep -qE '^description: *[^ ]' || fail "$md front matter has no description"
  link=".claude/skills/$skill"
  if [[ ! -L "$link" ]]; then fail "$link is not installed (run scripts/install-agent-skills.sh)"
  elif [[ "$(readlink -- "$link")" != "../../workflow/skills/$skill" ]]; then fail "$link does not point to workflow/skills/$skill"
  fi
done
for link in .claude/skills/*; do
  [[ -L "$link" && ! -e "$link" ]] && fail "dangling skill link: $link (run scripts/install-agent-skills.sh)"
done

# 5. Relative Markdown links (outside fenced code blocks) ------------------------------------------
while IFS= read -r -d '' md; do
  [[ -f "$md" ]] || continue   # deleted in the working tree but still in the index
  base_dir="$(dirname -- "$md")"
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    case "$target" in http://*|https://*|mailto:*|\#*) continue ;; esac
    path="${target%%#*}"; path="${path#<}"; path="${path%>}"
    [[ -e "$base_dir/$path" ]] || fail "$md links to a missing path: $target"
  done < <(awk '
    /^[ \t]*```/ { fence = !fence; next }
    fence { next }
    { line = $0
      while (match(line, /\]\([^) ]+\)/)) { print substr(line, RSTART + 2, RLENGTH - 3); line = substr(line, RSTART + RLENGTH) } }' "$md")
done < <(git ls-files -z -co --exclude-standard -- '*.md' 2>/dev/null)

# Summary -------------------------------------------------------------------------------------------
if ((fails)); then printf '%d failure(s), %d warning(s) [mode: %s]\n' "$fails" "$warns" "$mode"; exit 1; fi
printf 'ok: workflow checks passed, %d warning(s) [mode: %s]\n' "$warns" "$mode"
