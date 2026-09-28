#!/bin/bash
# Prints the notes for one version from CHANGELOG.md: the lines under
# `## <version>` up to the next `## `, blank lines trimmed at both ends.
# Prints nothing, and succeeds, when there is no such section — a release may
# have no notes.
#
#   scripts/release-notes.sh <version>
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f CHANGELOG.md ] || exit 0
awk -v heading="## $1" '
  $0 == heading { inside = 1; next }
  inside && /^## / { exit }
  inside { lines[++n] = $0 }
  END {
    first = 1; while (first <= n && lines[first] ~ /^[[:space:]]*$/) first++
    last = n;  while (last >= first && lines[last] ~ /^[[:space:]]*$/) last--
    for (i = first; i <= last; i++) print lines[i]
  }' CHANGELOG.md
