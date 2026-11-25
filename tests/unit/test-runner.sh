#!/bin/sh
# Unit tests for the unit-test runner itself (task 4.1 — stage0-netboot-image).
#
# Asserts:
#   1. tests/run-unit.sh exists and is POSIX-sh parseable (sh -n);
#   2. in an isolated sandbox, the runner executes every tests/unit/*.sh and
#      *.py and exits 0 when all pass and the required coverage files are
#      present;
#   3. the runner exits non-zero when any unit test fails;
#   4. the runner exits non-zero when a required coverage area's test file is
#      absent (the coverage assertion, not merely "tests exist").
#
# Runs under any POSIX sh. Invoke with: sh tests/unit/test-runner.sh

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/../.." && pwd)
RUNNER="$REPO_ROOT/tests/run-unit.sh"

PASS=0
FAIL=0

pass() {
    PASS=$((PASS + 1))
    printf 'ok: %s\n' "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n' "$1"
}

TMPROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$TMPROOT"' EXIT HUP INT TERM

RUNNER_OK=0
if [ ! -f "$RUNNER" ]; then
    fail "tests/run-unit.sh is missing"
elif ! sh -n "$RUNNER"; then
    fail "tests/run-unit.sh is not POSIX-sh parseable (sh -n)"
else
    pass "tests/run-unit.sh exists and is POSIX-sh parseable"
    RUNNER_OK=1
fi

if [ "$RUNNER_OK" -eq 1 ]; then
    # write_stubs <unit-dir>: minimal green stubs named to satisfy the three
    # required coverage areas plus a couple of extra passing files.
    write_stubs() {
        ud=$1
        printf '#!/bin/sh\nexit 0\n' > "$ud/test-adapter.sh"      # config->argv
        printf '#!/bin/sh\nexit 0\n' > "$ud/test-proxyprop.sh"    # proxy env
        printf 'import sys\nsys.exit(0)\n' > "$ud/test-config.py"  # schema
        printf '#!/bin/sh\nexit 0\n' > "$ud/test-extra.sh"
        printf 'import sys\nsys.exit(0)\n' > "$ud/test-extra2.py"
    }

    # Scenario A: all green + coverage present -> exit 0.
    sb="$TMPROOT/sb_allpass"
    mkdir -p "$sb/unit"
    cp "$RUNNER" "$sb/run-unit.sh"
    write_stubs "$sb/unit"
    if (cd "$TMPROOT" && sh "$sb/run-unit.sh" >"$sb/out" 2>&1); then
        pass "runner exits 0 when all tests pass and coverage is present"
    else
        fail "runner should exit 0 when all tests pass (output below)"
        cat "$sb/out"
    fi

    # Scenario B: one failing test -> non-zero and a FAIL line.
    sb="$TMPROOT/sb_fail"
    mkdir -p "$sb/unit"
    cp "$RUNNER" "$sb/run-unit.sh"
    write_stubs "$sb/unit"
    printf '#!/bin/sh\nexit 1\n' > "$sb/unit/test-fail.sh"
    if sh "$sb/run-unit.sh" >"$sb/out" 2>&1; then
        fail "runner should exit non-zero when a unit test fails"
    else
        pass "runner exits non-zero when a unit test fails"
    fi
    if grep -q 'test-fail.sh.*FAIL' "$sb/out"; then
        pass "runner reports FAIL for the failing test"
    else
        fail "runner did not report FAIL for the failing test"
    fi

    # Scenario C: required coverage file removed -> non-zero + coverage FAIL.
    sb="$TMPROOT/sb_nocov"
    mkdir -p "$sb/unit"
    cp "$RUNNER" "$sb/run-unit.sh"
    write_stubs "$sb/unit"
    rm -f "$sb/unit/test-config.py"   # schema-validation coverage gone
    if sh "$sb/run-unit.sh" >"$sb/out" 2>&1; then
        fail "runner should exit non-zero when a required coverage file is absent"
    else
        pass "runner exits non-zero when a required coverage file is absent"
    fi
    if grep -q 'coverage: FAIL' "$sb/out"; then
        pass "runner reports a coverage failure"
    else
        fail "runner did not report a coverage failure"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
