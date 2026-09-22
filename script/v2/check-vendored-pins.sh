#!/usr/bin/env bash
# T-574. Fail when a file whose header ASSERTS its body is unchanged has in fact changed.
#
# WHY THIS EXISTS. A vendoring header is an assertion about the day the file landed. It cannot see
# later edits, so "it is vendored, so it is out of audit scope" rests on a human reading a comment,
# with every commit after that comment as its blind spot. That is the board's dominant defect class:
# a check that passes because it cannot see its subject. This makes the assertion mechanical.
#
# WHERE IT RUNS, stated plainly because a check nobody executes reproduces the defect it fixes:
# .github/workflows/vendored-pins.yml runs it on every direct push to v8 and on pull requests.
# script/v2/launch-path-smoke.sh also calls it for the local, no-chain launch-path check.
#
# Output is machine-readable so the harness can map it to its own ok/FAIL lines:
#   PIN-OK <path> | PIN-MISMATCH <path> <expected> <actual> | PIN-MISSING <path>
# Exit 0 when every pinned file matches, 1 when any does not, 2 when the check itself cannot run.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
MANIFEST="${1:-$ROOT/script/v2/vendored-pins.json}"

command -v jq >/dev/null || { echo "check-vendored-pins: jq is required" >&2; exit 2; }
[ -r "$MANIFEST" ] || { echo "check-vendored-pins: cannot read manifest $MANIFEST" >&2; exit 2; }

# sha256sum on Linux, shasum -a 256 on macOS. If neither exists the check cannot run, and it says so
# rather than skipping: a silent skip is the failure mode this file was written to remove.
if command -v sha256sum >/dev/null; then HASH() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null; then HASH() { shasum -a 256 "$1" | cut -d' ' -f1; }
else echo "check-vendored-pins: neither sha256sum nor shasum is available" >&2; exit 2; fi

COUNT=$(jq -r '.pinned | length' "$MANIFEST")
[ "$COUNT" -gt 0 ] 2>/dev/null || { echo "check-vendored-pins: manifest pins no files" >&2; exit 2; }

rc=0
for i in $(seq 0 $((COUNT - 1))); do
  path=$(jq -r ".pinned[$i].path" "$MANIFEST")
  want=$(jq -r ".pinned[$i].sha256" "$MANIFEST")
  case "$want" in
    ''|null) echo "check-vendored-pins: $path has no sha256 in the manifest" >&2; rc=2; continue ;;
  esac
  if [ ! -r "$ROOT/$path" ]; then printf 'PIN-MISSING %s\n' "$path"; rc=1; continue; fi
  got=$(HASH "$ROOT/$path")
  if [ "$got" = "$want" ]; then printf 'PIN-OK %s\n' "$path"
  else printf 'PIN-MISMATCH %s %s %s\n' "$path" "$want" "$got"; rc=1; fi
done
exit $rc
