#!/bin/sh
# Integration test: ISO file layout (stage0-netboot-image, follow-up fix).
#
# Verifies that a freshly built hybrid ISO places the two files grub must read
# (the kernel and the initramfs) at LOW LBAs, and the large modloop LAST. The
# kernel must land below a fixed threshold so grub's read is reliable on
# firmwares (e.g. Proxmox SeaBIOS) that garble high-offset reads; this is the
# regression guard for the "invalid magic number" bug fixed by the --sort-weight
# change in build/build.sh.
#
# Runs inside the build container (needs grub-mkrescue, xorriso, kernel, modloop,
# and the initramfs builder). On a host without those it SKIPs (exit 3).
# Invoke with: sh tests/integration/test-isolayout.sh

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/../.." && pwd)

for tool in grub-mkrescue xorriso; do
    command -v "$tool" >/dev/null 2>&1 || { printf 'SKIP: %s unavailable\n' "$tool"; exit 3; }
done
[ -r /boot/vmlinuz-lts ] || { printf 'SKIP: /boot/vmlinuz-lts missing\n'; exit 3; }
[ -r /boot/modloop-lts ] || { printf 'SKIP: /boot/modloop-lts missing\n'; exit 3; }
[ -r "$REPO_ROOT/build/build.sh" ] || { printf 'SKIP: build/build.sh missing\n'; exit 3; }

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n       %s\n' "$1" "$2"; }

# lba_of <iso> <iso_path> -> prints the file's start LBA (numeric)
lba_of() {
    xorriso -indev "$1" -find / -exec report_lba 2>/dev/null \
        | grep -F "'$2'" \
        | head -1 \
        | awk -F',' '{ gsub(/[^0-9]/, "", $2); print $2 }'
}

tmpdir=$(mktemp -d) || exit 1
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

iso="$tmpdir/dist/netinstall.iso"

printf 'building hybrid ISO (build.sh)...\n'
OUT_DIR="$tmpdir/dist" sh "$REPO_ROOT/build/build.sh" >"$tmpdir/build.log" 2>&1
st=$?
if [ "$st" -ne 0 ] || [ ! -f "$iso" ]; then
    fail "build.sh produced the ISO" "exit $st; $(tail -3 "$tmpdir/build.log" | tr '\n' ' ')"
    printf '%s\n' "RESULT: $PASS passed, $FAIL failed"
    exit 1
fi
pass "build.sh produced the ISO"

kernel_lba=$(lba_of "$iso" /vmlinuz-lts)
initramfs_lba=$(lba_of "$iso" /initramfs-stage0)
modloop_lba=$(lba_of "$iso" /modloop-lts)

# Numeric, non-empty guards.
case "$kernel_lba" in
    ''|*[!0-9]*) fail "kernel LBA is numeric" "got [$kernel_lba]" ;;
    *) pass "kernel LBA is numeric ($kernel_lba)" ;;
esac

# (1) the kernel is at a low absolute LBA (reliable grub read).
if [ -n "$kernel_lba" ] && [ "$kernel_lba" -lt 4096 ] 2>/dev/null; then
    pass "kernel is at a low LBA ($kernel_lba < 4096)"
else
    fail "kernel is at a low LBA" "vmlinuz-lts LBA $kernel_lba (expected < 4096)"
fi

# (2) relative order: kernel < initramfs < modloop.
if [ -n "$kernel_lba" ] && [ -n "$initramfs_lba" ] && [ -n "$modloop_lba" ] \
   && [ "$kernel_lba" -lt "$initramfs_lba" ] 2>/dev/null \
   && [ "$initramfs_lba" -lt "$modloop_lba" ] 2>/dev/null; then
    pass "ISO order is kernel($kernel_lba) < initramfs($initramfs_lba) < modloop($modloop_lba)"
else
    fail "ISO order is kernel < initramfs < modloop" "got $kernel_lba / $initramfs_lba / $modloop_lba"
fi

printf '%s\n' "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
