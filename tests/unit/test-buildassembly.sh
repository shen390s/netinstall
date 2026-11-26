#!/bin/sh
# Unit tests for the build assembly (task 3.5 — stage0-netboot-image).
#
# Asserts:
#   1. build_assemble_plan emits the ordered steps — build initramfs ->
#      netboot assembly -> grub-mkrescue hybrid ISO -> raw USB image;
#   2. it references the shared artifact names (vmlinuz-lts,
#      initramfs-stage0, modloop-lts) and the boot configs (menu.ipxe,
#      dnsmasq.conf, grub.cfg), and delegates the initramfs build to
#      stage0/build-initramfs.sh;
#   3. grub-mkrescue is invoked for the hybrid ISO with BIOS (i386-pc) and
#      UEFI (x86_64-efi) loaders;
#   4. build_assemble_plan fails closed (non-zero, no stdout) on a missing
#      input (kernel/modloop/initramfs-builder/boot configs/iPXE chainloaders);
#   5. DRY_RUN=1 emits the plan but performs no build/copy/grub-mkrescue;
#   6. the iPXE chainloaders (undionly.kpxe + ipxe.efi) are copied to the TFTP
#      root, and menu.ipxe lands at the TFTP root (not under boot/).
#
# Runs under any POSIX sh. Invoke with: sh tests/unit/test-buildassembly.sh

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/../.." && pwd)
BUILD_HELPER="$REPO_ROOT/build/build.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n       %s\n' "$1" "$2"; }

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

assert_not_contains() { # name needle haystack
    case "$3" in
        *"$2"*) fail "$1" "expected output NOT to contain [$2]" ;;
        *) pass "$1" ;;
    esac
}

line_of() { # needle haystack -> first 1-based line containing needle (0 if none)
    printf '%s\n' "$2" | awk -v n="$1" 'index($0, n) { print NR; found = 1; exit } END { if (!found) print 0 }'
}

# Source the build helper. (RED phase: when build/build.sh is absent the
# functions stay undefined and the plan tests fail explicitly.)
if [ -r "$BUILD_HELPER" ]; then
    . "$BUILD_HELPER"
fi

type build_assemble_plan >/dev/null 2>&1 \
    && type build_assemble_run >/dev/null 2>&1
assert_return_ok "build defines plan + run helpers" "$?"

# ---------------------------------------------------------------------------
# Fixture: overridable input seams pointed at temp files; outputs under a temp
# OUT_DIR so the plan is testable without a running container.
# ---------------------------------------------------------------------------
tmpdir=$(mktemp -d) || exit 1
export REPO_ROOT
export OUT_DIR="$tmpdir/out"
export KERNEL="$tmpdir/vmlinuz-lts"
export MODLOOP="$tmpdir/modloop-lts"
printf 'kernel-placeholder\n' > "$KERNEL"
printf 'modloop-placeholder\n' > "$MODLOOP"
export IPXE_BIOS="$tmpdir/undionly.kpxe"
export IPXE_EFI="$tmpdir/ipxe.efi"
printf 'ipxe-bios-placeholder\n' > "$IPXE_BIOS"
printf 'ipxe-efi-placeholder\n' > "$IPXE_EFI"
unset DRY_RUN

# ---------------------------------------------------------------------------
# (1) ordered plan + (2) artifact names / boot configs + (3) grub-mkrescue
# ---------------------------------------------------------------------------
plan=$(build_assemble_plan 2>"$tmpdir/plan.err"); st=$?
assert_return_ok "build_assemble_plan returns 0" "$st"

li=$(line_of "build stage0 initramfs" "$plan")
ln=$(line_of "assemble netboot tree" "$plan")
lg=$(line_of "build hybrid ISO" "$plan")
lu=$(line_of "produce raw USB image" "$plan")

[ "$li" -gt 0 ] && pass "plan has a build-initramfs step" || fail "plan has a build-initramfs step" "marker not found"
[ "$ln" -gt 0 ] && pass "plan has a netboot-assembly step" || fail "plan has a netboot-assembly step" "marker not found"
[ "$lg" -gt 0 ] && pass "plan has an ISO step" || fail "plan has an ISO step" "marker not found"
[ "$lu" -gt 0 ] && pass "plan has a USB-image step" || fail "plan has a USB-image step" "marker not found"

if [ "$li" -gt 0 ] && [ "$li" -lt "$ln" ] && [ "$ln" -lt "$lg" ] && [ "$lg" -lt "$lu" ]; then
    pass "plan orders steps: initramfs -> netboot -> ISO -> USB"
