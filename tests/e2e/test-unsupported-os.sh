#!/bin/sh
# E2E: unsupported OS rejection (stage0-netboot-image, task 4.3 — req 4.3).
#
# Builds the REAL stage0 initramfs, extracts it, and drives the REAL baked
# `menu` core and `reinstall-adapter` (the exact scripts the booted image runs —
# not mocks) against an OS selection absent from the OS catalog. Asserts:
#   1. the menu core rejects the unsupported OS: non-zero exit, and NO config is
#      emitted (no disk identity is committed, so no disk write can follow);
#   2. the reinstall adapter rejects the unsupported OS with status 2 and an
#      "unsupported os" message (req 4.3) before emitting any argv.
#
# A full QEMU boot to the dialog menu is not required here: the rejection is a
# pure function of the baked menu/adapter, so this test exercises the actual
# shipped artifacts directly (see run-e2e.sh residual gaps for why the interactive
# menu is not driven under QEMU).

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

e2e_skip_unless "$REPO_ROOT/stage0/build-initramfs.sh" "initramfs builder"

INITRD="$TMPDIR/initramfs-stage0"
e2e_info "building stage0 initramfs"
e2e_build_initramfs "$INITRD"
_st=$?
if [ "$_st" -ne 0 ]; then
    [ "$_st" -eq 3 ] && exit 3
    e2e_fail "initramfs build failed"
    exit 1
fi

ROOTFS="$TMPDIR/rootfs"
e2e_extract_initramfs "$INITRD" "$ROOTFS" || { e2e_fail "initramfs extract failed"; exit 1; }
e2e_assert_present "initramfs carries the menu" "$ROOTFS/usr/local/sbin/menu"
e2e_assert_present "initramfs carries the reinstall adapter" "$ROOTFS/usr/local/sbin/reinstall-adapter"
e2e_assert_present "initramfs carries the OS catalog" "$ROOTFS/etc/netinstall/os-catalog.json"

# --- (1) the baked menu core rejects an unsupported OS ---------------------
# Source the extracted menu with the TUI short-circuited (MENU_TEST_MODE=1) and
# the catalog pointed at the extracted copy, then drive menu_config_emit exactly
# as the booted menu would for a catalog-missing OS (linux/mint/21).
MENU_OS_CATALOG="$ROOTFS/etc/netinstall/os-catalog.json"; export MENU_OS_CATALOG
MENU_TEST_MODE=1
. "$ROOTFS/usr/local/sbin/menu"

MENU_WIPE_GUARD=
menu_config_emit \
    "/dev/disk/by-id/ata-TEST_1" "TestDisk" "SN1" "1000" \
    linux mint 21 "" "" "" \
    "" "" "" "" \
    dhcp "" "" "" \
    "" "" "" "" "" \
    yes >"$TMPDIR/menu.out" 2>"$TMPDIR/menu.err"
st=$?
if [ "$st" -ne 0 ]; then
    PASS=$((PASS + 1)); printf 'PASS: %s\n' "menu rejects unsupported OS (exit $st)"
else
    FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "menu should reject unsupported OS but exited 0"
fi
MENU_OUT=$(cat "$TMPDIR/menu.out")
if [ -z "$MENU_OUT" ]; then
    PASS=$((PASS + 1)); printf 'PASS: %s\n' "menu emits no config for unsupported OS (no disk write path)"
else
    FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "menu emitted config for unsupported OS: $MENU_OUT"
fi
e2e_assert_contains "menu reports the unsupported OS" "unsupported os" "$(cat "$TMPDIR/menu.err")"

menu_os_supported linux mint 21 2>/dev/null
if [ $? -ne 0 ]; then
    PASS=$((PASS + 1)); printf 'PASS: %s\n' "menu_os_supported reports the OS as unsupported"
else
    FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "menu_os_supported should reject linux/mint/21"
fi

# --- (2) the baked adapter rejects the unsupported OS (status 2) -----------
cat > "$TMPDIR/unsupported.json" <<EOF
{"targetDisk":{"id":"/dev/disk/by-id/ata-TEST_1","model":"TestDisk","serial":"SN1","size":"1000"},"os":{"category":"linux","distro":"mint","version":"21","extra":{}},"network":{"mode":"dhcp"}}
EOF

ADAPTER_OS_CATALOG="$ROOTFS/etc/netinstall/os-catalog.json" \
ADAPTER_PROXY_LIB="$ROOTFS/usr/local/sbin/lib/proxy.sh" \
sh "$ROOTFS/usr/local/sbin/reinstall-adapter" "$TMPDIR/unsupported.json" \
    >"$TMPDIR/adapter.out" 2>"$TMPDIR/adapter.err"
st=$?
if [ "$st" -eq 2 ]; then
    PASS=$((PASS + 1)); printf 'PASS: %s\n' "adapter rejects unsupported OS with status 2 (req 4.3)"
else
    FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "adapter should exit 2 for unsupported OS, got $st"
fi
ADAPTER_OUT=$(cat "$TMPDIR/adapter.out")
if [ -z "$ADAPTER_OUT" ]; then
    PASS=$((PASS + 1)); printf 'PASS: %s\n' "adapter emits no argv for unsupported OS"
else
    FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "adapter emitted argv for unsupported OS: $ADAPTER_OUT"
fi
e2e_assert_contains "adapter reports the unsupported OS" "unsupported os" "$(cat "$TMPDIR/adapter.err")"

e2e_summary
exit $?
