#!/bin/sh
# build-initramfs — build the stage0 initramfs from the mkinitfs feature
# (stage0-netboot-image, task 3.3).
#
# Installs the complete stage0 payload (scripts, config, reinstall bundle,
# stage1 sources, and the local.d boot hook) into a target root at the container
# paths that stage0/features.d/stage0.files references, normalizes +x on every
# command-invoked script (menu/disk-prep/rescue are committed 0644 but are
# exec'd as commands), and runs `mkinitfs -F "base network stage0"` to produce the
# initramfs.
#
# Two layers, mirroring the other stage0 components:
#   1. build_initramfs_plan — a pure, testable core that emits the install map,
#      the chmod list, and the mkinitfs command. It never executes anything and
#      fails closed (non-zero, no output) when any payload source is missing.
#   2. build_initramfs_run — validates + builds the plan, then either emits it
#      (DRY_RUN=1, nothing executed) or runs each line under `sh -e`.
#
# Overridable seams (env):
#   REPO_ROOT             repo root (derived from $0 when executed directly;
#                         a sourcing test must set it)
#   TARGET_ROOT           install root (default /)
#   MKINITFS_FEATURES_DIR features.d dir holding stage0.files
#                         (default $REPO_ROOT/stage0/features.d)
#   MKINITFS_OUT          initramfs output path (default /boot/initramfs-stage0)
#   KERNEL_VERSION        kernel version (default: first /lib/modules entry;
#                         set this in a container, where uname -r is the HOST)
#   DRY_RUN=1             emit the plan, do not install or run mkinitfs
#
# All POSIX sh (busybox ash compatible); no bashisms.

# Locate the repo root when this script is executed directly. When sourced by a
# test there is no portable way to find this script's own path, so the test
# sets REPO_ROOT before sourcing.
if [ "${0##*/}" = build-initramfs.sh ]; then
    REPO_ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
fi

# build_initramfs_install_map
# Emit the repo-source -> container-destination install map, one "src dst" pair
# per line. This is the single authoritative list of stage0 payload files the
# helper installs; stage0/features.d/stage0.files mirrors the destination paths
# (plus the apk-provided tool binaries).
build_initramfs_install_map() {
    _p="$REPO_ROOT/stage0/payload"
    _b="$REPO_ROOT/reinstall"
    _s="$REPO_ROOT/stage1"
    cat <<EOF
$_p/usr/local/sbin/stage0-main /usr/local/sbin/stage0-main
$_p/usr/local/sbin/menu /usr/local/sbin/menu
$_p/usr/local/sbin/disk-prep /usr/local/sbin/disk-prep
$_p/usr/local/sbin/stage1-install /usr/local/sbin/stage1-install
$_p/usr/local/sbin/reinstall-adapter /usr/local/sbin/reinstall-adapter
$_p/usr/local/sbin/rescue /usr/local/sbin/rescue
$_p/usr/local/sbin/lib/net.sh /usr/local/sbin/lib/net.sh
$_p/usr/local/sbin/lib/disk.sh /usr/local/sbin/lib/disk.sh
$_p/usr/local/sbin/lib/proxy.sh /usr/local/sbin/lib/proxy.sh
$_p/etc/netinstall/config.schema.json /etc/netinstall/config.schema.json
$_p/etc/netinstall/os-catalog.json /etc/netinstall/os-catalog.json
$_b/reinstall.sh /reinstall/reinstall.sh
$_b/trans.sh /reinstall/trans.sh
$_b/initrd-network.sh /reinstall/initrd-network.sh
$_b/patches/proxy-env.patch /reinstall/patches/proxy-env.patch
$_s/etc/profile.d/99-proxy.sh /stage1/etc/profile.d/99-proxy.sh
$_s/etc/local.d/stage1.start /stage1/etc/local.d/stage1.start
EOF
}

# build_initramfs_plan
# Emit the executable plan (mkdir -> cp map -> boot hook -> chmod -> mkinitfs).
# Fails closed when any payload source is missing, emitting nothing on stdout.
build_initramfs_plan() {
    _target=${TARGET_ROOT:-/}
    _target=${_target%/}          # "/" -> "" so "$_target$dst" has no double /
    _basedir=${_target:-/}        # mkinitfs -b wants a real root path
    _features=${MKINITFS_FEATURES_DIR:-"$REPO_ROOT/stage0/features.d"}
    _out=${MKINITFS_OUT:-/boot/initramfs-stage0}
    _kver=${KERNEL_VERSION:-$(ls "$_basedir/lib/modules" 2>/dev/null | head -n1)}

    # Fail closed: resolve the install map and require every source to exist.
    _map=$(build_initramfs_install_map) || return $?
    _missing=''
    while read -r _src _dst; do
        [ -n "$_src" ] || continue
        [ -r "$_src" ] || _missing="$_missing  $_src\n"
    done <<EOF
$_map
EOF
    if [ -n "$_missing" ]; then
        printf 'build-initramfs: missing payload source(s):\n%b' "$_missing" >&2
        return 1
    fi

    # Destination directories.
    printf 'mkdir -p %s/usr/local/sbin %s/usr/local/sbin/lib %s/etc/netinstall %s/etc/local.d %s/reinstall/patches %s/stage1/etc/profile.d %s/stage1/etc/local.d\n' \
        "$_target" "$_target" "$_target" "$_target" "$_target" "$_target" "$_target"

    # Install map.
    while read -r _src _dst; do
        [ -n "$_src" ] || continue
        printf 'cp %s %s%s\n' "$_src" "$_target" "$_dst"
    done <<EOF
$_map
EOF

    # Boot hook: OpenRC local.d entry that hands control to the orchestrator.
    printf '%s\n' "printf '%s\\n' '#!/bin/sh' 'exec /usr/local/sbin/stage0-main' > $_target/etc/local.d/stage0.start"

    # Normalize +x on every command-invoked script (menu/disk-prep/rescue are
    # committed 0644; the others are +x but normalized for idempotency).
    for _exe in stage0-main menu disk-prep stage1-install reinstall-adapter rescue; do
        printf 'chmod +x %s/usr/local/sbin/%s\n' "$_target" "$_exe"
    done
    printf 'chmod +x %s/etc/local.d/stage0.start\n' "$_target"
    printf 'chmod +x %s/stage1/etc/local.d/stage1.start\n' "$_target"

    # Build the initramfs: base (busybox + init) plus the stage0 feature.
    printf "mkinitfs -b %s -F 'base network stage0' -P %s -o %s %s\n" "$_basedir" "$_features" "$_out" "$_kver"
}

# build_initramfs_run
# Validate + build the plan, then emit it (DRY_RUN=1) or execute it under
# `sh -e`. A failed plan (missing payload source) returns non-zero without
# executing anything.
build_initramfs_run() {
    _plan=$(build_initramfs_plan) || return $?
    printf '%s\n' "$_plan"
    if [ "${DRY_RUN:-0}" = 1 ]; then
        return 0
    fi
    printf '%s\n' "$_plan" | sh -e
}

# Run only when executed as `build-initramfs.sh` (not when sourced by a test).
case "${0##*/}" in
    build-initramfs.sh) build_initramfs_run "$@" ;;
esac
