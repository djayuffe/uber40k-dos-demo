#!/bin/sh
# Behavioural tests: run the built .COM files in an emulated 16-bit CPU and
# check what they do to the hardware (OPL2 writes, stack, exit cleanliness).
# Needs Python 3 + `unicorn`, installed into a throwaway ./.venv.
set -eu
cd "$(dirname "$0")/.."
[ -f UBERSHOW.COM ] || ./build.sh
if [ ! -x .venv/bin/python ]; then
    python3 -m venv .venv
    .venv/bin/pip install -q unicorn
fi
exec .venv/bin/python tests/emu_test.py "$@"
