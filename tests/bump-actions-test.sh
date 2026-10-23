#!/usr/bin/env bash
# Runs scripts/bump-actions.sh against temporary workflow files with a fake `gh`.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FAILS=0
NOW=$(date +%s)
OLD=$((NOW - 30 * 86400)) # a release 30 days old
NEW=$((NOW - 1 * 86400))  # a release 1 day old

new_case() { # sets $W (work dir) and $FIX (fixtures); installs the fake gh
  W=$(mktemp -d); FIX="$W/fix"; mkdir -p "$FIX" "$W/bin" "$W/repo/.github/workflows"
  cat > "$W/bin/gh" <<'GH'
#!/usr/bin/env bash
[ "$1" = api ] || exit 1
p=$2
case "$p" in
  repos/*/releases/latest)
    f="$FIX/rel_$(echo "${p#repos/}" | sed 's#/releases/latest##; s#/#_#')"
    [ -f "$f" ] && cat "$f" || exit 1 ;;
  repos/*/git/ref/tags/*)
    r=${p#repos/}; repo=${r%%/git/*}; tag=${r##*/}
    [ -f "$FIX/tag_$(echo "$repo" | tr / _)_$tag" ] || exit 1 ;;
  *) exit 1 ;;
esac
GH
  chmod +x "$W/bin/gh"
}
release() { printf '%s\t%s\n' "$2" "$3" > "$FIX/rel_$(echo "$1" | tr / _)"; }
tag()     { : > "$FIX/tag_$(echo "$1" | tr / _)_$2"; }
run()     { (cd "$W/repo" && FIX="$FIX" PATH="$W/bin:$PATH" SUMMARY_FILE="$W/summary" bash "$ROOT/scripts/bump-actions.sh" "${1:-7}" > "$W/out" 2>&1); }
check()   { # description, command that must succeed
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAILS=$((FAILS + 1)); sed 's/^/     /' "$W/out" 2>/dev/null; fi
}
has()  { grep -qF -- "$2" "$W/repo/$1"; }
lacks() { ! grep -qF -- "$2" "$W/repo/$1"; }

# ── bumps a lower major, keeps comments, updates several files and sub-paths
new_case
cat > "$W/repo/.github/workflows/a.yml" <<'Y'
steps:
  - uses: actions/checkout@v5 # keep this comment
  - uses: owner/tool/sub/dir@v2
  - uses: "quoted/action@v1"
Y
cat > "$W/repo/.github/workflows/b.yaml" <<'Y'
steps:
  - uses: actions/checkout@v5
Y
release actions/checkout v7.1.0 "$OLD"; tag actions/checkout v7
release owner/tool v3.0.1 "$OLD";       tag owner/tool v3
release quoted/action v2 "$OLD";        tag quoted/action v2
run
check "major bumped in every file" "has .github/workflows/a.yml 'actions/checkout@v7 # keep this comment' && has .github/workflows/b.yaml 'actions/checkout@v7'"
check "sub-path and quoted pins bumped" "has .github/workflows/a.yml 'owner/tool/sub/dir@v3' && has .github/workflows/a.yml '\"quoted/action@v2\"'"
check "summary written" "grep -q 'actions/checkout v5 -> v7' '$W/summary'"
cp -r "$W/repo" "$W/before"
run
check "second run changes nothing" "diff -r '$W/repo' '$W/before' > /dev/null"

# ── leaves things alone
new_case
cat > "$W/repo/.github/workflows/a.yml" <<'Y'
steps:
  - uses: actions/checkout@v7
  - uses: ./local/action
  - uses: docker://alpine:3
  - uses: pinned/by-sha@8f4b7f84864484a7bf31766abe9204da3cbe65b3
  - uses: pinned/by-minor@v1.2.3
  - uses: sloccy/shared-ci/.github/workflows/security.yml@v1
  - uses: young/release@v1
  - uses: notag/release@v1
  - uses: norelease/at-all@v1
Y
release actions/checkout v7 "$OLD"; tag actions/checkout v7
release sloccy/shared-ci v2.0.0 "$OLD"; tag sloccy/shared-ci v2
release young/release v2.0.0 "$NEW"; tag young/release v2
release notag/release v2.0.0 "$OLD"
cp "$W/repo/.github/workflows/a.yml" "$W/a.orig"
run
check "nothing eligible: file untouched" "diff -q '$W/repo/.github/workflows/a.yml' '$W/a.orig' > /dev/null"
check "young release is reported as waiting" "grep -q 'young/release.*1 day' '$W/out'"
check "missing major tag is reported" "grep -q 'notag/release.*no moving tag v2' '$W/out'"
check "no release at all is not an error" "grep -q 'norelease/at-all: no stable release' '$W/out'"

# ── the minimum age is a parameter
new_case
echo "  - uses: young/release@v1" > "$W/repo/.github/workflows/a.yml"
release young/release v2.0.0 "$NEW"; tag young/release v2
run 0
check "min age 0 adopts a young release" "has .github/workflows/a.yml 'young/release@v2'"

# ── a pin that merely starts with the same text is not touched
new_case
cat > "$W/repo/.github/workflows/a.yml" <<'Y'
  - uses: a/b@v1
  - uses: a/b@v10
Y
release a/b v11.0.0 "$OLD"; tag a/b v11
run
check "v1 and v10 are bumped separately and exactly" "has .github/workflows/a.yml 'a/b@v11' && lacks .github/workflows/a.yml 'a/b@v1 ' && ! grep -q '@v111' '$W/repo/.github/workflows/a.yml'"

# ── no workflow files
new_case
rmdir "$W/repo/.github/workflows"
run
check "no workflows is fine" "grep -q 'No workflow files' '$W/out'"

if [ "$FAILS" -eq 0 ]; then echo "all passed"; else echo "$FAILS failed"; exit 1; fi
