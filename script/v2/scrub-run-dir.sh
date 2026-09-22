#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------------
# scrub-run-dir.sh — scan a broadcast run directory (or any files) for SECRET SHAPES before a log, receipt or
# report leaves the box; optionally write value-free copies. T-OP-201 (BROADCAST SET prep, owner ask 07:45Z).
#
#   script/v2/scrub-run-dir.sh <run-dir> [<file>...]            scan; prints file:line:shape, NEVER the value
#   script/v2/scrub-run-dir.sh <run-dir> --redact [--out <dir>] scan, then write copies with every match replaced by
#                                                                <REDACTED:shape> into <run-dir>.scrubbed/ (or --out)
#                                                                and re-scan the copies (must come back clean)
#   script/v2/scrub-run-dir.sh --self-test                       the synthetic-fixture suite (script/v2/scrub-run-dir.test.sh)
#
# EXIT: 0 clean (warnings allowed), 1 at least one hit, 2 usage / cannot run. A hit is printed as
# `<file>:<line>:<shape>` and nothing else from that line: the point of this tool is that its own output can be
# pasted anywhere. Warnings are `<file>:<line>:WARN:<shape>`.
#
# THE SHAPES (each is an ERE that works under BSD grep -E and GNU grep -E; no \b, no \S):
#   rpc-key-url        a URL whose path carries an API key: `https://<host>/v2/<16+ token chars>` (Alchemy's host+key
#                      shape, T-OP-118's leak) or any URL with `?key=`/`api_key=`/`token=`/`apikey=`
#   env-secret         `NAME=value` where NAME is DEPLOYER_PK, ADMIN_PK, *_PK, *PRIVATE_KEY*, FORK_URL, *RPC_URL*,
#                      *_API_KEY, *_TOKEN, *_SECRET*, MNEMONIC (the coordinator-leak shape: a whole `env` dump)
#   hex-private-key    a 0x-prefixed 64-hex word on a line that also names a key (`pk`, `private`, `mnemonic`,
#                      `secret`, `--private-key`, `privateKey`) -- see WHAT THIS CANNOT SEE for bare 64-hex
#   github-token       ghp_ / gho_ / ghu_ / ghs_ / ghr_ (36+ chars) and github_pat_ (22+ chars)
#   bearer-token       `Bearer <16+ token chars>` (also `Authorization: Bearer ...`)
#   aws-key            AKIA + 16 upper/digit; `aws_secret_access_key=...`
#   cloudflare-token   `CLOUDFLARE_API_TOKEN=` / `CF_API_TOKEN=` / `CLOUDFLARE_API_KEY=` with a value
#   alchemy-key        `ALCHEMY_API_KEY=` with a value (the URL form is rpc-key-url)
#   fork-host          WARN ONLY: the host of ~/.agent-bridge/stonkhouse/fork.env (read for its HOST, never its key)
#                      appearing in a line; the same host followed by `/v2/<key>` is a rpc-key-url HIT
#
# WHAT THIS CANNOT SEE, said rather than faked:
#   - a BARE 0x + 64-hex word with no key-ish word on its line. A run dir is full of them -- transaction hashes,
#     operation ids, keccak fingerprints -- and a private key is byte-identical in shape. Flagging every one would
#     make the tool unusable and its exit code meaningless. So a private key pasted alone on a line is NOT caught.
#   - a secret split across lines, base64-wrapped, or a value under a name this list does not know.
#   - binary files are skipped (grep -I).
# It reads ~/.agent-bridge/stonkhouse/fork.env if present, ONLY to learn the host (scheme and path stripped in
# this process); the key never leaves that file and is never printed.
#
# bash 3.2 compatible (macOS): no associative arrays; sed -E; find/grep as shipped with the OS.
# -------------------------------------------------------------------------------------------------
set -euo pipefail

usage() { sed -n '2,/^# ----/p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "scrub-run-dir: $*" >&2; exit 2; }

FORK_ENV=${SCRUB_FORK_ENV:-$HOME/.agent-bridge/stonkhouse/fork.env}
TOKEN='[A-Za-z0-9_~.+/=-]'          # one token character (no space, no quote)
NB='(^|[^A-Za-z0-9_])'              # a non-word boundary before a token, BSD-safe

# shape name -> ERE. Kept as two parallel lists (bash 3.2 has no associative arrays), same order everywhere.
SHAPES="rpc-key-url env-secret hex-private-key github-token bearer-token aws-key cloudflare-token alchemy-key"
re_of() {
  case "$1" in
    rpc-key-url)      echo "https?://[A-Za-z0-9._-]+/v2/${TOKEN}{16,}|https?://[^ \"'\\]*[?&](api_?key|apikey|token|key)=${TOKEN}+" ;;
    env-secret)       echo "${NB}(DEPLOYER_PK|ADMIN_PK|[A-Z0-9_]*_PK|[A-Za-z0-9_]*PRIVATE_KEY[A-Za-z0-9_]*|FORK_URL|[A-Z0-9_]*RPC_URL[A-Z0-9_]*|[A-Z0-9_]*_API_KEY|[A-Z0-9_]*_TOKEN|[A-Z0-9_]*_SECRET[A-Z0-9_]*|MNEMONIC)=[^ ]+" ;;
    hex-private-key)  echo "(--private-key|[Pp]rivate[-_ ]?[Kk]ey|[^A-Za-z0-9_][Pp][Kk][^A-Za-z0-9_]|[Mm]nemonic|[Ss]ecret).{0,40}0x[0-9a-fA-F]{64}" ;;
    github-token)     echo "${NB}(gh[poust]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,})" ;;
    bearer-token)     echo "[Bb]earer +${TOKEN}{16,}" ;;
    aws-key)          echo "${NB}AKIA[0-9A-Z]{16}([^A-Z0-9]|$)|[Aa][Ww][Ss]_[Ss][Ee][Cc][Rr][Ee][Tt]_[Aa][Cc][Cc][Ee][Ss][Ss]_[Kk][Ee][Yy][=: ]+[^ ]+" ;;
    cloudflare-token) echo "${NB}(CLOUDFLARE_API_TOKEN|CF_API_TOKEN|CLOUDFLARE_API_KEY|CF_API_KEY)[=: ]+[^ ]+" ;;
    alchemy-key)      echo "${NB}ALCHEMY_API_KEY[=: ]+[^ ]+" ;;
    *) die "unknown shape $1" ;;
  esac
}

