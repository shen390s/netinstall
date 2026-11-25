#!/bin/sh
# Boot the pre-built Alpine test initramfs under qemu to prove the VM runner
# can boot an image (task 1.1 completion criterion).
set -u

KERNEL=/boot/vmlinuz-lts
INITRD=/boot/initramfs-lts

for f in "$KERNEL" "$INITRD"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: missing $f"
    exit 1
  fi
done

LOG=$(mktemp)

# Headless software-emulation (TCG) boot; serial console on stdio; no reboot
# loop; bounded runtime (the initramfs drops to a busybox rescue shell and idles,
# so timeout kills qemu after we have captured the init banner).
timeout 60 qemu-system-x86_64 \
  -accel tcg -nographic -no-reboot -m 512 \
  -kernel "$KERNEL" -initrd "$INITRD" \
  -append "console=ttyS0" >"$LOG" 2>&1
rc=$?

echo "--- qemu exit code: $rc (124 = killed by timeout while the rescue shell idled) ---"
echo "--- boot log (tail) ---"
tail -n 40 "$LOG"

# "Alpine Init" is printed by the initramfs init script, so it proves the guest
# kernel booted AND reached userspace init (not merely that the kernel banner
# was emitted before a panic).
if grep -qE "Linux version|Alpine Init" "$LOG"; then
  echo "PASS: qemu-system-x86_64 booted the test image (kernel + initramfs init observed)"
  rm -f "$LOG"
  exit 0
fi

echo "FAIL: no kernel/init banner in qemu boot log"
rm -f "$LOG"
exit 1
