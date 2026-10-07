#!/bin/sh
set -eu
DOSBOX_BIN=dosbox
if ! command -v "$DOSBOX_BIN" >/dev/null 2>&1; then
    # Homebrew's dosbox cask (macOS) installs the .app bundle only, with no
    # `dosbox` symlink on PATH; fall back to the bundle's binary directly.
    MAC_APP=/Applications/dosbox.app/Contents/MacOS/DOSBox
    if [ -x "$MAC_APP" ]; then
        DOSBOX_BIN="$MAC_APP"
    else
        echo 'ERROR: DOSBox is required (dosbox not on PATH, and' \
             "$MAC_APP not found)." >&2
        exit 1
    fi
fi
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TARGET="${1:-UBERSHOW.COM}"

# Combining `-conf DOSBOX.CONF` with separate `-c` autoexec flags on the
# command line defeats cycles=max in this DOSBox build -- it silently falls
# back to a low fixed cycle count (observed: 3000) instead of running the
# CPU as fast as the host allows. Putting the autoexec commands inside the
# conf file's own [autoexec] section instead does not have this problem, so
# build a temp conf from DOSBOX.CONF with the real mount/run commands
# appended, and launch with -conf alone.
TMPCONF=$(mktemp /tmp/uber256-dosbox.XXXXXX.conf)
trap 'rm -f "$TMPCONF"' EXIT
grep -v '^\[autoexec\]' "$DIR/DOSBOX.CONF" | grep -v '^#' > "$TMPCONF"
{
    echo "[autoexec]"
    echo "mount c $DIR"
    echo "c:"
    echo "$TARGET"
} >> "$TMPCONF"

"$DOSBOX_BIN" -conf "$TMPCONF"