# The fork host, for the WARN shape: scheme and path stripped in-process, nothing else read from the file.
fork_host() {
  [ -f "$FORK_ENV" ] || return 0
  sed -nE 's#^FORK_URL=[a-z]+://([A-Za-z0-9._-]+).*$#\1#p' "$FORK_ENV" | head -1
}

MODE=scan; OUT=""; RUN_DIR=""; FILES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --redact) MODE=redact; shift ;;
    --out) [ $# -ge 2 ] || die "--out needs a path"; OUT=$2; shift 2 ;;
    --self-test) exec bash "$(dirname "$0")/scrub-run-dir.test.sh" ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown flag $1 (see --help)" ;;
    *) if [ -z "$RUN_DIR" ]; then RUN_DIR=$1; else FILES="$FILES
$1"; fi; shift ;;
  esac
done
[ -n "$RUN_DIR" ] || { usage >&2; exit 2; }
[ -e "$RUN_DIR" ] || die "no such path: $RUN_DIR"

# Every file to scan: the run dir's regular files (recursively) plus any explicit files, one per line.
list_files() {
  if [ -d "$RUN_DIR" ]; then find "$RUN_DIR" -type f | LC_ALL=C sort; else echo "$RUN_DIR"; fi
  printf '%s\n' "$FILES" | sed '/^$/d'
}

HITS=0; WARNS=0
HOST=$(fork_host || true)
scan_file() { # <file>  -> prints file:line:shape per matching line, per shape; counts
  local f=$1 shape re n
  for shape in $SHAPES; do
    re=$(re_of "$shape")
    # -I: skip binaries. -n: line numbers. The VALUE never leaves grep: only the line number does.
    n=$(grep -InE -- "$re" "$f" 2>/dev/null | cut -d: -f1 || true)
    for line in $n; do echo "$f:$line:$shape"; HITS=$((HITS + 1)); done
  done
  if [ -n "$HOST" ]; then
    # The host alone is a WARN; the host with a /v2/<key> path already counted as rpc-key-url above.
    n=$(grep -InF -- "$HOST" "$f" 2>/dev/null | cut -d: -f1 || true)
    for line in $n; do
      if ! sed -n "${line}p" "$f" | grep -qE -- "$(re_of rpc-key-url)"; then echo "$f:$line:WARN:fork-host"; WARNS=$((WARNS + 1)); fi
    done
  fi
}

redact_file() { # <src> <dst>: every shape's matches -> <REDACTED:shape>, in the fixed shape order
  local src=$1 dst=$2 shape
  local args=()
  mkdir -p "$(dirname "$dst")"
  # An indexed array, not a string: the expressions carry spaces (`[=: ]`) and must reach sed as one word each.
  for shape in $SHAPES; do args+=(-e "s#$(re_of "$shape")#<REDACTED:$shape>#g"); done
  sed -E "${args[@]}" "$src" > "$dst"
}

while IFS= read -r f; do [ -n "$f" ] || continue; scan_file "$f"; done <<FILES
$(list_files)
FILES

if [ "$MODE" = redact ]; then
  [ -n "$OUT" ] || OUT="${RUN_DIR%/}.scrubbed"
  [ -d "$RUN_DIR" ] || die "--redact needs a run DIRECTORY (copies are written under $OUT)"
  rm -rf "$OUT"; mkdir -p "$OUT"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in "$RUN_DIR"/*) rel=${f#"$RUN_DIR"/} ;; *) rel=$(basename "$f") ;; esac
    redact_file "$f" "$OUT/$rel"
  done <<FILES
$(list_files)
FILES
  echo "scrub-run-dir: $HITS hit(s), $WARNS warning(s) in $RUN_DIR; value-free copies written to $OUT"
  # THE COPIES MUST SCAN CLEAN, by this same scanner, or the redaction is a claim rather than a fact.
  if "$0" "$OUT" > /dev/null; then echo "scrub-run-dir: re-scan of $OUT: clean"; else echo "scrub-run-dir: re-scan of $OUT STILL HITS -- do not ship it" >&2; exit 1; fi
  exit 0
fi

if [ "$HITS" != 0 ]; then echo "scrub-run-dir: $HITS hit(s), $WARNS warning(s) in $RUN_DIR -- do NOT ship these files as they are (--redact writes value-free copies)" >&2; exit 1; fi
echo "scrub-run-dir: clean ($WARNS warning(s)) in $RUN_DIR"
