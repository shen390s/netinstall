#!/bin/sh
# build — assemble the stage0 payload into three bootable forms
# (stage0-netboot-image, task 3.5).
#
# Produces, from one shared stage0 kernel + initramfs + modloop:
#   netboot/          iPXE + dnsmasq netboot tree (BIOS and UEFI clients)
#   <ISO_OUT>         hybrid BIOS+UEFI ISO (grub-mkrescue)
#   <USB_OUT>         dd-able raw USB image (byte-for-byte copy of the ISO)
#
# It does NOT re-author the initramfs (task 3.3) or the boot configs (task 3.4);
# it only orchestrates them:
#   1. build the stage0 initramfs — delegates to stage0/build-initramfs.sh,
#      which emits initramfs-stage0 (and fails closed on a missing payload
#      source);
#   2. assemble the netboot tree — undionly.kpxe + ipxe.efi chainloaders and
#      menu.ipxe at the TFTP root, plus vmlinuz-lts + initramfs-stage0 +
#      modloop-lts, and boot/dnsmasq.conf as a reference copy, under netboot/;
#   3. build the hybrid ISO via grub-mkrescue (i386-pc BIOS + x86_64-efi UEFI)
#      from a tree holding vmlinuz-lts, initramfs-stage0, modloop-lts, and the
#      grub menu (placed at boot/grub/grub.cfg, the path grub-mkrescue's
#      embedded loader searches on the media);
#   4. produce the raw USB image as a dd-able copy of the hybrid ISO.
#
# Two layers, mirroring the other stage0 components:
#   1. build_assemble_plan — a pure, testable core that emits the ordered,
#      executable plan. It never executes anything and fails closed (non-zero,
#      no stdout) when any input is missing.
#   2. build_assemble_run — validates + builds the plan, then either emits it
#      (DRY_RUN=1, nothing executed) or runs it under `sh -e`.
#
# Overridable seams (env) so the plan is testable without a running container:
#   REPO_ROOT          repo root (derived from $0 when executed directly; a
#                      sourcing test must set it)
#   OUT_DIR            output root (default $REPO_ROOT/dist)
#   NETBOOT_DIR        netboot tree output (default $OUT_DIR/netboot)
#   ISO_TREE           ISO staging tree (default $OUT_DIR/iso)
#   ISO_OUT            hybrid ISO path (default $OUT_DIR/netinstall.iso)
#   USB_OUT            USB image path (default $OUT_DIR/netinstall.img)
#   INITRAMFS_OUT      initramfs output path (default $OUT_DIR/initramfs-stage0)
#   KERNEL             source kernel (default /boot/vmlinuz-lts)
#   MODLOOP            source modloop (default /boot/modloop-lts)
#   INITRAMFS_BUILDER  initramfs builder script
#                      (default $REPO_ROOT/stage0/build-initramfs.sh)
#   BOOT_MENU_IPXE     iPXE script (default $REPO_ROOT/boot/menu.ipxe)
#   BOOT_DNSMASQ       dnsmasq config (default $REPO_ROOT/boot/dnsmasq.conf)
#   BOOT_GRUB_CFG      grub menu (default $REPO_ROOT/boot/grub.cfg)
#   IPXE_BIOS          iPXE BIOS chainloader (default /usr/share/ipxe/undionly.kpxe)
#   IPXE_EFI           iPXE UEFI chainloader (default /usr/share/ipxe/ipxe.efi)
#   GRUB_MKRESCUE      grub-mkrescue binary (default grub-mkrescue)
#   KERNEL_VERSION     optional; forwarded to the initramfs builder
#   DRY_RUN=1          emit the plan, do not build/copy/grub-mkrescue
#
# All POSIX sh (busybox ash compatible); no bashisms.

# Locate the repo root when this script is executed directly. When sourced by a
# test there is no portable way to find this script's own path, so the test sets
# REPO_ROOT before sourcing.
if [ "${0##*/}" = build.sh ]; then
    REPO_ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
fi

