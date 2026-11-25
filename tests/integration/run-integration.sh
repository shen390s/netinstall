#!/bin/sh
# Integration test runner for stage0-netboot-image (task 4.2).
#
# Executes every tests/integration/test-*.sh in turn, prints a per-file
# PASS/FAIL/SKIP line, and exits 0 only if no test FAILS and the three required
# coverage areas from design.md "Testing Strategy" each have a green test file:
#   - disk install on a loop device : test-diskinstall.sh  (req 6.1)
#   - stage1 artifact injection      : test-stage1inject.sh (req 7.1)
#   - proxy patch application        : test-proxypatch.sh   (req 8.2)
#
# "Green" means the required file was present AND exited 0. A test that exits 3
# reports SKIP (its required piece — losetup/mount/root — is unavailable in the
# current environment); SKIPs never fail the run, but they also do not satisfy
# the coverage assertion (a skipped area is reported as such, not as a missing
# test).
#
# These are REAL integration tests: run them inside the privileged build
# container (as root) so loop devices and mounts work. From the repo root:
#
#   docker run --rm --privileged -v "$PWD":/repo --entrypoint sh netinstall-stage0 \
#       -c 'cd /repo && sh tests/integration/run-integration.sh'
#
# or via the bundled wrapper: sh tests/integration/run-in-container.sh
#
# Runs under any POSIX sh, from any working directory (paths are resolved
# relative to this script, not the current directory).

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
INTEGRATION_DIR="$SCRIPT_DIR"

tmpdir=$(mktemp -d) || exit 1
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM
out="$tmpdir/test.out"
passed="$tmpdir/passed.txt"
skipped="$tmpdir/skipped.txt"
: > "$passed"
: > "$skipped"

count=0
failed=0
skipcount=0

for f in "$INTEGRATION_DIR"/test-*.sh; do
    [ -e "$f" ] || continue
    count=$((count + 1))
    name=${f##*/}
    printf '%-24s ' "$name"
    sh "$f" >"$out" 2>&1
    rc=$?
    case "$rc" in
        0)
            printf 'PASS\n'
            printf '%s\n' "$name" >> "$passed"
            ;;
        3)
            printf 'SKIP\n'
            printf '%s\n' "$name" >> "$skipped"
            skipcount=$((skipcount + 1))
            sed 's/^/    /' "$out"
            ;;
        *)
            printf 'FAIL (exit %s)\n' "$rc"
            cat "$out"
            failed=$((failed + 1))
            ;;
    esac
done

# Coverage assertion: each required area must have at least one green test
# file. check_coverage_group(label, filename) appends the label to "missing"
# when the file is neither passed nor skipped.
missing=""
skipped_areas=""
check_coverage_group() {
    label=$1
    candidate=$2
    if grep -qFx "$candidate" "$passed"; then
        return 0
    fi
    if grep -qFx "$candidate" "$skipped"; then
        skipped_areas="$skipped_areas $label"
        return 0
    fi
    missing="$missing $label"
    return 1
}

check_coverage_group "disk-install(test-diskinstall.sh)" test-diskinstall.sh
check_coverage_group "stage1-inject(test-stage1inject.sh)" test-stage1inject.sh
check_coverage_group "proxy-patch(test-proxypatch.sh)" test-proxypatch.sh

printf '\n%d/%d integration test files passed' "$((count - failed - skipcount))" "$count"
if [ "$skipcount" -gt 0 ]; then
    printf ' (%d skipped)' "$skipcount"
fi
printf '\n'

if [ -n "$skipped_areas" ]; then
    printf 'coverage: SKIPPED area(s):%s\n' "$skipped_areas"
fi
if [ -n "$missing" ]; then
    printf 'coverage: FAIL (missing/not-green required test file(s):%s)\n' "$missing"
elif [ -z "$skipped_areas" ]; then
    printf 'coverage: OK (disk-install, stage1-inject, proxy-patch)\n'
fi

if [ "$failed" -ne 0 ] || [ -n "$missing" ]; then
    printf 'integration test run: FAILED\n'
    exit 1
fi

printf 'integration test run: PASSED\n'
exit 0
