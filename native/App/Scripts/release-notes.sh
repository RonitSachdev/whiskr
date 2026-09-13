#!/bin/sh
# Prints the CHANGELOG.md section for a version, for a release's notes: the "## [<version>]" section if
# there is one, else "## [Unreleased]" (a draft made before the changelog was cut).
#
#   Scripts/release-notes.sh <version> [CHANGELOG.md]
set -eu

version=${1:?usage: release-notes.sh <version> [changelog]}
changelog=${2:-../../CHANGELOG.md}

section() {
    awk -v heading="## [$1]" '
        index($0, heading) == 1 { found = 1; next }
        found && /^## \[/ { exit }
        found && /^\[[^]]+\]: / { exit }
        found && !started && /^[[:space:]]*$/ { next }
        found { started = 1; print }
    ' "$changelog"
}

notes=$(section "$version")
[ -n "$(printf '%s' "$notes" | tr -d '[:space:]')" ] || notes=$(section Unreleased)
[ -n "$(printf '%s' "$notes" | tr -d '[:space:]')" ] || { echo "release-notes.sh: no section for $version or Unreleased in $changelog" >&2; exit 1; }
printf '%s\n' "$notes"
