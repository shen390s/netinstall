#!/bin/sh
# Unit tests for the Stage0 Orchestrator (task 3.2 — stage0-netboot-image).
#
# Drives the testable stage0_main core with every component path overridden by
# stubs, and asserts:
#   1. firmware detection returns bios vs uefi correctly (override + /sys seam);
#   2. with a confirmed config, the ordered sequence
#      net-up -> menu -> disk-prep -> stage1-install -> reboot runs (marker-based);
#   3. with an aborting menu, disk-prep/stage1-install/reboot are NOT called and
#      rescue IS called (requirement 1.4);
#   4. reboot is the final step (requirement 7.3);
#   5. DRY_RUN=1 emits the sequence without executing any component.
#
# Runs under any POSIX sh. Invoke with: sh tests/unit/test-stage0main.sh

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/../.." && pwd)
STAGE0_MAIN="$REPO_ROOT/stage0/payload/usr/local/sbin/stage0-main"

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

# Source the component under test. (RED phase: when stage0-main is absent, the
# functions stay undefined and the behavioural tests fail explicitly.)
if [ -r "$STAGE0_MAIN" ]; then
    . "$STAGE0_MAIN"
fi

type stage0_main >/dev/null 2>&1 && type stage0_detect_firmware >/dev/null 2>&1 \
    && type stage0_net_up >/dev/null 2>&1 && type stage0_config_disk_id >/dev/null 2>&1
assert_return_ok "stage0-main defines stage0_main + core helpers" "$?"

# ---------------------------------------------------------------------------
# Fixtures: a scratch dir, stub components, and a shared marker file.
# ---------------------------------------------------------------------------

tmpdir=$(mktemp -d) || exit 1
stubs="$tmpdir/stubs"
mkdir -p "$stubs"

MARKER="$tmpdir/marker"
DISK_ID="/dev/disk/by-id/ata-TEST_1"
export MARKER DISK_ID

# net.sh stub: net_commands emits a single marker-writing command, proving the
# orchestrator delegates network bring-up to net.sh rather than doing it inline.
cat > "$stubs/net.sh" <<'EOF'
net_commands() {
    printf 'echo net-up >> %s\n' "$MARKER"
}
EOF

# menu stub (confirmed): writes a valid DeploymentConfig to its out_path arg.
cat > "$stubs/menu" <<'EOF'
#!/bin/sh
printf 'menu\n' >> "$MARKER"
cat > "$1" <<JSON
{"targetDisk":{"id":"$DISK_ID","model":"TestDisk","serial":"SN1","size":"1000"},"os":{"category":"linux","distro":"debian","version":"12","extra":{}},"network":{"mode":"dhcp"}}
JSON
exit 0
EOF

# menu stub (abort): records the attempt, then exits non-zero (wipe unconfirmed).
cat > "$stubs/menu-abort" <<'EOF'
#!/bin/sh
printf 'menu\n' >> "$MARKER"
exit 1
EOF

cat > "$stubs/disk-prep" <<'EOF'
#!/bin/sh
printf 'disk-prep:%s:%s\n' "$1" "$2" >> "$MARKER"
exit 0
EOF

cat > "$stubs/stage1-install" <<'EOF'
#!/bin/sh
printf 'stage1-install:%s:%s\n' "$1" "$2" >> "$MARKER"
exit 0
EOF

cat > "$stubs/rescue" <<'EOF'
#!/bin/sh
printf 'rescue\n' >> "$MARKER"
exit 0
EOF

cat > "$stubs/reboot" <<'EOF'
#!/bin/sh
printf 'reboot\n' >> "$MARKER"
exit 0
EOF

chmod +x "$stubs/menu" "$stubs/menu-abort" "$stubs/disk-prep" \
    "$stubs/stage1-install" "$stubs/rescue" "$stubs/reboot"

# Overridable seams (env) — set before the flow tests use them.
export STAGE0_NET_LIB="$stubs/net.sh"
export STAGE0_MENU="$stubs/menu"
export STAGE0_CONFIG="$tmpdir/config.json"
export STAGE0_DISK_PREP="$stubs/disk-prep"
export STAGE0_STAGE1_INSTALL="$stubs/stage1-install"
export STAGE0_RESCUE="$stubs/rescue"
export STAGE0_REBOOT="$stubs/reboot"
export STAGE0_SYSROOT="$tmpdir/sysroot"
export STAGE0_NET_IFACE="eth0"
export STAGE0_NET_MODE="dhcp"

# ---------------------------------------------------------------------------
# (1) Firmware detection
# ---------------------------------------------------------------------------
STAGE0_FIRMWARE=bios
assert_eq "firmware override bios -> bios" "bios" "$(stage0_detect_firmware)"
STAGE0_FIRMWARE=uefi
assert_eq "firmware override uefi -> uefi" "uefi" "$(stage0_detect_firmware)"

