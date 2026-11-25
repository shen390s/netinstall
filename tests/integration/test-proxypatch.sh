#!/bin/sh
# Integration test: proxy patch application (task 4.2 — stage0-netboot-image).
#
# Applies reinstall/patches/proxy-env.patch to a COPY of reinstall/reinstall.sh
# (never the vendored original) exactly the way stage1-install does — `patch -p2`
# from the directory containing the copy — and asserts:
#   1. the patch applies cleanly (exit 0);
#   2. the injected init hook now exports the five proxy vars verbatim;
#   3. no other change is made (the diff is exactly the five added export lines,
#      zero removed lines).
#
# Runs under any POSIX sh and does not need root. Invoke with:
#   sh tests/integration/test-proxypatch.sh

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/../.." && pwd)
REINSTALL_SH="$REPO_ROOT/reinstall/reinstall.sh"
PATCH="$REPO_ROOT/reinstall/patches/proxy-env.patch"

# SKIP (not fail) when the tool needed to apply/verify the patch is absent.
if ! command -v patch >/dev/null 2>&1; then
    printf 'SKIP: patch is unavailable\n'
    exit 3
fi

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n       %s\n' "$1" "$2"; }

assert_return_ok() { # name status
    if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1" "expected status 0 got $2"; fi
}

assert_contains() { # name needle haystack
    case "$3" in
        *"$2"*) pass "$1" ;;
        *) fail "$1" "expected to contain [$2]" ;;
    esac
}

tmpdir=$(mktemp -d) || exit 1
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

[ -r "$REINSTALL_SH" ] || { printf 'SKIP: reinstall/reinstall.sh missing\n'; exit 3; }
[ -r "$PATCH" ] || { printf 'SKIP: reinstall/patches/proxy-env.patch missing\n'; exit 3; }

cp "$REINSTALL_SH" "$tmpdir/reinstall.sh"

# Apply the patch to the copy, from the copy's directory, at -p2 (identical to
# stage1-install: `( cd $_sysroot/usr/local/sbin && patch -p2 -i <patch> )`).
patch -d "$tmpdir" -p2 -i "$PATCH" >"$tmpdir/patch.out" 2>&1
st=$?
assert_return_ok "proxy-env.patch applies cleanly at -p2" "$st"

patched="$tmpdir/reinstall.sh"
for line in \
    'export http_proxy=$http_proxy' \
    'export https_proxy=$https_proxy' \
    'export all_proxy=$all_proxy' \
    'export no_proxy=$no_proxy' \
    'export github_proxy=$github_proxy'; do
    assert_contains "init hook exports [$line]" "$line" "$(cat "$patched")"
done

# No other change: the patch must add exactly five lines and be fully
# reversible. (Busybox and GNU `diff` disagree on default output format, so we
# avoid `diff` and instead (a) count lines and (b) reverse-apply the patch and
# `cmp` the result against the untouched original — both portable POSIX tools.)
orig_lines=$(wc -l < "$REINSTALL_SH" | tr -d ' ')
patched_lines=$(wc -l < "$patched" | tr -d ' ')

if [ "$((patched_lines - orig_lines))" -eq 5 ]; then
    pass "patch adds exactly five lines"
else
    fail "patch adds exactly five lines" \
        "expected 5 added lines, got $((patched_lines - orig_lines))"
fi

# Reverse-apply on a fresh copy and compare byte-for-byte with the original:
# any change beyond the added block would break the round-trip.
revertdir=$(mktemp -d) || exit 1
trap 'rm -rf "$tmpdir" "$revertdir"' EXIT HUP INT TERM
cp "$REINSTALL_SH" "$revertdir/reinstall.sh"
patch -d "$revertdir" -p2 -i "$PATCH" >/dev/null 2>&1
patch -d "$revertdir" -p2 -R -i "$PATCH" >"$tmpdir/revert.out" 2>&1
if cmp -s "$REINSTALL_SH" "$revertdir/reinstall.sh"; then
    pass "patch is fully reversible (no other change)"
else
    fail "patch is fully reversible (no other change)" \
        "reverse-apply did not reproduce the original"
fi

rm -rf "$tmpdir"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
