#!/bin/sh
# E2E: ISO boot under UEFI (stage0-netboot-image, task 4.3 — requirement 1.3).
#
# Builds the REAL hybrid ISO (and the netboot tree) via build/build.sh, then
# boots it in QEMU under OVMF (UEFI firmware) and asserts the guest reaches the
# GRUB boot menu. This proves the hybrid ISO boots on UEFI firmware (req 1.3).
# The BIOS path is also exercised by booting the same ISO under SeaBIOS.
#
# Requires a modloop module bundle (build.sh's fail-closed input). It is
# generated from the installed kernel modules via mksquashfs (squashfs-tools is
# installed on demand when apk has network access). If either is unavailable the
# test SKIPs (exit 3) with the documented reason rather than faking a pass.
#
# NOTE: the ISO's grub.cfg does not pass `console=ttyS0` to the kernel, so this
# test asserts the UEFI boot reached GRUB (and that the stage0 menu entry is
# selected on BIOS) rather than kernel serial output — see run-e2e.sh residual
# gaps. The kernel/initramfs boot-to-init itself is asserted by test-netboot.sh.

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
e2e_require grub-mkrescue "hybrid ISO builder (grub)"
e2e_skip_unless /boot/vmlinuz-lts "stage0 kernel (linux-lts)"
e2e_skip_unless "$REPO_ROOT/build/build.sh" "build assembly"
e2e_skip_unless "$REPO_ROOT/stage0/build-initramfs.sh" "initramfs builder"

OVMF=$(e2e_find_ovmf) || {
    e2e_skip "no UEFI firmware (OVMF) found under /usr/share/qemu or /usr/share/OVMF"
    exit 3
}
e2e_info "UEFI firmware: $OVMF"

# --- generate modloop + build the real artifacts ---------------------------
MODLOOP="$TMPDIR/modloop-lts"
if ! e2e_ensure_modloop "$MODLOOP"; then
    exit 3
fi
e2e_assert_present "modloop module bundle generated" "$MODLOOP"

OUTDIR="$TMPDIR/dist"
mkdir -p "$OUTDIR"
e2e_info "building netboot tree + hybrid ISO (this can take a couple of minutes)"
if ! e2e_build_artifacts "$OUTDIR" "$MODLOOP"; then
    e2e_fail "build/build.sh failed"
    exit 1
fi
e2e_assert_present "hybrid ISO built" "$OUTDIR/netinstall.iso"
e2e_assert_present "netboot tree: initramfs-stage0" "$OUTDIR/netboot/initramfs-stage0"
e2e_assert_present "netboot tree: vmlinuz-lts" "$OUTDIR/netboot/vmlinuz-lts"
e2e_assert_present "netboot tree: menu.ipxe" "$OUTDIR/netboot/menu.ipxe"
e2e_assert_present "netboot tree: undionly.kpxe (BIOS iPXE)" "$OUTDIR/netboot/undionly.kpxe"
e2e_assert_present "netboot tree: ipxe.efi (UEFI iPXE)" "$OUTDIR/netboot/ipxe.efi"

# --- UEFI ISO boot reaches GRUB --------------------------------------------
LOG_UEFI="$TMPDIR/uefi.log"
e2e_info "booting hybrid ISO under OVMF (UEFI)"
e2e_qemu_boot_uefi "$LOG_UEFI" 75 "GNU GRUB" "$OVMF" "$OUTDIR/netinstall.iso"
UEFI_LOG=$(cat "$LOG_UEFI" 2>/dev/null)
e2e_assert_contains "UEFI firmware boots the ISO to GRUB" "GNU GRUB" "$UEFI_LOG"

# --- BIOS ISO boot selects the stage0 menu entry ---------------------------
LOG_BIOS="$TMPDIR/bios.log"
e2e_info "booting hybrid ISO under SeaBIOS (BIOS)"
e2e_qemu_boot_iso "$LOG_BIOS" 60 "netinstall stage0 installer" "$OUTDIR/netinstall.iso"
BIOS_LOG=$(cat "$LOG_BIOS" 2>/dev/null)
e2e_assert_contains "BIOS firmware boots the ISO to the stage0 menu entry" \
    "netinstall stage0 installer" "$BIOS_LOG"

e2e_summary
exit $?
