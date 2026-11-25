#!/bin/sh
# tests/e2e/lib.sh — shared helpers for the stage0-netboot-image E2E tests
# (task 4.3).
#
# Each tests/e2e/test-*.sh sets REPO_ROOT and E2E_DIR, then sources this file.
# All helpers are POSIX sh (busybox ash compatible); no bashisms. Helpers build
# and boot the REAL stage0 artifacts (never mocks), and fail/skip honestly.

# --- output + control ------------------------------------------------------

e2e_info() { printf '[e2e] %s\n' "$*"; }
e2e_skip() { printf 'SKIP: %s\n' "$*"; }
e2e_fail() { printf 'FAIL: %s\n' "$*"; }

# e2e_require <bin> <why>
# Abort with SKIP (exit 3) when a required binary is missing.
e2e_require() {
    _bin=$1; _why=$2
    if ! command -v "$_bin" >/dev/null 2>&1; then
        e2e_skip "missing required tool [$_bin]: $_why"
        exit 3
    fi
}

# e2e_skip_unless <path> <why>
# Abort with SKIP (exit 3) when a required file is missing/unreadable.
e2e_skip_unless() {
    _path=$1; _why=$2
    if [ ! -r "$_path" ]; then
        e2e_skip "missing required file [$_path]: $_why"
        exit 3
    fi
}

# --- environment -----------------------------------------------------------

# e2e_kernel_version — the container kernel version mkinitfs must target.
e2e_kernel_version() {
    ls /lib/modules 2>/dev/null | head -n 1
}

# e2e_find_ovmf — print a UEFI firmware (OVMF) code path, or nothing.
e2e_find_ovmf() {
    for _f in /usr/share/qemu/edk2-x86_64-code.fd \
              /usr/share/OVMF/OVMF_CODE.fd \
              /usr/share/OVMF/OVMF_CODE.secboot.fd \
              /usr/share/edk2-ovmf/OVMF_CODE.fd \
              /usr/share/edk2/x64/OVMF_CODE.fd; do
        [ -r "$_f" ] && { printf '%s\n' "$_f"; return 0; }
    done
    return 1
}

# --- building the real artifacts -------------------------------------------

# e2e_build_initramfs <out>
# Build the REAL stage0 initramfs (delegates to stage0/build-initramfs.sh).
# Returns 0 on success.
e2e_build_initramfs() {
    _out=$1
    _kver=$(e2e_kernel_version) || return 1
    KERNEL_VERSION="$_kver" MKINITFS_OUT="$_out" \
        sh "$REPO_ROOT/stage0/build-initramfs.sh" >/dev/null 2>&1
}

# e2e_ensure_modloop <out>
# Produce a real modloop squashfs of the installed kernel modules (the input
# build/build.sh requires). Requires mksquashfs; installs squashfs-tools if it
# is absent and apk can reach the repositories. Returns 0 on success, 3 when the
# prerequisite cannot be satisfied (caller should SKIP).
e2e_ensure_modloop() {
    _out=$1
    _kver=$(e2e_kernel_version) || return 3
    if ! command -v mksquashfs >/dev/null 2>&1; then
        apk add squashfs-tools >/dev/null 2>&1
    fi
    if ! command -v mksquashfs >/dev/null 2>&1; then
        e2e_skip "mksquashfs unavailable (cannot generate modloop); apk add squashfs-tools failed"
        return 3
    fi
    if [ ! -d "/lib/modules/$_kver" ]; then
        e2e_skip "no kernel module tree at /lib/modules/$_kver (cannot generate modloop)"
        return 3
    fi
    _stage=$(mktemp -d) || return 3
    mkdir -p "$_stage/modules/$_kver" || { rm -rf "$_stage"; return 3; }
    cp -a "/lib/modules/$_kver/." "$_stage/modules/$_kver/" || { rm -rf "$_stage"; return 3; }
    mksquashfs "$_stage" "$_out" -noappend -comp xz -no-progress >/dev/null 2>&1
    _rc=$?
    rm -rf "$_stage"
    return "$_rc"
}

# e2e_build_artifacts <out_dir>
# Build the REAL netboot tree + hybrid ISO via build/build.sh. The output
# directory must exist first (build.sh does not create its own root). Returns 0
# on success.
e2e_build_artifacts() {
    _outdir=$1
    _modloop=$2
    _kver=$(e2e_kernel_version) || return 1
    OUT_DIR="$_outdir" MODLOOP="$_modloop" KERNEL_VERSION="$_kver" \
        sh "$REPO_ROOT/build/build.sh" >/dev/null 2>&1
}

