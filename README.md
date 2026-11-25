# netinstall

`netinstall` is a network-boot OS deployment tool. It builds a menu-driven **stage0** mini-Linux image that boots a machine from the network, a USB drive, or an ISO, prepares a target disk, and hands off to [bin456789/reinstall](https://github.com/bin456789/reinstall) to install the final Linux or Windows OS.

The image does not perform the OS install itself. Instead it:

1. boots into a RAM-only stage0 live system,
2. shows a text menu to select the target disk, OS, credentials, and network/proxy settings,
3. partitions the confirmed disk and installs a bootloader,
4. installs a minimal stage1 system on the disk with `reinstall` and the chosen configuration baked in,
5. reboots into stage1, which runs `reinstall` unattended to install the final OS.

## Boot media

One stage0 kernel + initramfs + modloop is packaged three ways:

- **Network boot** (PXE BIOS and UEFI) — an iPXE + dnsmasq tree.
- **Hybrid ISO** — a BIOS + UEFI bootable `.iso` (`grub-mkrescue`).
- **USB image** — a `dd`-able raw copy of the hybrid ISO.

Target machines need Secure Boot disabled (or a signed boot path); see `docs/user-guide.md`.

## Prerequisites

Everything is built inside the container defined by `build/Dockerfile`: an Alpine 3.21 image carrying the full toolchain (mkinitfs, grub + grub-bios + grub-efi, xorriso, mtools, dialog, parted, sfdisk, dropbear, alpine-conf `setup-disk`, busybox + busybox-extras), QEMU for tests, the pinned Linux kernel/modules, and the iPXE chainloaders (`undionly.kpxe`, `ipxe.efi`). You need Docker to build and run it.

## Build

```sh
# 1. Build the build/test container (context is build/, which holds the Dockerfile).
docker build -t netinstall-stage0 build/

# 2. Assemble the three artifacts inside the container.
docker run --rm -v "$PWD":/repo --entrypoint sh netinstall-stage0 \
    -c 'cd /repo && sh build/build.sh'
```

`build/build.sh` builds the stage0 initramfs, then assembles the outputs under `dist/`:

- `dist/netboot/` — netboot tree (`undionly.kpxe`, `ipxe.efi`, `menu.ipxe`, `vmlinuz-lts`, `initramfs-stage0`, `modloop-lts`, and a reference `boot/dnsmasq.conf`).
- `dist/netinstall.iso` — hybrid BIOS + UEFI ISO.
- `dist/netinstall.img` — `dd`-able USB image.

The build is self-contained (no network needed at build time beyond what the Docker image already baked in).

## Test

```sh
# Unit tests (no container needed; POSIX sh + python3).
sh tests/run-unit.sh

# Integration tests (need root + loop devices/mounts; run in the privileged container).
sh tests/integration/run-in-container.sh

# End-to-end tests (QEMU; run in the privileged container).
sh tests/e2e/run-in-container.sh
```

The two `run-in-container.sh` wrappers mount the repo at `/repo` and run the real suite inside `netinstall-stage0:latest` under `docker run --privileged`.

## Documentation

- **Operator walkthrough** (booting, the menu, the stage sequence, proxy, rescue, troubleshooting): `docs/user-guide.md`
- **Feature specification** (requirements, design, tasks): `.kiro/specs/stage0-netboot-image/`

## Known status

The full end-to-end chain (`menu -> disk-prep -> stage1 -> reinstall -> final OS`) is **not yet exercised**: a full boot to the interactive menu requires a reachable Alpine apk repository at boot so `initramfs-init` can `apk add alpine-base` into the live root before `switch_root`. The E2E suite asserts the reachable parts instead — the image boots to userspace init, the initramfs carries the complete payload, and the disk is untouched before the full-wipe confirmation — and skips the full chain with a documented reason. Installing a real final OS via `reinstall` is also too slow for CI and is not exercised. See `docs/user-guide.md` and the spec for the current status.
