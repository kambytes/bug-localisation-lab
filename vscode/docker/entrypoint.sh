#!/bin/bash
# =============================================================================
# entrypoint.sh - bring up the virtual display, then keep the container alive.
#
# Runs as PID 1, so these services live as long as the container. Backgrounding
# them from a `docker exec` shell does NOT work - they are killed when that exec
# session ends.
#
# Ports and password match VS Code's own .devcontainer/README.md: "The default
# VNC password is `vscode`. The VNC server runs on port `5901` and a web client
# is available on port `6080`."
# =============================================================================
set -uo pipefail

export DISPLAY="${DISPLAY:-:99}"
GEOMETRY="${VNC_GEOMETRY:-1440x900x24}"

Xvfb "$DISPLAY" -screen 0 "$GEOMETRY" -ac >/tmp/xvfb.log 2>&1 &

# Wait for the X server to accept connections rather than sleeping blindly.
for _ in $(seq 1 40); do
  xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break
  sleep 0.5
done
if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
  echo "ERROR: Xvfb did not come up. Log follows." >&2
  cat /tmp/xvfb.log >&2
  exit 1
fi

fluxbox >/tmp/fluxbox.log 2>&1 &

x11vnc -display "$DISPLAY" -forever -shared \
       -rfbauth "$HOME/.vncpass" -rfbport 5901 -listen 0.0.0.0 \
       >/tmp/x11vnc.log 2>&1 &

websockify --web=/usr/share/novnc 6080 localhost:5901 >/tmp/novnc.log 2>&1 &

COMMIT_FILE="$HOME/COMMIT"
cat <<MSG

Desktop ready$( [ -f "$COMMIT_FILE" ] && echo " for commit $(cut -c1-7 "$COMMIT_FILE")" ).
  Browser:     http://localhost:6080/vnc.html      password: vscode
  VNC client:  vnc://localhost:5901                password: vscode

Launch the editor with:
  docker exec -it <container> launch.sh

MSG

sleep infinity
