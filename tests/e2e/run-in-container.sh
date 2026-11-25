#!/bin/sh
# Wrapper: run the end-to-end suite inside the privileged build container.
#
# The E2E tests need QEMU (bundled in the build container) plus root (loop
# devices for the modloop/module tree and the QEMU virtual disk), which the
# build container provides under `docker run --privileged`. This wrapper
# reproduces exactly that invocation, mounting the repository at /repo and
# running the runner there.
#
# Usage (from anywhere):
#   sh tests/e2e/run-in-container.sh
#
# Equivalent manual invocation (from the repo root):
#   docker run --rm --privileged -v "$PWD":/repo --entrypoint sh netinstall-stage0 \
#       -c 'cd /repo && sh tests/e2e/run-e2e.sh'
#
# Overridable:
#   NETINSTALL_IMAGE   container image (default netinstall-stage0:latest)

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/../.." && pwd)
IMAGE=${NETINSTALL_IMAGE:-netinstall-stage0:latest}

if ! command -v docker >/dev/null 2>&1; then
    printf 'docker is unavailable; cannot run the e2e suite in a container.\n' >&2
    printf 'Run directly instead: sh %s/run-e2e.sh\n' "$SCRIPT_DIR" >&2
    exit 1
fi

printf 'running e2e suite in container image %s (repo: %s)\n' "$IMAGE" "$REPO_ROOT"
exec docker run --rm --privileged \
    -v "$REPO_ROOT":/repo \
    --entrypoint sh "$IMAGE" \
    -c 'cd /repo && sh tests/e2e/run-e2e.sh'
