#!/bin/bash
# Cross-builds Naples.app for the Pi (Darwin arm64) with the iokit repo's toolchain, exactly like milan's build.sh.
#
#   ./build.sh                 build; output lands in iokit's libc_build/gnustep/root
#   ./build.sh deploy          build, then copy Naples.app to the Pi
#
# IOKIT_DIR   the iokit checkout (default ../iokit)
# DEPLOY_HOST ssh target for "deploy" (default root@10.0.0.142)
set -euo pipefail
NAPLES_DIR="$(cd "$(dirname "$0")" && pwd -P)"
IOKIT_DIR="${IOKIT_DIR:-$NAPLES_DIR/../iokit}"
STAGING="$IOKIT_DIR/tools/userland_staging"
[ -x "$STAGING/build_naples.sh" ] || { echo "error: $STAGING/build_naples.sh not found; set IOKIT_DIR" >&2; exit 1; }

NAPLES_SRC="$NAPLES_DIR" "$STAGING/build_naples.sh"

[ "${1:-}" = deploy ] || exit 0
HOST="${DEPLOY_HOST:-root@10.0.0.142}"
GSROOT="$(cd "$STAGING/libc_build/gnustep/root/usr/GNUstep/System" && pwd -P)"
tar -C "$GSROOT/Applications" -cf - Naples.app Milan.app |
    ssh "$HOST" 'rm -rf /Applications/Naples.app /Applications/Milan.app && tar -C /Applications -xf -'
echo "deployed Naples.app and Milan.app to $HOST"
