#!/bin/sh
# Assemble UBERSHOW.COM with NASM, run the static audits and enforce the 40K size budget.
set -eu
cd "$(dirname "$0")"
LIMIT=40960
python3 audit.py
command -v nasm >/dev/null 2>&1 || { echo 'ERROR: NASM is required.' >&2; exit 1; }
nasm -f bin -Wall -Werror showcase.asm -o UBERSHOW.COM
size=$(wc -c < UBERSHOW.COM | tr -d ' ')
printf 'UBERSHOW.COM: %s bytes (40K budget %s)\n' "$size" "$LIMIT"
[ "$size" -le "$LIMIT" ] || { echo 'ERROR: UBERSHOW.COM exceeds the 40K budget' >&2; exit 2; }
if command -v sha256sum >/dev/null 2>&1; then sha256sum UBERSHOW.COM > SHA256SUMS; else shasum -a 256 UBERSHOW.COM > SHA256SUMS; fi
cat SHA256SUMS
