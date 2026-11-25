#!/bin/sh
# E2E: menu -> disk-prep -> stage1 -> firstboot chain (stage0-netboot-image,
# task 4.3 — requirements 1.4, 2.3, 3.3, 7.2, 9.2).
#
# Boots the REAL stage0 kernel + initramfs in QEMU with a REAL virtual disk
# attached and asserts the two parts of the chain that are reachable in this
# build container:
#   1. the guest reaches userspace init (the stage0 image loads into memory);
#   2. the attached disk is byte-for-byte UNMODIFIED after boot — the full-wipe
#      confirmation is the only path to disk-prep, and booting never writes
#      before that confirmation (req 1.4, 2.3, 3.3);
#   3. the built initramfs carries the chain-driving payload (orchestrator,
#      disk-prep, stage1-install, and the stage1 firstboot hook) (req 7.1/7.2).
#
# RESIDUAL GAP (documented, not faked): the full boot -> dialog menu -> disk-prep
# -> stage1-install -> reboot -> stage1 firstboot sequence is SKIPped. Driving it
# in QEMU requires the booted stage0 to reach the menu, which in turn requires
# (a) a reachable Alpine apk repository so initramfs-init can `apk add
# alpine-base` before switch_root, (b) a modloop module bundle, and (c) a ncurses
# terminfo database plus setup-disk/httpd baked into the initramfs. None of those
# are materialized by the current build container/pipeline (tasks 1.1/3.3/3.5;
# out of scope for 4.3). The test therefore exits 3 (SKIP) for the chain while
# still asserting the reachable safety + payload properties above.

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/../.." && pwd)
E2E_DIR="$SCRIPT_DIR"
. "$E2E_DIR/lib.sh"

PASS=0
FAIL=0
QEMU_PID=
TMPDIR=$(mktemp -d) || exit 1
trap 'e2e_cleanup' EXIT HUP INT TERM
e2e_cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
    rm -rf "$TMPDIR"
}

e2e_require qemu-system-x86_64 "VM runner (E2E boot)"
e2e_require sha256sum "disk integrity comparison"
e2e_skip_unless /boot/vmlinuz-lts "stage0 kernel (linux-lts)"
e2e_skip_unless "$REPO_ROOT/stage0/build-initramfs.sh" "initramfs builder"

INITRD="$TMPDIR/initramfs-stage0"
e2e_info "building stage0 initramfs"
if ! e2e_build_initramfs "$INITRD"; then
    e2e_fail "initramfs build failed"
    exit 1
fi

# --- (3) payload carries the chain-driving components ----------------------
ROOTFS="$TMPDIR/rootfs"
e2e_extract_initramfs "$INITRD" "$ROOTFS" || { e2e_fail "initramfs extract failed"; exit 1; }
for p in usr/local/sbin/stage0-main usr/local/sbin/disk-prep usr/local/sbin/stage1-install stage1/etc/local.d/stage1.start; do
    e2e_assert_present "chain payload: $p" "$ROOTFS/$p"
done

# --- create a real virtual disk with a recognizable, integrity-checked state --
DISK="$TMPDIR/disk.img"
dd if=/dev/zero of="$DISK" bs=1M count=128 2>/dev/null || { e2e_fail "cannot create virtual disk"; exit 1; }
BEFORE=$(sha256sum "$DISK" | awk '{print $1}')

# --- (1) boot with the disk attached; assert userspace init ----------------
LOG="$TMPDIR/boot.log"
e2e_info "booting stage0 with an attached virtual disk (no confirmation)"
e2e_qemu_boot "$LOG" 45 "Alpine Init" /boot/vmlinuz-lts "$INITRD" "console=ttyS0" \
    -drive file="$DISK",format=raw,if=virtio
BOOTLOG=$(cat "$LOG" 2>/dev/null)
e2e_assert_contains "stage0 kernel boots with disk attached" "Linux version" "$BOOTLOG"
e2e_assert_contains "stage0 reaches userspace init with disk attached" "Alpine Init" "$BOOTLOG"

# --- (2) the disk is untouched before full-wipe confirmation ---------------
AFTER=$(sha256sum "$DISK" | awk '{print $1}')
if [ "$BEFORE" = "$AFTER" ]; then
    PASS=$((PASS + 1))
    printf 'PASS: %s\n' "boot writes nothing to the disk before confirmation (req 1.4/2.3/3.3)"
else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n       disk changed during boot (before=$BEFORE after=$AFTER)\n' \
        "boot must not write the disk before confirmation"
fi

# --- residual gap: the full chain is environmentally infeasible ------------
e2e_skip "full menu -> disk-prep -> stage1 -> firstboot boot chain (requires apk repo + modloop + terminfo + setup-disk/httpd in initramfs; see run-e2e.sh residual gaps)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
exit 3
