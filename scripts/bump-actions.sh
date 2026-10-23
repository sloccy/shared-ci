#!/usr/bin/env bash
# Bumps `uses: owner/repo[/path]@vN` pins in a repo's workflow files to the newest stable major.
#
#   bump-actions.sh [min-age-days]      run from the repo root; needs `gh` (GH_TOKEN) and perl
#
# A pin moves only when the action's latest stable release has a higher major, that release is at
# least min-age-days old (default 7: a bad release can be pulled before we adopt it), and the
# moving major tag (vN) exists. Local actions, docker://, SHA pins, non-vN refs and sloccy/shared-ci
# itself (our own moving tag) are left alone. One line per bump goes to stdout and to $SUMMARY_FILE.
set -euo pipefail

MIN_AGE_DAYS=${1:-7}
SUMMARY=${SUMMARY_FILE:-/dev/null}
NOW=$(date +%s)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

list_files() {
  [ -d .github/workflows ] && find .github/workflows -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) -print0
  [ -d .github/actions ] && find .github/actions -type f \( -name action.yml -o -name action.yaml \) -print0
  return 0
}

[ -n "$(list_files | tr '\0' '\n' | head -1)" ] || { echo "No workflow files."; exit 0; }

pins=$(list_files | xargs -0 grep -hoE "uses:[[:space:]]*['\"]?[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@v[0-9]+['\"]?" 2>/dev/null \
  | sed -E "s/uses:[[:space:]]*['\"]?//; s/['\"]?\$//" | sort -u || true)
[ -n "$pins" ] || { echo "No version-pinned actions found."; exit 0; }

# latest <owner/repo>: prints "<major> <epoch>" for its newest stable release, or nothing
latest() {
  local cache
  cache="$TMP/$(echo "$1" | tr '/' '_')"
  [ -f "$cache" ] || {
    local out tag
    out=$(gh api "repos/$1/releases/latest" --jq '[.tag_name, (.published_at | fromdateiso8601)] | @tsv' 2>/dev/null || true)
    tag=${out%%$'\t'*}
    if [[ "$tag" =~ ^v([0-9]+)([.].*)?$ ]]; then
      echo "${BASH_REMATCH[1]} ${out##*$'\t'}" > "$cache"
    else
      : > "$cache"
    fi
  }
  cat "$cache"
}

changed=0
while IFS= read -r pin; do
  [ -n "$pin" ] || continue
  path=${pin%@*}
  cur=${pin##*@v}
  repo=$(echo "$path" | cut -d/ -f1-2)
  [ "$repo" = "sloccy/shared-ci" ] && continue
  read -r major epoch <<< "$(latest "$repo")"
  [ -n "${major:-}" ] || { echo "skip $path: no stable release found"; continue; }
  [ "$major" -gt "$cur" ] || continue
  age=$(( (NOW - epoch) / 86400 ))
  if [ "$age" -lt "$MIN_AGE_DAYS" ]; then
    echo "skip $path: v$major is only $age day(s) old (waiting for $MIN_AGE_DAYS)"
    continue
  fi
  if ! gh api "repos/$repo/git/ref/tags/v$major" > /dev/null 2>&1; then
    echo "skip $path: no moving tag v$major"
    continue
  fi
  # shellcheck disable=SC2016 # the perl program reads OLD and NEW from its environment
  list_files | OLD="$path@v$cur" NEW="$path@v$major" xargs -0 perl -pi -e 's/\Q$ENV{OLD}\E(?=[\x27"\s#]|$)/$ENV{NEW}/g'
  released=$(date -u -d "@$epoch" +%F 2>/dev/null || date -u -r "$epoch" +%F)
  line="- $path v$cur -> v$major (released $released)"
  echo "$line"
  echo "$line" >> "$SUMMARY"
  changed=$((changed + 1))
done <<< "$pins"

echo "$changed pin(s) bumped."