else
    fail "plan orders steps: initramfs -> netboot -> ISO -> USB" "initramfs@$li netboot@$ln ISO@$lg USB@$lu"
fi

# (2) artifact names and boot configs
for a in vmlinuz-lts initramfs-stage0 modloop-lts; do
    assert_contains "plan references $a" "$a" "$plan"
done
assert_contains "plan copies undionly.kpxe to the TFTP root" "netboot/undionly.kpxe" "$plan"
assert_contains "plan copies ipxe.efi to the TFTP root" "netboot/ipxe.efi" "$plan"
assert_contains "plan places menu.ipxe at the TFTP root" "netboot/menu.ipxe" "$plan"
assert_not_contains "plan does not place menu.ipxe under boot/" "netboot/boot/menu.ipxe" "$plan"
assert_contains "plan references boot/dnsmasq.conf" "dnsmasq.conf" "$plan"
assert_contains "plan references boot/grub.cfg" "boot/grub.cfg" "$plan"
assert_contains "plan delegates to build-initramfs.sh" "build-initramfs.sh" "$plan"
assert_contains "plan creates the output root" "mkdir -p '$OUT_DIR'" "$plan"

# (3) grub-mkrescue for the hybrid ISO (BIOS + UEFI)
assert_contains "plan invokes grub-mkrescue" "grub-mkrescue" "$plan"
assert_contains "plan targets BIOS i386-pc" "i386-pc" "$plan"
assert_contains "plan targets UEFI x86_64-efi" "x86_64-efi" "$plan"
assert_contains "plan sorts kernel to low LBA" "--sort-weight 100 vmlinuz-lts" "$plan"
assert_contains "plan sorts initramfs to low LBA" "--sort-weight 90 initramfs-stage0" "$plan"

# ---------------------------------------------------------------------------
# (4) fail closed on a missing input
# ---------------------------------------------------------------------------
saved_modloop=$MODLOOP
export MODLOOP="$tmpdir/does-not-exist-modloop"
missing_plan=$(build_assemble_plan 2>"$tmpdir/missing.err"); missing_st=$?
export MODLOOP=$saved_modloop
assert_return_fail "build_assemble_plan fails closed on missing modloop" "$missing_st"
if [ -z "$missing_plan" ]; then
    pass "no plan on stdout when an input is missing"
else
    fail "no plan on stdout when an input is missing" "got: $missing_plan"
fi

saved_kernel=$KERNEL
export KERNEL="$tmpdir/does-not-exist-kernel"
missing_plan2=$(build_assemble_plan 2>"$tmpdir/missing2.err"); missing_st2=$?
export KERNEL=$saved_kernel
assert_return_fail "build_assemble_plan fails closed on missing kernel" "$missing_st2"

saved_ipxe_bios=$IPXE_BIOS
export IPXE_BIOS="$tmpdir/does-not-exist-undionly.kpxe"
missing_plan3=$(build_assemble_plan 2>"$tmpdir/missing3.err"); missing_st3=$?
export IPXE_BIOS=$saved_ipxe_bios
assert_return_fail "build_assemble_plan fails closed on missing iPXE BIOS chainloader" "$missing_st3"

saved_ipxe_efi=$IPXE_EFI
export IPXE_EFI="$tmpdir/does-not-exist-ipxe.efi"
missing_plan4=$(build_assemble_plan 2>"$tmpdir/missing4.err"); missing_st4=$?
export IPXE_EFI=$saved_ipxe_efi
assert_return_fail "build_assemble_plan fails closed on missing iPXE EFI chainloader" "$missing_st4"

# ---------------------------------------------------------------------------
# (5) DRY_RUN=1 emits but performs no build/copy/grub-mkrescue
# ---------------------------------------------------------------------------
rm -rf "$OUT_DIR"
export DRY_RUN=1
build_assemble_run > "$tmpdir/dry.out" 2> "$tmpdir/dry.err"; dry_st=$?
unset DRY_RUN
assert_return_ok "DRY_RUN=1 build returns 0" "$dry_st"
assert_contains "DRY_RUN=1 still emits the grub-mkrescue step" "grub-mkrescue" "$(cat "$tmpdir/dry.out")"

for missing_out in "$OUT_DIR/netboot" "$OUT_DIR/iso" "$OUT_DIR/initramfs-stage0" "$OUT_DIR/netinstall.iso" "$OUT_DIR/netinstall.img"; do
    if [ -e "$missing_out" ]; then
        fail "DRY_RUN=1 creates nothing" "unexpected path: $missing_out"
    else
        pass "DRY_RUN=1 creates nothing ($missing_out)"
    fi
done

rm -rf "$tmpdir"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
