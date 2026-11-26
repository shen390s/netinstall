#!/bin/sh
# Unit tests for the Disk Provisioner non-interactive core (task 2.3 —
# stage0-netboot-image).
#
# Drives the pure command-generation + disk-guard core of `disk-prep` without
# touching a real block device, and asserts:
#   1. a valid by-id target + bios mode emits a `setup-disk -m sys` command with
#      the BIOS (i386-pc) bootloader selection;
#   2. uefi mode emits the UEFI (x86_64-efi) bootloader selection;
#   3. a disk id that does not resolve to the by-id target is refused with a
#      non-zero exit and no command;
#   4. an empty/unset disk id is refused;
#   5. the dry-run path never executes destructive commands.
#
# Runs under any POSIX sh. Invoke with: sh tests/unit/test-diskprep.sh

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/../.." && pwd)
SBIN_DIR="$REPO_ROOT/stage0/payload/usr/local/sbin"
LIB_DIR="$SBIN_DIR/lib"

DISK_PREP="$SBIN_DIR/disk-prep"
export DISK_PREP_DISK_LIB="$LIB_DIR/disk.sh"

# Source the disk helper, then the disk-prep core under test.
. "$DISK_PREP_DISK_LIB"
. "$DISK_PREP"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n       %s\n' "$1" "$2"; }

assert_eq() { # name expected actual
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2] got [$3]"; fi
}

assert_return_ok() { # name status
    if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1" "expected status 0 got $2"; fi
}

assert_return_fail() { # name status
    if [ "$2" -ne 0 ]; then pass "$1"; else fail "$1" "expected non-zero status got $2"; fi
}

assert_contains() { # name needle haystack
    case "$3" in
        *"$2"*) pass "$1" ;;
        *) fail "$1" "expected [$3] to contain [$2]" ;;
    esac
}

assert_not_contains() { # name needle haystack
    case "$3" in
        *"$2"*) fail "$1" "expected [$3] to NOT contain [$2]" ;;
        *) pass "$1" ;;
    esac
}

type disk_prep_plan >/dev/null 2>&1
assert_return_ok "disk-prep defines disk_prep_plan" "$?"
type disk_prep_run >/dev/null 2>&1
assert_return_ok "disk-prep defines disk_prep_run" "$?"

# ---------------------------------------------------------------------------
# Fixture: a synthetic /dev/disk/by-id directory.
#   ata-Good_SSD_SERIAL -> ../../sda   (canonical by-id for the pinned disk sda)
#   zzz-Wrong_SSD       -> ../../sda   (a second alias to sda that is NOT the
#                                        canonical by-id for that device, so it
#                                        fails the wrong-disk round-trip guard)
# ---------------------------------------------------------------------------
tmpdir=$(mktemp -d) || exit 1
ln -s ../../sda "$tmpdir/ata-Good_SSD_SERIAL"
ln -s ../../sda "$tmpdir/zzz-Wrong_SSD"

GOOD_ID="$tmpdir/ata-Good_SSD_SERIAL"
WRONG_ID="$tmpdir/zzz-Wrong_SSD"
MISSING_ID="$tmpdir/ata-No_Such_Disk"

bios_expected='BOOTLOADER=grub setup-disk -m sys /dev/sda'
uefi_expected='USE_EFI=1 BOOTLOADER=grub setup-disk -m sys /dev/sda'

# ---------------------------------------------------------------------------
# (1) valid by-id target + bios -> setup-disk -m sys + BIOS bootloader
# ---------------------------------------------------------------------------
plan=$(disk_prep_plan "$GOOD_ID" bios "$tmpdir" 2>"$tmpdir/err"); st=$?
assert_return_ok "bios plan returns 0" "$st"
assert_eq "bios plan emits setup-disk -m sys" "$bios_expected" "$plan"
assert_contains "bios plan runs the standard disk install" "setup-disk -m sys" "$plan"
assert_contains "bios plan selects grub bootloader" "BOOTLOADER=grub" "$plan"
assert_contains "bios plan operates on the resolved device" "/dev/sda" "$plan"
assert_not_contains "bios plan has no UEFI selector" "USE_EFI=1" "$plan"

