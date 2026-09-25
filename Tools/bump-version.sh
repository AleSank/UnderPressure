#!/bin/zsh
# Prepares a new version: sets MARKETING_VERSION (app and tests), increments the build number
# (CURRENT_PROJECT_VERSION) and adds a CHANGELOG.md section to fill in. Commits nothing.
# Usage: Tools/bump-version.sh 1.1.0
set -euo pipefail

root=${0:A:h:h}
cd "$root"
version=${1:-}
[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "Usage: $0 <major.minor.patch>, e.g. 1.1.0" >&2; exit 1; }

project=UnderPressure.xcodeproj/project.pbxproj
current=$(sed -nE 's/.*MARKETING_VERSION = ([0-9.]+);.*/\1/p' $project | head -1)
build=$(sed -nE 's/.*CURRENT_PROJECT_VERSION = ([0-9]+);.*/\1/p' $project | head -1)
[[ $version != $current ]] || { echo "Already at $version" >&2; exit 1; }

sed -i '' -E "s/MARKETING_VERSION = [0-9.]+;/MARKETING_VERSION = $version;/" $project
sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $((build + 1));/" $project

if ! grep -q "^## $version$" CHANGELOG.md; then
  # New section right after the "# Changelog" title.
  awk -v v="$version" 'NR == 1 { print; print ""; print "## " v; print ""; print "- (describe the changes)"; next } { print }' \
    CHANGELOG.md > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md
fi

cat <<NEXT
$current → $version (build $((build + 1))).
Next:
  1. Describe the changes under "## $version" in CHANGELOG.md.
  2. Commit, then push the branch first and the tag separately:
       git push origin main
       git tag v$version && git push origin v$version
     The tag push starts the Release workflow (tests, build, GitHub release with the zip).
NEXT