# build_assemble_plan
# Emit the executable plan: initramfs build -> netboot tree -> grub-mkrescue
# hybrid ISO -> USB image copy. Fails closed when any input is missing,
# emitting nothing on stdout.
build_assemble_plan() {
    _repo=${REPO_ROOT:-.}
    _out=${OUT_DIR:-"$_repo/dist"}
    _netboot=${NETBOOT_DIR:-"$_out/netboot"}
    _isotree=${ISO_TREE:-"$_out/iso"}
    _iso=${ISO_OUT:-"$_out/netinstall.iso"}
    _usb=${USB_OUT:-"$_out/netinstall.img"}
    _initramfs=${INITRAMFS_OUT:-"$_out/initramfs-stage0"}
    _kernel=${KERNEL:-/boot/vmlinuz-lts}
    _modloop=${MODLOOP:-/boot/modloop-lts}
    _ipxe_bios=${IPXE_BIOS:-/usr/share/ipxe/undionly.kpxe}
    _ipxe_efi=${IPXE_EFI:-/usr/share/ipxe/ipxe.efi}
    _builder=${INITRAMFS_BUILDER:-"$_repo/stage0/build-initramfs.sh"}
    _menu_ipxe=${BOOT_MENU_IPXE:-"$_repo/boot/menu.ipxe"}
    _dnsmasq=${BOOT_DNSMASQ:-"$_repo/boot/dnsmasq.conf"}
    _grub_cfg=${BOOT_GRUB_CFG:-"$_repo/boot/grub.cfg"}
    _grub_mkrescue=${GRUB_MKRESCUE:-grub-mkrescue}
    _dry=${DRY_RUN:-0}

    # Fail closed: require the kernel, modloop, initramfs builder, and boot
    # configs to be present and readable. The builder itself fails closed on a
    # missing payload source.
    _missing=''
    for _f in "$_kernel" "$_modloop" "$_builder" "$_menu_ipxe" "$_dnsmasq" "$_grub_cfg" "$_ipxe_bios" "$_ipxe_efi"; do
        [ -r "$_f" ] || _missing="$_missing  $_f\n"
    done
    if [ -n "$_missing" ]; then
        printf 'build: missing input(s):\n%b' "$_missing" >&2
        return 1
    fi

    # (0) ensure the output root exists before any step writes into it.
    printf "mkdir -p '%s'\n" "$_out"

    # (1) build the stage0 initramfs (delegate to stage0/build-initramfs.sh).
    _builder_env="DRY_RUN=$_dry REPO_ROOT='$_repo' MKINITFS_OUT='$_initramfs'"
    if [ -n "${KERNEL_VERSION:-}" ]; then
        _builder_env="$_builder_env KERNEL_VERSION='$KERNEL_VERSION'"
    fi
    printf '%s\n' '# build stage0 initramfs (delegates to stage0/build-initramfs.sh)'
    printf "%s sh '%s'\n" "$_builder_env" "$_builder"

    # (2) assemble the netboot tree.
    printf '%s\n' '# assemble netboot tree (undionly.kpxe + ipxe.efi + menu.ipxe at TFTP root; vmlinuz-lts + initramfs-stage0 + modloop-lts; boot/dnsmasq.conf reference)'
    printf "mkdir -p '%s/boot'\n" "$_netboot"
    printf "cp '%s' '%s/undionly.kpxe'\n" "$_ipxe_bios" "$_netboot"
    printf "cp '%s' '%s/ipxe.efi'\n" "$_ipxe_efi" "$_netboot"
    printf "cp '%s' '%s/vmlinuz-lts'\n" "$_kernel" "$_netboot"
    printf "cp '%s' '%s/initramfs-stage0'\n" "$_initramfs" "$_netboot"
    printf "cp '%s' '%s/modloop-lts'\n" "$_modloop" "$_netboot"
    printf "cp '%s' '%s/menu.ipxe'\n" "$_menu_ipxe" "$_netboot"
    printf "cp '%s' '%s/boot/dnsmasq.conf'\n" "$_dnsmasq" "$_netboot"

    # (3) build the hybrid ISO via grub-mkrescue (BIOS i386-pc + UEFI
    # x86_64-efi). grub-mkrescue embeds loaders for every installed platform;
    # the build container carries grub-bios (i386-pc) and grub-efi
    # (x86_64-efi), so the output is a hybrid BIOS+UEFI image. The grub menu is
    # placed at boot/grub/grub.cfg — the path grub-mkrescue's embedded loader
    # `configfile`s on the media.
    printf '%s\n' '# build hybrid ISO via grub-mkrescue (BIOS i386-pc + UEFI x86_64-efi)'
    printf "mkdir -p '%s/boot/grub'\n" "$_isotree"
    printf "cp '%s' '%s/vmlinuz-lts'\n" "$_kernel" "$_isotree"
    printf "cp '%s' '%s/initramfs-stage0'\n" "$_initramfs" "$_isotree"
    printf "cp '%s' '%s/modloop-lts'\n" "$_modloop" "$_isotree"
    printf "cp '%s' '%s/boot/grub/grub.cfg'\n" "$_grub_cfg" "$_isotree"
    printf "%s -o '%s' '%s'\n" "$_grub_mkrescue" "$_iso" "$_isotree"

    # (4) produce the raw USB image (a dd-able copy of the hybrid ISO).
    printf '%s\n' '# produce raw USB image (dd-able copy of the hybrid ISO)'
    printf "cp '%s' '%s'\n" "$_iso" "$_usb"
}

# build_assemble_run
# Validate + build the plan, then emit it (DRY_RUN=1) or execute it under
# `sh -e`. A failed plan (missing input) returns non-zero without executing
# anything.
build_assemble_run() {
    _plan=$(build_assemble_plan) || return $?
    printf '%s\n' "$_plan"
    if [ "${DRY_RUN:-0}" = 1 ]; then
        return 0
    fi
    printf '%s\n' "$_plan" | sh -e
}

# Run only when executed as `build.sh` (not when sourced by a test).
case "${0##*/}" in
    build.sh) build_assemble_run "$@" ;;
esac