# ---------------------------------------------------------------------------
# (2) uefi mode -> x86_64-efi bootloader selection
# ---------------------------------------------------------------------------
plan=$(disk_prep_plan "$GOOD_ID" uefi "$tmpdir" 2>"$tmpdir/err"); st=$?
assert_return_ok "uefi plan returns 0" "$st"
assert_eq "uefi plan emits setup-disk -m sys + USE_EFI" "$uefi_expected" "$plan"
assert_contains "uefi plan runs the standard disk install" "setup-disk -m sys" "$plan"
assert_contains "uefi plan selects grub bootloader" "BOOTLOADER=grub" "$plan"
assert_contains "uefi plan selects UEFI via USE_EFI" "USE_EFI=1" "$plan"
assert_contains "uefi plan operates on the resolved device" "/dev/sda" "$plan"

# ---------------------------------------------------------------------------
# (3) disk id that does not resolve to the by-id target -> refused, no command
# ---------------------------------------------------------------------------
plan=$(disk_prep_plan "$WRONG_ID" bios "$tmpdir" 2>"$tmpdir/err"); st=$?
assert_return_fail "non-canonical by-id alias refused" "$st"
assert_eq "non-canonical by-id alias emits no command" "" "$plan"

plan=$(disk_prep_plan "$MISSING_ID" bios "$tmpdir" 2>"$tmpdir/err"); st=$?
assert_return_fail "non-existent by-id path refused" "$st"
assert_eq "non-existent by-id path emits no command" "" "$plan"

# ---------------------------------------------------------------------------
# (4) empty/unset disk id -> refused (unset == empty via ${1:-} in the core)
# ---------------------------------------------------------------------------
plan=$(disk_prep_plan "" bios "$tmpdir" 2>"$tmpdir/err"); st=$?
assert_return_fail "empty disk id refused" "$st"
assert_eq "empty disk id emits no command" "" "$plan"

# Unsupported firmware mode is also refused (design: unsupported firmware -> rescue).
plan=$(disk_prep_plan "$GOOD_ID" bogus "$tmpdir" 2>"$tmpdir/err"); st=$?
assert_return_fail "unsupported firmware mode refused" "$st"
assert_eq "unsupported firmware mode emits no command" "" "$plan"

# ---------------------------------------------------------------------------
# (5) dry-run path never executes destructive commands
# ---------------------------------------------------------------------------
fakebin=$(mktemp -d) || exit 1
fakelog="$tmpdir/exec.log"
: > "$fakelog"

cat > "$fakebin/setup-disk" <<'EOF'
#!/bin/sh
printf '%s\n' "setup-disk $*" >> "$FAKE_LOG"
EOF
chmod +x "$fakebin/setup-disk"

export FAKE_LOG="$fakelog"
export PATH="$fakebin:$PATH"

export DRY_RUN=1
disk_prep_run "$GOOD_ID" bios "$tmpdir" > "$tmpdir/dry.out" 2>"$tmpdir/dry.err"; st=$?
assert_return_ok "dry-run wrapper returns 0" "$st"
assert_eq "dry-run executes no destructive command" "" "$(cat "$fakelog")"
assert_contains "dry-run still emits the plan" "setup-disk -m sys" "$(cat "$tmpdir/dry.out")"
unset DRY_RUN

# The thin wrapper dispatches to the generated commands only when not dry-run
# (using harmless logging stubs, not real setup-disk/grub-install).
disk_prep_run "$GOOD_ID" bios "$tmpdir" > "$tmpdir/exec.out" 2>"$tmpdir/exec.err"; st=$?
assert_return_ok "non-dry-run wrapper returns 0" "$st"
assert_contains "non-dry-run executes setup-disk" \
    "setup-disk -m sys /dev/sda" "$(cat "$fakelog")"

rm -rf "$tmpdir" "$fakebin"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
