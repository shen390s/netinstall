#!/bin/sh
# Unit tests for the boot configurations (task 3.4 — stage0-netboot-image).
#
# Asserts:
#   1. boot/menu.ipxe is an iPXE script that does `dhcp`, `kernel` (HTTP URL),
#      `initrd`, and `boot`, and references the shared stage0 artifacts
#      (vmlinuz-lts, initramfs-stage0, modloop-lts) plus the Alpine kernel
#      cmdline tokens (alpine_repo=, modloop=);
#   2. boot/dnsmasq.conf selects the iPXE chainloader by firmware via DHCP
#      option 93 (client-arch): arch 0 (x86 BIOS) -> undionly.kpxe,
#      arch 7 (x86-64 UEFI) -> ipxe.efi;
#   3. boot/grub.cfg has a menuentry that does `linux /vmlinuz-lts <cmdline>`
#      + `initrd /initramfs-stage0`;
#   4. all three configs reference the SAME kernel/initramfs/modloop artifact
#      names so they chain-load an identical stage0.
#
# Runs under any POSIX sh. Invoke with: sh tests/unit/test-bootcfg.sh

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/../.." && pwd)
BOOT_DIR="$REPO_ROOT/boot"

MENU_IPXE="$BOOT_DIR/menu.ipxe"
DNSMASQ_CONF="$BOOT_DIR/dnsmasq.conf"
GRUB_CFG="$BOOT_DIR/grub.cfg"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n       %s\n' "$1" "$2"; }

assert_contains() { # name needle haystack
    case "$3" in
        *"$2"*) pass "$1" ;;
        *) fail "$1" "expected to contain [$2]" ;;
    esac
}

# Read a config file into a variable; empty string when missing (so the RED
# phase fails explicitly instead of erroring out).
read_file() { # path -> echoes contents (or empty if unreadable)
    if [ -r "$1" ]; then
        cat "$1"
    else
        printf ''
    fi
}

menu=$(read_file "$MENU_IPXE")
dnsmasq=$(read_file "$DNSMASQ_CONF")
grub=$(read_file "$GRUB_CFG")

# ---------------------------------------------------------------------------
# (1) menu.ipxe — iPXE script
# ---------------------------------------------------------------------------

if [ -r "$MENU_IPXE" ]; then pass "menu.ipxe is present and readable"; else fail "menu.ipxe is present and readable" "missing $MENU_IPXE"; fi

assert_contains "menu.ipxe runs dhcp" "dhcp" "$menu"
assert_contains "menu.ipxe loads a kernel" "kernel" "$menu"
assert_contains "menu.ipxe loads an initrd" "initrd" "$menu"
assert_contains "menu.ipxe boots" "boot" "$menu"
assert_contains "menu.ipxe references vmlinuz-lts" "vmlinuz-lts" "$menu"
assert_contains "menu.ipxe references initramfs-stage0" "initramfs-stage0" "$menu"
assert_contains "menu.ipxe references modloop-lts" "modloop-lts" "$menu"
assert_contains "menu.ipxe sets a valid alpine_repo" "alpine_repo=https://dl-cdn.alpinelinux.org/alpine/v3.21/main" "$menu"
assert_contains "menu.ipxe sets modloop=none" "modloop=none" "$menu"
assert_contains "menu.ipxe sets console=tty0" "console=tty0" "$menu"
assert_contains "menu.ipxe sets console=ttyS0" "console=ttyS0" "$menu"
assert_contains "menu.ipxe loads disk drivers via modules=" "modules=ahci,nvme,sd_mod" "$menu"
assert_contains "menu.ipxe uses an HTTP server URL" "http://" "$menu"

# ---------------------------------------------------------------------------
# (2) dnsmasq.conf — firmware-based chainloader selection
# ---------------------------------------------------------------------------

if [ -r "$DNSMASQ_CONF" ]; then pass "dnsmasq.conf is present and readable"; else fail "dnsmasq.conf is present and readable" "missing $DNSMASQ_CONF"; fi

assert_contains "dnsmasq matches BIOS arch 0" "option:client-arch,0" "$dnsmasq"
assert_contains "dnsmasq matches x86-64 UEFI arch 7" "option:client-arch,7" "$dnsmasq"
assert_contains "dnsmasq maps BIOS to undionly.kpxe" "undionly.kpxe" "$dnsmasq"
assert_contains "dnsmasq maps UEFI to ipxe.efi" "ipxe.efi" "$dnsmasq"
assert_contains "dnsmasq enables TFTP" "enable-tftp" "$dnsmasq"

# ---------------------------------------------------------------------------
# (3) grub.cfg — ISO/USB menu
# ---------------------------------------------------------------------------

if [ -r "$GRUB_CFG" ]; then pass "grub.cfg is present and readable"; else fail "grub.cfg is present and readable" "missing $GRUB_CFG"; fi

assert_contains "grub.cfg defines a menuentry" "menuentry" "$grub"
assert_contains "grub.cfg loads linux /vmlinuz-lts" "linux /vmlinuz-lts" "$grub"
assert_contains "grub.cfg loads initrd /initramfs-stage0" "initrd /initramfs-stage0" "$grub"
assert_contains "grub.cfg references modloop-lts" "modloop-lts" "$grub"
assert_contains "grub.cfg sets a valid alpine_repo" "alpine_repo=https://dl-cdn.alpinelinux.org/alpine/v3.21/main" "$grub"
assert_contains "grub.cfg sets modloop=none" "modloop=none" "$grub"
assert_contains "grub.cfg sets console=tty0" "console=tty0" "$grub"
assert_contains "grub.cfg sets console=ttyS0" "console=ttyS0" "$grub"
assert_contains "grub.cfg loads disk drivers via modules=" "modules=ahci,nvme,sd_mod" "$grub"

# ---------------------------------------------------------------------------
# (4) identical artifact names across all three configs
# ---------------------------------------------------------------------------

for artifact in vmlinuz-lts initramfs-stage0 modloop-lts; do
    for spec in "menu.ipxe:$menu" "dnsmasq.conf:$dnsmasq" "grub.cfg:$grub"; do
        _name=${spec%%:*}
        _body=${spec#*:}
        assert_contains "$_name references $artifact" "$artifact" "$_body"
    done
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
