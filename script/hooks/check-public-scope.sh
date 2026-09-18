#!/usr/bin/env bash
set -euo pipefail

# On macOS, the Apple shim can exist before its Xcode license is accepted.
# Prefer a real Homebrew Git there, while retaining the usual PATH elsewhere.
git_bin=git
if [[ -x /opt/homebrew/bin/git ]]; then
  git_bin=/opt/homebrew/bin/git
fi

# Pre-commit calls this without arguments. Explicit paths are accepted solely
# to exercise the policy without staging files.
failed=0
check_path() {
  local path="$1"
  local allow_deleted="${2:-0}"
  local reason=''
  case "$path" in
    .env.example|*/.env.example) ;;
    .env|.env.*|*/.env|*/.env.*)
      reason='environment/credential file' ;;
  esac
  case "$path" in
    broadcast/*|out/*|cache/*|coverage/*|lcov.info|*/rehearsal-passed.json)
      reason='generated or local rehearsal artifact' ;;
    ops/devnet/addresses.json|registry/dev*.json|registry/*-dev.json|*devnet-addresses*.json|*dev-registry*.json)
      reason='local dev registry or address file' ;;
    CLAUDE.md|*/CLAUDE.md|STATUS-*.md|*/STATUS-*.md|*.patch.untracked|verify-flags.patch*)
      reason='private handoff or migration scratch file' ;;
    .gitmodules|lib/forge-std|lib/openzeppelin-contracts)
      reason='dependency/submodule change requires an explicit reviewed migration' ;;
    *.pem|*.p12|*.pfx|*.key|*keystore*|*mnemonic*|*private-key*|*private_key*)
      reason='credential-like path' ;;
  esac
  case "$path" in
    *.[mM][dD]|*.[mM][dD][xX]|*.[mM][aA][rR][kK][dD][oO][wW][nN])
      reason='Markdown file excluded from this migration' ;;
  esac
  if [[ -n "$reason" ]]; then
    printf 'public-migration-scope: reject %q (%s)\n' "$path" "$reason" >&2
    failed=1
    return
  fi

  # The policy source necessarily contains its own forbidden path tokens.
  if [[ "$path" == script/hooks/check-public-scope.sh ]]; then
    return
  fi

  # Scan the staged blob, not the working tree; avoid printing matching lines.
  # This catches machine-private paths that generic secret detectors often miss.
  if ! "$git_bin" cat-file -e ":$path" 2>/dev/null; then
    # A deleted, non-Markdown path has no staged blob to inspect.
    if [[ "$allow_deleted" == 1 ]]; then
      return
    fi
    printf 'public-migration-scope: cannot inspect staged blob %q\n' "$path" >&2
    failed=1
    return
  fi
  if rg -q '(/Users/|/home/[^/]+/|/Volumes/|file://|wt/callhouse|stonkhouse-plan/status/)' < <("$git_bin" show ":$path"); then
    printf 'public-migration-scope: reject %q (local/private path in staged content)\n' "$path" >&2
    failed=1
  fi
}

if (( $# > 0 )); then
  for path in "$@"; do
    check_path "$path"
  done
else
  staged_paths=$(mktemp)
  trap 'rm -f "$staged_paths"' EXIT
  # --no-renames exposes both sides, so renaming a Markdown file to a
  # non-Markdown extension cannot evade the exclusion.
  "$git_bin" diff --cached --no-renames --name-only --diff-filter=ACMRD -z > "$staged_paths"
  while IFS= read -r -d '' path; do
    check_path "$path" 1
  done < "$staged_paths"
fi

exit "$failed"
