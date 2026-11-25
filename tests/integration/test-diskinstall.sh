#!/bin/sh
# Integration test: disk-prep setup-disk command (task 4.2 — stage0-netboot-image).
#
# Container-runnable scope: run the REAL disk-prep (not dry-run) for the BIOS
# firmware mode against a disposable loop device and assert that it emits and
# executes a syntactically valid `setup-disk` command. Specifically:
#   1. `setup-disk` was invoked (the generated command appears in the output);
#   2. setup-disk's output does NOT contain "Illegal option" (no `-B`-style
#      syntax regression).
#
# Full partition + grub-MBR + OS verification is NOT feasible on a loop device:
# Alpine `setup-disk`'s `is_available_disk` check excludes loop devices
# (/sys/block/loopN/device does not exist), so it prints "No disks found."
# instead of partitioning. That outcome is ACCEPTABLE here — it proves the
# command parsed cleanly and reached setup-disk's disk scan. Full
# partition/grub/OS verification is covered by the E2E suite (task 4.3, QEMU
# virtual disk).
#
# The loop device is exposed through a synthetic /dev/disk/by-id symlink so the
# disk-prep wrong-disk guard round-trips exactly as in production. The loop
# device is always detached and the temp files removed on exit (idempotent).
#
# SKIPs (exit 3, not fail) when root, losetup, or dd is unavailable.
# Requires running inside the privileged build container.
# Invoke with: sh tests/integration/test-diskinstall.sh

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/../.." && pwd)
DISK_PREP="$REPO_ROOT/stage0/payload/usr/local/sbin/disk-prep"
DISK_LIB="$REPO_ROOT/stage0/payload/usr/local/sbin/lib/disk.sh"

# --- prerequisite gate (skip, not fail) -------------------------------------
if [ "$(id -u 2>/dev/null)" != "0" ]; then
    printf 'SKIP: requires root for losetup\n'
    exit 3
fi
for tool in losetup dd; do
    command -v "$tool" >/dev/null 2>&1 || { printf 'SKIP: %s is unavailable\n' "$tool"; exit 3; }
done
[ -r "$DISK_PREP" ] || { printf 'SKIP: disk-prep missing\n'; exit 3; }

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n       %s\n' "$1" "$2"; }

tmpdir=$(mktemp -d) || exit 1
img="$tmpdir/disk.img"
loop=""
loop_attached=0

cleanup() {
    [ "$loop_attached" = 1 ] && losetup -d "$loop" 2>/dev/null
    rm -rf "$tmpdir"
}
trap cleanup EXIT HUP INT TERM

# --- fixture: sparse disk + loop device + by-id symlink ---------------------
dd if=/dev/zero of="$img" bs=1M count=256 status=none 2>"$tmpdir/dd.err" \
    || { printf 'SKIP: cannot create sparse disk image (%s)\n' "$(cat "$tmpdir/dd.err")"; exit 3; }

loop=$(losetup -f 2>/dev/null) || { printf 'SKIP: no free loop device\n'; exit 3; }
losetup -P "$loop" "$img" 2>"$tmpdir/losetup.err" \
    || { printf 'SKIP: losetup failed (%s)\n' "$(cat "$tmpdir/losetup.err")"; exit 3; }
loop_attached=1

devname=${loop#/dev/}
byid="$tmpdir/by-id"
mkdir -p "$byid"
ln -s "../../$devname" "$byid/ata-NetInstall_TestDisk"
disk_id="$byid/ata-NetInstall_TestDisk"

# --- run the REAL disk-prep (BIOS) -----------------------------------------
DISK_PREP_DISK_LIB="$DISK_LIB"
export DISK_PREP_DISK_LIB
. "$DISK_PREP"

# DRY_RUN is deliberately unset so disk_prep_run executes the generated plan.
# The exit status is intentionally NOT asserted: on a loop device, Alpine
# `setup-disk` excludes the disk ("No disks found.") and the trailing
# `grub-install` also fails to resolve the overlay device — both acceptable
# container limitations, not disk-prep regressions.
disk_prep_run "$disk_id" bios "$byid" >"$tmpdir/diskprep.out" 2>&1

# --- assert the setup-disk command was emitted and is syntactically valid ---
if grep -Fq 'setup-disk -m sys' "$tmpdir/diskprep.out"; then
    pass "disk-prep invoked setup-disk (command emitted)"
else
    fail "disk-prep invoked setup-disk (command emitted)" "setup-disk command not found in output"
    sed 's/^/       | /' "$tmpdir/diskprep.out"
fi

if grep -Fq 'Illegal option' "$tmpdir/diskprep.out"; then
    fail "setup-disk command is syntactically valid" "setup-disk reported an illegal option"
    sed 's/^/       | /' "$tmpdir/diskprep.out"
else
    pass "setup-disk command is syntactically valid"
fi

# Loop-device exclusion is an acceptable outcome, not a failure: setup-disk
# cannot partition a loop device because /sys/block/loopN/device is absent.
if grep -Fq 'No disks found' "$tmpdir/diskprep.out"; then
    printf '       (setup-disk excluded the loop device: "No disks found" — acceptable; full partition/grub/OS verification is E2E, task 4.3)\n'
fi

# --- cleanup (trap also runs, but be explicit) ------------------------------
losetup -d "$loop" 2>/dev/null; loop_attached=0

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