STAGE0_FIRMWARE=
STAGE0_EFI_SYS="$tmpdir/efi"; mkdir -p "$STAGE0_EFI_SYS"
assert_eq "efi dir present -> uefi" "uefi" "$(stage0_detect_firmware)"
STAGE0_EFI_SYS="$tmpdir/no-efi"
assert_eq "efi dir absent -> bios" "bios" "$(stage0_detect_firmware)"

STAGE0_FIRMWARE=weird
stage0_detect_firmware >/dev/null 2>&1
assert_return_fail "invalid firmware override is refused" "$?"
STAGE0_FIRMWARE=bios
STAGE0_EFI_SYS=/sys/firmware/efi

# ---------------------------------------------------------------------------
# (2) Confirmed config -> ordered sequence, and (4) reboot last.
# ---------------------------------------------------------------------------
: > "$MARKER"
stage0_main > "$tmpdir/seq.out" 2> "$tmpdir/seq.err"; st=$?
assert_return_ok "confirmed flow returns 0" "$st"

seq_flat=$(tr '\n' ' ' < "$MARKER")
assert_contains "sequence includes net-up" "net-up" "$seq_flat"
assert_contains "sequence includes menu" "menu" "$seq_flat"
assert_contains "disk-prep receives confirmed disk + firmware" \
    "disk-prep:$DISK_ID:bios" "$seq_flat"
assert_contains "stage1-install receives sysroot + config" \
    "stage1-install:$tmpdir/sysroot:$tmpdir/config.json" "$seq_flat"
assert_contains "sequence includes reboot" "reboot" "$seq_flat"

# Strict left-to-right order (net-up -> menu -> disk-prep -> stage1-install -> reboot).
case "$seq_flat" in
    *"net-up"*"menu"*"disk-prep:$DISK_ID:bios"*"stage1-install"*"reboot"*)
        pass "ordered sequence net-up -> menu -> disk-prep -> stage1-install -> reboot" ;;
    *) fail "ordered sequence" "out of order: $seq_flat" ;;
esac

assert_eq "reboot is the final step" "reboot" "$(tail -n 1 "$MARKER")"

# ---------------------------------------------------------------------------
# (3) Aborting menu -> rescue, no disk write (requirement 1.4).
# ---------------------------------------------------------------------------
STAGE0_MENU="$stubs/menu-abort"
: > "$MARKER"
stage0_main > "$tmpdir/abort.out" 2> "$tmpdir/abort.err"; st=$?
assert_return_fail "aborting flow returns non-zero" "$st"

abort_flat=$(tr '\n' ' ' < "$MARKER")
assert_contains "abort still runs net-up" "net-up" "$abort_flat"
assert_contains "abort still runs menu" "menu" "$abort_flat"
assert_contains "abort calls rescue" "rescue" "$abort_flat"
assert_not_contains "abort does NOT call disk-prep" "disk-prep" "$abort_flat"
assert_not_contains "abort does NOT call stage1-install" "stage1-install" "$abort_flat"
assert_not_contains "abort does NOT reboot" "reboot" "$abort_flat"
assert_eq "abort ends in rescue" "rescue" "$(tail -n 1 "$MARKER")"
STAGE0_MENU="$stubs/menu"

# ---------------------------------------------------------------------------
# (5) DRY_RUN=1 emits the sequence without executing any component.
# ---------------------------------------------------------------------------
cat > "$STAGE0_CONFIG" <<JSON
{"targetDisk":{"id":"$DISK_ID","model":"TestDisk","serial":"SN1","size":"1000"},"os":{"category":"linux","distro":"debian","version":"12","extra":{}},"network":{"mode":"dhcp"}}
JSON
: > "$MARKER"
export DRY_RUN=1
stage0_main > "$tmpdir/dry.out" 2> "$tmpdir/dry.err"; st=$?
unset DRY_RUN
assert_return_ok "dry-run flow returns 0" "$st"

assert_eq "dry-run executes no component" "" "$(cat "$MARKER")"

dry_flat=$(tr '\n' ' ' < "$tmpdir/dry.out")
assert_contains "dry-run emits menu step" "menu" "$dry_flat"
assert_contains "dry-run emits disk-prep step" "disk-prep" "$dry_flat"
assert_contains "dry-run emits stage1-install step" "stage1-install" "$dry_flat"
assert_contains "dry-run emits reboot step" "reboot" "$dry_flat"
case "$dry_flat" in
    *"menu"*"disk-prep"*"stage1-install"*"reboot"*)
        pass "dry-run emits ordered menu -> disk-prep -> stage1-install -> reboot" ;;
    *) fail "dry-run ordered emission" "out of order: $dry_flat" ;;
esac
assert_eq "dry-run ends with forced reboot" \
    "$(printf '[dry-run] reboot: %s -f' "$STAGE0_REBOOT")" "$(tail -n 1 "$tmpdir/dry.out")"

rm -rf "$tmpdir"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
