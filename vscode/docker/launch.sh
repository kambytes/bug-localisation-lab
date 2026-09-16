#!/bin/bash
# =============================================================================
# launch.sh - run the VS Code build in this image.
#
#   docker exec -it <container> launch.sh [extra vscode args]
#
# The desktop stays up when VS Code quits, so this can be re-run as often as you
# like without restarting the container.
# =============================================================================
set -uo pipefail

# shellcheck disable=SC1091
. /etc/profile.d/nvm.sh

# NODE_OPTIONS carries --max-old-space-size for the BUILD. Electron rejects it
# ("Most NODE_OPTIONs are not supported in packaged apps"). VS Code's own
# resources/darwin/bin/code.sh unsets it before launching for the same reason.
unset NODE_OPTIONS

VSCODE_DIR="${VSCODE_DIR:-$HOME/vscode}"
export DISPLAY="${DISPLAY:-:99}"

if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
  echo "ERROR: no X server on DISPLAY=$DISPLAY. Is the container's entrypoint running?" >&2
  exit 1
fi

cd "$VSCODE_DIR" || exit 1
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo "Launching VS Code at commit $SHA"

# A fresh profile per commit, so state written by one commit cannot influence
# the verdict on the next.
#   --no-sandbox            Chromium's sandbox cannot work unprivileged here
#   --disable-gpu           no GPU is exposed to the container
#   --disable-dev-shm-usage /dev/shm is 64 MB in Docker; the renderer crashes
exec ./scripts/code.sh \
  --no-sandbox \
  --disable-gpu \
  --disable-dev-shm-usage \
  --user-data-dir "/tmp/vscode-profile-$SHA" \
  --extensions-dir "/tmp/vscode-exts-$SHA" \
  "$@"
