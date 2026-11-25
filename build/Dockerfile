# stage0-netboot-image build container (task 1.1)
#
# Alpine-based build/test environment carrying the full stage0 image toolchain
# plus a VM runner for end-to-end tests. Tool set per design.md "Technology Stack":
#   mkinitfs            initramfs builder
#   grub + grub-bios + grub-efi   bootloader (i386-pc + x86_64-efi) and ISO/USB
#   xorriso             ISO tooling (used by grub-mkrescue)
#   mtools              grub-mkrescue support (EFI boot image)
#   dialog              TUI toolkit (configuration menu)
#   parted, sfdisk      partition utilities
#   dropbear            SSH server (rescue)
#   qemu-system-x86_64  VM runner (end-to-end tests)
#   linux-lts           bundled kernel (lets mkinitfs build a real initramfs and
#                       gives the VM runner a self-contained boot test image)
#   busybox             POSIX shell / scripting
#
# The base image is pinned to an immutable Alpine release tag; apk packages are
# pinned to the exact versions resolved from that release's repositories.

FROM alpine:3.21.10

RUN apk add --no-cache \
    mkinitfs=3.11.1-r0 \
    grub=2.12-r7 \
    grub-bios=2.12-r7 \
    grub-efi=2.12-r7 \
    xorriso=1.5.6-r0 \
    mtools=4.0.46-r0 \
    dialog=1.3.20240619-r0 \
    parted=3.6-r2 \
    sfdisk=2.40.4-r1 \
    dropbear=2024.86-r0 \
    qemu-system-x86_64=9.1.2-r1 \
    linux-lts=6.12.119-r0 \
    busybox=1.37.0-r14

# Pre-build a minimal initramfs from the bundled linux-lts kernel so the image
# is self-contained and the VM-runner boot test has a known-good artifact.
# mkinitfs must be pointed at the installed kernel version, NOT `uname -r`
# (containers share the host kernel, which here differs from the Alpine kernel).
# `-F base` keeps it to busybox + init (a few MB) instead of the default feature
# set, whose `kms` feature drags in ~100MB of GPU firmware.
RUN KVER="$(ls /lib/modules | head -n1)" \
    && echo "building initramfs (base) for kernel: $KVER" \
    && mkinitfs -F base -o /boot/initramfs-lts "$KVER" \
    && ls -l /boot/

# Self-test scripts: assert the toolchain is present/versioned and that the VM
# runner boots a test image.
COPY test-tools.sh /usr/local/bin/test-tools
COPY test-qemu-boot.sh /usr/local/bin/test-qemu-boot
RUN chmod +x /usr/local/bin/test-tools /usr/local/bin/test-qemu-boot

CMD ["sh"]
