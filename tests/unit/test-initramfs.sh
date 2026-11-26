#!/bin/sh
# Unit tests for the stage0 initramfs feature (task 3.3 — stage0-netboot-image).
#
# Asserts:
#   1. stage0/features.d/stage0.files bakes the stage0 apkovl
#      (/stage0.apkovl.tar.gz) rather than individual payload/tool paths;
#   2. the build helper's plan stages the payload into the apkovl and emits
#      `chmod +x` for menu/disk-prep/rescue/stage0-main/stage1-install/
#      reinstall-adapter + `tar -czf` for the apkovl;
#   3. the mkinitfs command uses `-F` with the `base` + `stage0` feature;
#   4. DRY_RUN=1 performs no staging/tar and no mkinitfs.
#
# Runs under any POSIX sh. Invoke with: sh tests/unit/test-initramfs.sh

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/../.." && pwd)
FILES_LIST="$REPO_ROOT/stage0/features.d/stage0.files"
BUILD_HELPER="$REPO_ROOT/stage0/build-initramfs.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n       %s\n' "$1" "$2"; }

assert_eq() { # name expected actual
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2] got [$3]"; fi
}

assert_return_ok() { # name status
    if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1" "expected status 0 got $2"; fi
}

assert_return_fail() { # name status
    if [ "$2" -ne 0 ]; then pass "$1"; else fail "$1" "expected non-zero status got $2"; fi
}

assert_contains() { # name needle haystack
    case "$3" in
        *"$2"*) pass "$1" ;;
        *) fail "$1" "expected output to contain [$2]" ;;
    esac
}

# Source the build helper. (RED phase: when build-initramfs.sh is absent, the
# functions stay undefined and the plan tests fail explicitly.)
if [ -r "$BUILD_HELPER" ]; then
    . "$BUILD_HELPER"
fi

type build_initramfs_plan >/dev/null 2>&1 \
    && type build_initramfs_run >/dev/null 2>&1
assert_return_ok "build-initramfs defines plan + run helpers" "$?"

# ---------------------------------------------------------------------------
# (1) .files list completeness
# ---------------------------------------------------------------------------

if [ -r "$FILES_LIST" ]; then
    files=$(sed -e '/^[[:space:]]*$/d' -e '/^[[:space:]]*#/d' "$FILES_LIST")
    pass ".files list is present and readable"
else
    files=''
    fail ".files list is present and readable" "missing $FILES_LIST"
fi

required_paths="
/stage0.apkovl.tar.gz
"

for p in $required_paths; do
    assert_contains ".files references $p" "$p" "$files"
done

# ---------------------------------------------------------------------------
# Plan seams + (2) chmod normalization, (3) mkinitfs feature list
# ---------------------------------------------------------------------------

tmpdir=$(mktemp -d) || exit 1
export REPO_ROOT
export TARGET_ROOT="$tmpdir/root"
export MKINITFS_OUT="$tmpdir/initramfs"
export KERNEL_VERSION="6.12.119-0-lts"
export APKOVL_STAGE="$tmpdir/stage"
export APKOVL_OUT="$tmpdir/apkovl.tar.gz"

plan=$(build_initramfs_plan 2>"$tmpdir/plan.err"); st=$?
assert_return_ok "build_initramfs_plan returns 0" "$st"

for exe in menu disk-prep rescue stage0-main stage1-install reinstall-adapter; do
    assert_contains "plan chmods +x $exe" \
        "chmod +x $APKOVL_STAGE/usr/local/sbin/$exe" "$plan"
done

assert_contains "plan chmods +x the boot hook" \
    "chmod +x $APKOVL_STAGE/etc/local.d/stage0.start" "$plan"
assert_contains "plan chmods +x stage1.start" \
    "chmod +x $APKOVL_STAGE/stage1/etc/local.d/stage1.start" "$plan"

assert_contains "plan packages the payload as an apkovl" \
    "tar -czf $APKOVL_OUT -C $APKOVL_STAGE ." "$plan"

assert_contains "plan enables the local service" \
    "ln -s /etc/init.d/local $APKOVL_STAGE/etc/runlevels/default/local" "$plan"

assert_contains "plan runs mkinitfs" "mkinitfs " "$plan"
assert_contains "mkinitfs uses -F with base + network + cdrom + disk/fs + stage0" "-F 'base network cdrom ata nvme scsi usb virtio ext4 stage0'" "$plan"
case "$plan" in
    *"base"*"stage0"*) pass "feature list carries base and stage0" ;;
    *) fail "feature list carries base and stage0" "missing base/stage0 in: $plan" ;;
esac

# Boot hook: the static local.d entry (copied by the install map) takes over
# the console and execs the orchestrator.
hook_file="$REPO_ROOT/stage0/payload/etc/local.d/stage0.start"
if [ -r "$hook_file" ]; then
    hook=$(cat "$hook_file")
    pass "boot hook file is present"
    assert_contains "hook defaults TERM to linux" "export TERM=linux" "$hook"
    assert_contains "hook auto-detects linux for VGA consoles" "tty[0-9]*) _term=linux" "$hook"
    assert_contains "hook auto-detects vt100 for serial consoles" "*) _term=vt100" "$hook"
    assert_contains "hook sizes the terminal before dialog" "timeout 5 resize" "$hook"
    assert_contains "hook falls back to 80 columns when size is unknown" "COLUMNS=80" "$hook"
    assert_contains "hook disables getty" "killall getty" "$hook"
    assert_contains "hook execs the orchestrator" "exec /usr/local/sbin/stage0-main" "$hook"
else
    fail "boot hook file is present" "missing $hook_file"
fi
assert_contains "plan stages the boot hook" "/etc/local.d/stage0.start" "$plan"

# ---------------------------------------------------------------------------
# (4) DRY_RUN=1 performs no install / no mkinitfs
# ---------------------------------------------------------------------------

rm -rf "$TARGET_ROOT" "$MKINITFS_OUT" "$APKOVL_STAGE" "$APKOVL_OUT"
export DRY_RUN=1
build_initramfs_run > "$tmpdir/dry.out" 2> "$tmpdir/dry.err"; st=$?
unset DRY_RUN
assert_return_ok "dry-run build returns 0" "$st"

if [ -e "$TARGET_ROOT" ]; then
    fail "DRY_RUN=1 installs nothing" "unexpected target root: $TARGET_ROOT"
else
    pass "DRY_RUN=1 installs nothing"
fi

if [ -e "$APKOVL_OUT" ]; then
    fail "DRY_RUN=1 creates no apkovl" "unexpected apkovl: $APKOVL_OUT"
else
    pass "DRY_RUN=1 creates no apkovl"
fi

if [ -e "$MKINITFS_OUT" ]; then
    fail "DRY_RUN=1 runs no mkinitfs" "unexpected output: $MKINITFS_OUT"
else
    pass "DRY_RUN=1 runs no mkinitfs"
fi

assert_contains "dry-run still emits the chmod plan" \
    "chmod +x $APKOVL_STAGE/usr/local/sbin/menu" "$(cat "$tmpdir/dry.out")"

rm -rf "$tmpdir"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
