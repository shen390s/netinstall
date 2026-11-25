#!/bin/sh
# Wrapper: run the integration suite inside the privileged build container.
#
# The integration tests need root + real loop devices + mounts, which the build
# container provides under `docker run --privileged`. This wrapper reproduces
# exactly that invocation, mounting the repository read-only at /repo and
# running the runner there.
#
# Usage (from anywhere):
#   sh tests/integration/run-in-container.sh
#
# Equivalent manual invocation (from the repo root):
#   docker run --rm --privileged -v "$PWD":/repo --entrypoint sh netinstall-stage0 \
#       -c 'cd /repo && sh tests/integration/run-integration.sh'
#
# Overridable:
#   NETINSTALL_IMAGE   container image (default netinstall-stage0:latest)

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/../.." && pwd)
IMAGE=${NETINSTALL_IMAGE:-netinstall-stage0:latest}

if ! command -v docker >/dev/null 2>&1; then
    printf 'docker is unavailable; cannot run the integration suite in a container.\n' >&2
    printf 'Run directly instead (root-only pieces will skip): sh %s/run-integration.sh\n' "$SCRIPT_DIR" >&2
    exit 1
fi

printf 'running integration suite in container image %s (repo: %s)\n' "$IMAGE" "$REPO_ROOT"
exec docker run --rm --privileged \
    -v "$REPO_ROOT":/repo \
    --entrypoint sh "$IMAGE" \
    -c 'cd /repo && sh tests/integration/run-integration.sh'