# e2e_extract_initramfs <initrd> <dir>
# Extract an initramfs (gzip-compressed or plain cpio) into <dir>.
e2e_extract_initramfs() {
    _initrd=$1; _dir=$2
    mkdir -p "$_dir" || return 1
    ( cd "$_dir" && (zcat "$_initrd" 2>/dev/null || cat "$_initrd") | cpio -idmu 2>/dev/null )
}

# --- booting under QEMU (TCG) ----------------------------------------------

# e2e_qemu_run <log> <timeout_secs> <break_pattern> <args...>
# Boot qemu-system-x86_64 (TCG, nographic, no reboot) with <args...>, capturing
# the serial console to <log>. Polls up to <timeout_secs> and stops early when
# <break_pattern> (may be empty) appears in the log — the stage0 initramfs idles
# in an emergency shell after boot, so callers pass their success marker here to
# avoid waiting out the full timeout. Always leaves no qemu process behind.
# Returns 0 (callers assert on the captured log, not the exit code).
e2e_qemu_run() {
    _log=$1; _timeout=$2; _break=$3
    shift 3

    qemu-system-x86_64 \
        -accel tcg -nographic -no-reboot -m 1024 "$@" >"$_log" 2>&1 &
    QEMU_PID=$!

    _i=0
    while kill -0 "$QEMU_PID" 2>/dev/null; do
        if [ -n "$_break" ] && [ -s "$_log" ] && grep -qF "$_break" "$_log" 2>/dev/null; then
            kill "$QEMU_PID" 2>/dev/null
            break
        fi
        _i=$((_i + 1))
        if [ "$_i" -ge "$_timeout" ]; then
            kill "$QEMU_PID" 2>/dev/null
            break
        fi
        sleep 1
    done
    wait "$QEMU_PID" 2>/dev/null
    QEMU_PID=
    return 0
}

# e2e_qemu_boot <log> <timeout_secs> <break> <kernel> <initrd> <append> [extra...]
# Boot kernel+initramfs directly (the netboot shortcut).
e2e_qemu_boot() {
    _log=$1; _timeout=$2; _break=$3; _kernel=$4; _initrd=$5; _append=$6
    shift 6
    e2e_qemu_run "$_log" "$_timeout" "$_break" \
        -kernel "$_kernel" -initrd "$_initrd" -append "$_append" "$@"
}

# e2e_qemu_boot_iso <log> <timeout_secs> <break> <iso> [extra...]
# Boot a hybrid ISO as a CD-ROM (default SeaBIOS).
e2e_qemu_boot_iso() {
    _log=$1; _timeout=$2; _break=$3; _iso=$4
    shift 4
    e2e_qemu_run "$_log" "$_timeout" "$_break" -cdrom "$_iso" -boot d "$@"
}

# e2e_qemu_boot_uefi <log> <timeout_secs> <break> <ovmf> <iso>
# Boot a hybrid ISO under UEFI firmware (OVMF pflash).
e2e_qemu_boot_uefi() {
    _log=$1; _timeout=$2; _break=$3; _ovmf=$4; _iso=$5
    e2e_qemu_run "$_log" "$_timeout" "$_break" \
        -drive if=pflash,format=raw,readonly=on,file="$_ovmf" \
        -cdrom "$_iso" -boot d
}

# --- assertion helpers -----------------------------------------------------

# e2e_assert_contains <name> <needle> <haystack>
e2e_assert_contains() {
    _name=$1; _needle=$2; _haystack=$3
    case "$_haystack" in
        *"$_needle"*) PASS=$((PASS + 1)); printf 'PASS: %s\n' "$_name" ;;
        *) FAIL=$((FAIL + 1)); printf 'FAIL: %s\n       expected output to contain [%s]\n' "$_name" "$_needle" ;;
    esac
}

# e2e_assert_not_contains <name> <needle> <haystack>
e2e_assert_not_contains() {
    _name=$1; _needle=$2; _haystack=$3
    case "$_haystack" in
        *"$_needle"*) FAIL=$((FAIL + 1)); printf 'FAIL: %s\n       expected output to NOT contain [%s]\n' "$_name" "$_needle" ;;
        *) PASS=$((PASS + 1)); printf 'PASS: %s\n' "$_name" ;;
    esac
}

# e2e_assert_present <name> <path>
e2e_assert_present() {
    _name=$1; _path=$2
    if [ -e "$_path" ]; then PASS=$((PASS + 1)); printf 'PASS: %s\n' "$_name"; \
    else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n       missing [%s]\n' "$_name" "$_path"; fi
}

# e2e_summary — print a PASS/FAIL tally and exit 0/1 accordingly.
e2e_summary() {
    printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ]
}
