#!/bin/zsh
# Prints the CHANGELOG.md section of one version (the lines under "## <version>"), used as
# the GitHub release notes. Fails if the section is missing or still a placeholder.
# Usage: Tools/changelog-section.sh 1.1.0
set -euo pipefail

root=${0:A:h:h}
version=${1:?Usage: $0 <version>}
notes=$(awk -v v="$version" '
  $0 == "## " v { found = 1; next }
  found && /^## / { exit }
  found { print }
' "$root/CHANGELOG.md" | sed -e '/./,$!d')   # drop leading blank lines

[[ -n ${notes//[[:space:]]/} ]] || { echo "CHANGELOG.md has no section for $version" >&2; exit 1; }
[[ $notes != *"(describe the changes)"* ]] || { echo "CHANGELOG.md section for $version is still a placeholder" >&2; exit 1; }
print -r -- "$notes"
