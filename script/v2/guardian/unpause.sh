#!/usr/bin/env bash
# script/v2/guardian/unpause.sh — the same switches as pause.sh, set back to false, from the guardian wallet
# (T-OP-174). Every flag, refusal and read-back is pause.sh's; this file only fixes the direction.
#   script/v2/guardian/unpause.sh --registry <tier1.json> --rpc <url> [--send [--unlocked]] [--signer <addr>] [--only ...]
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pause.sh" --unpause "$@"
