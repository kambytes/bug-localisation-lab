#!/bin/bash
# =============================================================================
# bisect-step.sh - one step of a bisect: build the commit, run it, prune the
#                  previous one.
#
#   vscode/docker/bisect-step.sh <commit-sha>
#   vscode/docker/bisect-step.sh --clean      remove every version image, keep base
#   vscode/docker/bisect-step.sh --status     what is running, and disk in use
#
# Runs on the Mac, not in the container. The prune is the point: at under 50 GB
# free, forgetting to remove the previous image is what ends a bisect early.
# =============================================================================
set -euo pipefail

DOCKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_IMAGE="vscode:base"
CONTAINER="vsc"

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# --- subcommands --------------------------------------------------------------
case "${1:-}" in
  ""|-h|--help)
    usage; exit 0 ;;
  --status)
    echo "== container =="
    docker ps --filter "name=^/${CONTAINER}$" --format '{{.Names}}  {{.Image}}  {{.Status}}' || true
    echo
    echo "== vscode images =="
    docker images 'vscode' --format '{{.Repository}}:{{.Tag}}  {{.Size}}' || true
    echo
    docker system df
    exit 0 ;;
  --clean)
    echo "Removing every vscode version image except $BASE_IMAGE"
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker images 'vscode' --format '{{.Repository}}:{{.Tag}}' \
      | grep -v "^${BASE_IMAGE}$" \
      | while read -r img; do echo "  rmi $img"; docker rmi "$img" >/dev/null 2>&1 || true; done
    docker system df
    exit 0 ;;
esac

COMMIT="$1"
# Accept a short or full SHA; normalise the tag to 7 characters.
SHORT="$(printf '%s' "$COMMIT" | cut -c1-7)"
IMAGE="vscode:${SHORT}"

# --- preconditions ------------------------------------------------------------
if ! docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
  echo "ERROR: $BASE_IMAGE does not exist. Build it once for this bug:" >&2
  echo "  docker build -f $DOCKER_DIR/DockerfileBase \\" >&2
  echo "    --build-arg BASE_COMMIT=<good-endpoint-sha> -t $BASE_IMAGE $DOCKER_DIR" >&2
  exit 1
fi

PREV_IMAGE="$(docker inspect --format '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || true)"

# --- tear down the previous step FIRST ----------------------------------------
# Order matters, and an earlier version of this script had it wrong.
#
# The container is removed before the build, not after, so that a FAILED build
# leaves nothing behind for `docker exec vsc launch.sh` to open. Otherwise the
# editor silently starts at the PREVIOUS commit and you hand git bisect a
# verdict for a commit you never tested - a wrong answer that looks exactly like
# a right one.
#
# The previous image goes too. It has already been judged, so it has no further
# use, and at under 50 GB free the peak disk is what ends a bisect early.
echo "==> Clearing the previous step"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
if [ -n "$PREV_IMAGE" ] && [ "$PREV_IMAGE" != "$IMAGE" ] && [ "$PREV_IMAGE" != "$BASE_IMAGE" ]; then
  echo "    removing $PREV_IMAGE"
  docker rmi "$PREV_IMAGE" >/dev/null 2>&1 || echo "    (could not remove $PREV_IMAGE, continuing)"
fi

# Build cache from previous steps is never reused - COMMIT changes invalidate it
# - but it does accumulate and it is the usual cause of the Docker VM disk
# filling up, which surfaces as "failed to extract layer ... read-only file
# system" during export.
docker builder prune -f >/dev/null 2>&1 || true

# --- build --------------------------------------------------------------------
echo "==> Building $IMAGE from $COMMIT"
if ! docker build \
  -f "$DOCKER_DIR/DockerfileVersion" \
  --build-arg "COMMIT=$COMMIT" \
  -t "$IMAGE" \
  "$DOCKER_DIR"; then
  echo
  echo "BUILD FAILED for $SHORT - do NOT give git bisect a verdict for this commit." >&2
  echo "There is no container running, so nothing can mislead you." >&2
  echo "Disk is the usual cause; check with:  docker system df" >&2
  exit 1
fi

# --- run ----------------------------------------------------------------------
echo "==> Starting container $CONTAINER"
docker run -d --name "$CONTAINER" \
  -p 5901:5901 -p 6080:6080 \
  --shm-size=1g \
  "$IMAGE" >/dev/null

cat <<MSG

==> Ready: $SHORT

  1. Open    http://localhost:6080/vnc.html      password: vscode
  2. Launch  docker exec -it $CONTAINER launch.sh
  3. Try to reproduce the bug, then back in your git bisect terminal:
       git bisect good      (bug absent)
       git bisect bad       (bug present)
       git bisect skip      (would not build / cannot tell)

MSG
