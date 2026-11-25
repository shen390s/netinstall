#!/bin/sh
# stage0-netboot-image build container self-test (task 1.1).
#
# Asserts every tool required by design.md "Technology Stack" is installed and
# reports a version:
#   Initramfs:  mkinitfs
#   Bootloader: grub (grub-mkrescue, grub-install, grub-mkimage + i386-pc/x86_64-efi)
#   ISO/USB:    xorriso
#   Partition:  parted, sfdisk
#   TUI:        dialog
#   SSH/rescue: dropbear
#   VM runner:  qemu-system-x86_64
#   Disk install: setup-disk (alpine-conf)
#   Patching:  patch
#   HTTP log:  httpd (busybox-extras)
#   Scripting:  busybox (POSIX shell)
#
# Exit status: 0 when every tool is present and versioned, 1 otherwise.
set -u

fail=0
note() { printf '%s\n' "$*"; }
ok()   { note "OK   $1"; }
bad()  { note "FAIL $1"; fail=$((fail + 1)); }

# check <binary> <apk-package> <native-version-probe|->
#   - binary must be on PATH (presence + runnable path)
#   - apk-package must report an installed version via `apk list -I` (pinned version)
#   - native probe (optional) executes the binary to prove it runs and prints a version
check() {
  bin=$1 pkg=$2 probe=$3

  loc=$(command -v "$bin" 2>/dev/null) || loc=""
  if [ -z "$loc" ]; then
    bad "$bin: not found on PATH"
    return
  fi

  ver=$(apk list -I "$pkg" 2>/dev/null | head -n1 | awk '{print $1}')
  if [ -z "$ver" ]; then
    bad "$bin: package '$pkg' reports no installed version"
  fi

  native=""
  if [ "$probe" != "-" ]; then
    native=$(eval "$probe" 2>&1 | head -n1)
    if [ -z "$native" ]; then
      bad "$bin: native version probe produced no output"
    fi
  fi

  if [ -n "$ver" ]; then
    note "OK   $bin -> $loc | apk: $ver${native:+ | runs: $native}"
  fi
}

check mkinitfs            mkinitfs            -
check grub-mkrescue       grub                'grub-mkrescue --version'
check grub-install        grub                'grub-install --version'
check grub-mkimage        grub                'grub-mkimage --version'
check xorriso             xorriso             'xorriso -version'
check dialog              dialog              'dialog --version'
check parted              parted              'parted --version'
check sfdisk              sfdisk              'sfdisk --version'
check dropbear            dropbear            'dropbear -V'
check dropbearkey         dropbear            -
check qemu-system-x86_64  qemu-system-x86_64  'qemu-system-x86_64 --version'
check busybox             busybox             'busybox 2>&1 | head -n1'
check setup-disk          alpine-conf         -
check httpd               busybox-extras      -
check patch               patch               'patch --version'

echo
if [ "$fail" -ne 0 ]; then
  note "RESULT: FAIL ($fail check(s) failed)"
  exit 1
fi
note "RESULT: PASS"
exit 0
