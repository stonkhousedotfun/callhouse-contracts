#!/usr/bin/env bash
set -euo pipefail

for script in "$@"; do
  bash -n "$script"
done
