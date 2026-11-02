# shellcheck shell=bash
# Read values from project.yaml. Sourced by scripts; not executable on its own.
#
# project.yaml is deliberately a two-level map of scalars:
#
#   section:
#     key: value   # comment
#
# `null`, `~` and empty values read as the empty string. Lists and nested maps are not supported.

project_config_get() {
  local file="$1" section="$2" key="$3"
  [[ -f "$file" ]] || return 0
  awk -v sec="$section" -v key="$key" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    /^[^ \t#]/ { s = $0; sub(/:.*/, "", s); section = trim(s); next }
    /^[ \t]+[^ \t#]/ && section == sec {
      k = $0; sub(/:.*/, "", k); k = trim(k)
      if (k != key) next
      v = $0; sub(/^[^:]*:/, "", v); sub(/[ \t]+#.*$/, "", v); v = trim(v)
      if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
      if (v == "null" || v == "~") v = ""
      print v; exit
    }' "$file"
}

# project_config_set FILE SECTION KEY VALUE: replace the value of an existing key, keeping its comment.
project_config_set() {
  local file="$1" section="$2" key="$3" value="$4" tmp
  tmp="$(mktemp)"
  awk -v sec="$section" -v key="$key" -v val="$value" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    /^[^ \t#]/ { s = $0; sub(/:.*/, "", s); section = trim(s) }
    /^[ \t]+[^ \t#]/ && section == sec && !done {
      k = $0; sub(/:.*/, "", k); k = trim(k)
      if (k == key) {
        indent = $0; sub(/[^ \t].*$/, "", indent)
        comment = ""; if (match($0, /[ \t]+#.*$/)) comment = substr($0, RSTART)
        print indent key ": " val comment; done = 1; next
      }
    }
    { print }
    END { if (!done) exit 3 }' "$file" > "$tmp" || { rm -f -- "$tmp"; printf 'error: %s.%s not found in %s\n' "$section" "$key" "$file" >&2; return 1; }
  cat "$tmp" > "$file"; rm -f -- "$tmp"
}
