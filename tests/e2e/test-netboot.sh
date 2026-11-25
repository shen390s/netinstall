#!/bin/sh
# E2E: netboot boot (stage0-netboot-image, task 4.3 — requirement 1.2).
#
# Builds the REAL stage0 initramfs, boots the REAL stage0 kernel + initramfs in
# QEMU (TCG, no KVM) using the `-kernel`/`-initrd` shortcut (the same artifacts
# the netboot tree publishes), and asserts:
#   1. the guest kernel + initramfs reach userspace init ("Alpine Init"), i.e.
#      the stage0 image loads into memory with no pre-existing OS (req 1.2);
#   2. the built initramfs carries the complete stage0 payload (orchestrator,
#      menu, disk-prep, stage1-install, adapter, rescue, helpers, config, and
#      the local.d boot hook) — the "menu/init" that boots next;
#   3. the netboot boot configs (boot/menu.ipxe, boot/dnsmasq.conf) reference the
#      same kernel/initramfs/modloop artifacts the build publishes.
#
# The full netboot-tree assembly (build/build.sh) and its iPXE chainloaders are
# exercised by test-iso-uefi.sh (which builds the same tree), keeping this test
# cheap; a full boot past init into the dialog menu additionally requires an
# Alpine apk repository + modloop, documented in run-e2e.sh "KNOWN RESIDUAL
# GAPS".

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
e2e_skip_unless /boot/vmlinuz-lts "stage0 kernel (linux-lts)"
e2e_skip_unless "$REPO_ROOT/boot/menu.ipxe" "netboot iPXE menu"
e2e_skip_unless "$REPO_ROOT/boot/dnsmasq.conf" "netboot dnsmasq config"
e2e_skip_unless "$REPO_ROOT/stage0/build-initramfs.sh" "initramfs builder"

KERNEL=/boot/vmlinuz-lts
INITRD="$TMPDIR/initramfs-stage0"

e2e_info "building stage0 initramfs"
if ! e2e_build_initramfs "$INITRD"; then
    e2e_fail "initramfs build failed"
    exit 1
fi
e2e_assert_present "stage0 initramfs built" "$INITRD"

# --- (2) the built initramfs carries the complete stage0 payload -----------
ROOTFS="$TMPDIR/rootfs"
e2e_extract_initramfs "$INITRD" "$ROOTFS" || { e2e_fail "initramfs extract failed"; exit 1; }

for p in \
    usr/local/sbin/stage0-main \
    usr/local/sbin/menu \
    usr/local/sbin/disk-prep \
    usr/local/sbin/stage1-install \
    usr/local/sbin/reinstall-adapter \
    usr/local/sbin/rescue \
    usr/local/sbin/lib/net.sh \
    usr/local/sbin/lib/disk.sh \
    usr/local/sbin/lib/proxy.sh \
    etc/netinstall/config.schema.json \
    etc/netinstall/os-catalog.json \
    reinstall/reinstall.sh \
    reinstall/trans.sh \
    reinstall/initrd-network.sh \
    reinstall/patches/proxy-env.patch \
    stage1/etc/profile.d/99-proxy.sh \
    stage1/etc/local.d/stage1.start \
    etc/local.d/stage0.start; do
    e2e_assert_present "initramfs payload: $p" "$ROOTFS/$p"
done

# The local.d hook must exec the orchestrator (the boot -> menu handoff).
HOOK=$(cat "$ROOTFS/etc/local.d/stage0.start" 2>/dev/null)
e2e_assert_contains "stage0 boot hook execs the orchestrator" "stage0-main" "$HOOK"

# --- (1) boot the real kernel + initramfs to userspace init ----------------
LOG="$TMPDIR/boot.log"
e2e_info "booting stage0 kernel + initramfs in QEMU (TCG)"
e2e_qemu_boot "$LOG" 45 "Alpine Init" "$KERNEL" "$INITRD" "console=ttyS0"
BOOTLOG=$(cat "$LOG" 2>/dev/null)
e2e_assert_contains "stage0 kernel boots (Linux version)" "Linux version" "$BOOTLOG"
e2e_assert_contains "stage0 initramfs reaches userspace init (Alpine Init)" "Alpine Init" "$BOOTLOG"

# --- (3) netboot boot configs reference the shared artifacts ----------------
MENU_IPXE=$(cat "$REPO_ROOT/boot/menu.ipxe" 2>/dev/null)
e2e_assert_contains "menu.ipxe loads vmlinuz-lts" "vmlinuz-lts" "$MENU_IPXE"
e2e_assert_contains "menu.ipxe loads initramfs-stage0" "initramfs-stage0" "$MENU_IPXE"
e2e_assert_contains "menu.ipxe loads modloop-lts" "modloop-lts" "$MENU_IPXE"

DNSMASQ=$(cat "$REPO_ROOT/boot/dnsmasq.conf" 2>/dev/null)
e2e_assert_contains "dnsmasq selects BIOS chainloader" "undionly.kpxe" "$DNSMASQ"
e2e_assert_contains "dnsmasq selects UEFI chainloader" "ipxe.efi" "$DNSMASQ"

e2e_summary
exit $?
