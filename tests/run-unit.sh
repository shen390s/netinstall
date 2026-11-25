#!/bin/sh
# Unit test runner for stage0-netboot-image (task 4.1).
#
# Executes every tests/unit/*.sh and tests/unit/*.py in turn, prints a per-file
# PASS/FAIL line, and exits 0 only if every file passes AND the three required
# coverage areas from design.md "Testing Strategy" each have a green test file:
#   - config -> argv mapping : test-adapter.sh            (req 4.2)
#   - schema validation      : test-config.py             (req 2.2)
#   - proxy env construction : test-proxyprop.sh or
#                              test-helpers.sh            (req 8.2)
#
# "Green" means the required file was present AND exited 0.
#
# Runs under any POSIX sh, from any working directory (paths are resolved
# relative to this script, not the current directory). Invoke from the repo
# root with:
#   sh tests/run-unit.sh

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
UNIT_DIR="$SCRIPT_DIR/unit"

tmpdir=$(mktemp -d) || exit 1
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM
out="$tmpdir/test.out"
passed="$tmpdir/passed.txt"
: > "$passed"

count=0
failed=0

for f in "$UNIT_DIR"/*.sh "$UNIT_DIR"/*.py; do
    [ -e "$f" ] || continue
    count=$((count + 1))
    name=${f##*/}
    printf '%-24s ' "$name"
    if [ "${f##*.}" = "py" ]; then
        python3 "$f" >"$out" 2>&1
        rc=$?
    else
        sh "$f" >"$out" 2>&1
        rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
        printf 'PASS\n'
        printf '%s\n' "$name" >> "$passed"
    else
        printf 'FAIL (exit %s)\n' "$rc"
        cat "$out"
        failed=$((failed + 1))
    fi
done

# Coverage assertion: each required area must have at least one green test
# file. check_coverage_group(label, alt1[, alt2...]) appends the label to
# "missing" when none of the alternative basenames is in the passed list.
missing=""
check_coverage_group() {
    label=$1
    shift
    for candidate in "$@"; do
        if grep -qFx "$candidate" "$passed"; then
            return 0
        fi
    done
    missing="$missing $label"
    return 1
}

check_coverage_group "config->argv(test-adapter.sh)" test-adapter.sh
check_coverage_group "schema(test-config.py)" test-config.py
check_coverage_group "proxy(test-proxyprop.sh|test-helpers.sh)" test-proxyprop.sh test-helpers.sh

printf '\n%d/%d unit test files passed\n' "$((count - failed))" "$count"
if [ -n "$missing" ]; then
    printf 'coverage: FAIL (missing/not-green required test file(s):%s)\n' "$missing"
else
    printf 'coverage: OK (config->argv, schema, proxy)\n'
fi

if [ "$failed" -ne 0 ] || [ -n "$missing" ]; then
    printf 'unit test run: FAILED\n'
    exit 1
fi

printf 'unit test run: PASSED\n'
exit 0
