#!/bin/sh
# Integration tests for the integration-test runner itself (task 4.2 —
# stage0-netboot-image).
#
# Asserts:
#   1. tests/integration/run-integration.sh exists and is POSIX-sh parseable
#      (sh -n);
#   2. in an isolated sandbox, the runner executes every tests/integration/*.sh
#      test and exits 0 when all pass and the three required coverage areas
#      (disk install, stage1 injection, proxy patch) are present;
#   3. the runner exits non-zero when any integration test fails;
#   4. the runner exits non-zero when a required coverage area's test file is
#      absent (the coverage assertion, not merely "tests exist");
#   5. the runner treats exit status 3 as SKIP (not FAIL) — a suite of only
#      SKIPped tests still exits 0 (environment pieces unavailable).
#
# Runs under any POSIX sh. Invoke with: sh tests/integration/test-runner.sh

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/../.." && pwd)
RUNNER="$REPO_ROOT/tests/integration/run-integration.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'ok: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

TMPROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$TMPROOT"' EXIT HUP INT TERM

RUNNER_OK=0
if [ ! -f "$RUNNER" ]; then
    fail "tests/integration/run-integration.sh is missing"
elif ! sh -n "$RUNNER"; then
    fail "tests/integration/run-integration.sh is not POSIX-sh parseable (sh -n)"
else
    pass "tests/integration/run-integration.sh exists and is POSIX-sh parseable"
    RUNNER_OK=1
fi

if [ "$RUNNER_OK" -eq 1 ]; then
    # write_stubs <integration-dir>: minimal green stubs that satisfy the three
    # required coverage areas plus a couple of extra passing files.
    write_stubs() {
        idir=$1
        printf '#!/bin/sh\nexit 0\n' > "$idir/test-diskinstall.sh"   # disk install
        printf '#!/bin/sh\nexit 0\n' > "$idir/test-stage1inject.sh"  # stage1 inject
        printf '#!/bin/sh\nexit 0\n' > "$idir/test-proxypatch.sh"    # proxy patch
        printf '#!/bin/sh\nexit 0\n' > "$idir/test-extra.sh"
    }

    # Scenario A: all green + coverage present -> exit 0.
    sb="$TMPROOT/sb_allpass"
    mkdir -p "$sb"
    cp "$RUNNER" "$sb/run-integration.sh"
    write_stubs "$sb"
    if (cd "$TMPROOT" && sh "$sb/run-integration.sh" >"$sb/out" 2>&1); then
        pass "runner exits 0 when all tests pass and coverage is present"
    else
        fail "runner should exit 0 when all tests pass (output below)"
        cat "$sb/out"
    fi

    # Scenario B: one failing test -> non-zero and a FAIL line.
    sb="$TMPROOT/sb_fail"
    mkdir -p "$sb"
    cp "$RUNNER" "$sb/run-integration.sh"
    write_stubs "$sb"
    printf '#!/bin/sh\nexit 1\n' > "$sb/test-fail.sh"
    if sh "$sb/run-integration.sh" >"$sb/out" 2>&1; then
        fail "runner should exit non-zero when an integration test fails"
    else
        pass "runner exits non-zero when an integration test fails"
    fi
    if grep -q 'test-fail.sh.*FAIL' "$sb/out"; then
        pass "runner reports FAIL for the failing test"
    else
        fail "runner did not report FAIL for the failing test"
    fi

    # Scenario C: required coverage file removed -> non-zero + coverage FAIL.
    sb="$TMPROOT/sb_nocov"
    mkdir -p "$sb"
    cp "$RUNNER" "$sb/run-integration.sh"
    write_stubs "$sb"
    rm -f "$sb/test-proxypatch.sh"   # proxy-patch coverage gone
    if sh "$sb/run-integration.sh" >"$sb/out" 2>&1; then
        fail "runner should exit non-zero when a required coverage file is absent"
    else
        pass "runner exits non-zero when a required coverage file is absent"
    fi
    if grep -q 'coverage: FAIL' "$sb/out"; then
        pass "runner reports a coverage failure"
    else
        fail "runner did not report a coverage failure"
    fi

    # Scenario D: every test SKIPs (exit 3) -> runner exits 0 and reports SKIP.
    sb="$TMPROOT/sb_skip"
    mkdir -p "$sb"
    cp "$RUNNER" "$sb/run-integration.sh"
    write_stubs "$sb"
    for f in "$sb"/test-*.sh; do
        printf '#!/bin/sh\nprintf "SKIP: env unavailable\\n"\nexit 3\n' > "$f"
    done
    if sh "$sb/run-integration.sh" >"$sb/out" 2>&1; then
        pass "runner exits 0 when every test SKIPs"
    else
        fail "runner should exit 0 when every test SKIPs (output below)"
        cat "$sb/out"
    fi
    if grep -q 'SKIP' "$sb/out"; then
        pass "runner reports SKIP for skipped tests"
    else
        fail "runner did not report SKIP for skipped tests"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
