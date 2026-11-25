# netinstall — User Guide

This guide walks an operator through deploying Linux or Windows with `netinstall`: booting the stage0 installer, filling in the menu, and watching the unattended handoff to the final OS. It also covers proxy configuration and how to recover a failed deployment.

## Overview of the flow

A deployment runs through four stages, end to end:

```
boot (network / ISO / USB)
  -> stage0 (RAM)   : menu, then disk-prep, then stage1-install
  -> reboot
  -> stage1 (disk)  : firstboot runs reinstall.sh automatically
  -> reboot
  -> final OS
```

- **stage0** is a RAM-only Alpine live image. It shows the menu and, only after the full-wipe confirmation, partitions the target disk, installs a bootloader, and installs a minimal stage1 system.
- **stage1** is the minimal Alpine system now on disk. On its first boot it reads the configuration and runs `reinstall` with no further input.
- **`reinstall`** downloads and installs the selected final OS, then reboots into it.

Nothing is written to any disk until the menu's full-wipe confirmation is accepted.

## Booting the installer

All three media boot the same stage0 image (kernel `vmlinuz-lts`, initramfs `initramfs-stage0`, module bundle `modloop-lts`). Secure Boot must be off (see Troubleshooting).

### Network boot (PXE)

Serve the `dist/netboot/` tree from a DHCP + TFTP server (dnsmasq) and an HTTP server that publishes the same tree at the TFTP root.

1. Copy `dist/netboot/` to a directory (e.g. `/srv/netinstall`).
2. Point a dnsmasq instance at it. `boot/dnsmasq.conf` in the tree is a reference config:
   - `tftp-root=/srv/netinstall`
   - a DHCP range for PXE clients,
   - firmware-based chainloader selection (`dhcp-boot` for BIOS `undionly.kpxe` vs UEFI `ipxe.efi`),
   - the iPXE handoff (`dhcp-boot=tag:ipxe,menu.ipxe`).
3. Serve the same root over HTTP so iPXE can fetch `vmlinuz-lts`, `initramfs-stage0`, and `modloop-lts` from `http://<server>/` (see `menu.ipxe`, which derives the URL from the DHCP next-server).
4. Boot the target machine from its network interface (BIOS or UEFI PXE).

### Hybrid ISO

Boot `dist/netinstall.iso` from a CD/DVD drive, virtual media (IPMI), or any hypervisor CD-ROM. It is a hybrid BIOS + UEFI image; the GRUB menu entry `netinstall stage0 installer` boots either firmware.

### USB image

Write the image to a USB drive and boot from it:

```sh
dd if=dist/netinstall.img of=/dev/sdX bs=4M conv=fsync status=progress
```

Replace `/dev/sdX` with the USB device (its whole contents are overwritten). The image is a byte-for-byte copy of the hybrid ISO, so it boots on both BIOS and UEFI.

## The stage0 menu

Once the stage0 image finishes loading, it presents a `dialog` text menu over the console/serial. All choices are collected before anything is written, and nothing is written until the final confirmation.

### 1. Target disk

You pick the target disk from a list of detected disks, each shown as `model | serial | size`. The menu records the disk's stable `/dev/disk/by-id/...` identifier plus its model, serial, and size. A final confirmation re-displays that identity (ID, model, serial, size) and requires you to accept that **all data on the disk will be erased**. If you decline, nothing is written.

### 2. Operating system

You pick an OS from the catalog (`os-catalog.json`). The current catalog includes:

- **Linux**: Debian 12/13, Ubuntu 24.04 / 24.04-minimal / 22.04, Alpine 3.21/3.22, Rocky 9, CentOS 10, Fedora 45, Arch, openSUSE Tumbleweed.
- **Windows**: Windows (any version) — you are then prompted for the image name (default `Windows 11 Pro`) and language (default `en-us`).
- **dd**: a raw disk image — you are prompted for the image URL.

Selecting something `reinstall` cannot install is rejected at the menu, before any write.

### 3. Credentials

Optional login credentials for the **final installed OS** (they map to `reinstall` flags `--username`, `--password`, `--ssh-key`, `--ssh-port`):

- Username (leave empty to skip)
- Password (leave empty to skip)
- SSH public key (leave empty to skip)
- SSH port (default 22)

The SSH key here is for the final OS. The stage0 **rescue** SSH shell uses a separate key (see Rescue and observability).

### 4. Network

- **DHCP** (default), or
- **Static** — prompts for IPv4 address (CIDR), gateway, and an optional DNS server.

This choice is recorded in the deployment configuration. Note: stage1 and `reinstall` do not currently re-apply the operator-configured static IP (DHCP is the effective path during the install) — this is a known implementation gap. Stage0 itself brings up its boot interface before the menu appears (DHCP on `eth0` by default).

### 5. Proxy

Optional egress proxy for restricted networks (all fields are skippable):

- **HTTP proxy**
- **HTTPS proxy**
- **All-protocol proxy** (e.g. `socks5://host:1080`)
- **No-proxy hosts** (comma-separated hosts that bypass the proxy)
- **GitHub proxy mirror** (prefix used to rewrite `raw.githubusercontent.com` fetches)

See Proxy support below for how these propagate.

### 6. Full-wipe confirmation

A yes/no dialog re-displays the disk identity and warns that the operation is irreversible. Confirming is the only path to disk writes.

## What you see during the deployment

1. **Boot / menu** — the stage0 menu; no disk activity.
2. **Disk prep** — on confirmation, stage0 runs the Alpine `setup-disk -m sys` (with `BOOTLOADER=grub`, plus a firmware-pinned `grub-install` target: `i386-pc` for BIOS, `x86_64-efi` for UEFI) to partition the disk and install a bootloader, then installs the minimal base system.
3. **Stage1 install** — stage0 chroot-injects the `reinstall` bundle, the configuration (`/etc/netinstall/config.json`), the proxy profile, and the firstboot hook into the disk-installed system, and enables the OpenRC `local` service.
4. **Reboot** — stage0 reboots into the disk.
5. **Stage1 firstboot** — the `local.d` firstboot script reads `config.json`, maps it to a `reinstall.sh` command line, applies the proxy environment, and launches `reinstall` unattended.
6. **Final OS** — `reinstall` downloads and installs the selected OS, then reboots into it.

Progress is written to the serial console. An HTTP progress log and a dropbear SSH rescue are baked into the stage0 image as capabilities (see below) but are not automatically started.

## Proxy support and propagation

A configured proxy is applied to every download stage:

- The menu writes the proxy into `/etc/netinstall/config.json`.
- The stage1 proxy profile (`/etc/profile.d/99-proxy.sh`) exports `http_proxy`, `https_proxy`, `all_proxy`, `no_proxy`, and `github_proxy` into stage1 shells.
- The firstboot script also evaluates the same proxy environment before launching `reinstall`.
- The pinned `reinstall.sh` is patched (see `reinstall/patches/proxy-env.patch`) so those same five variables are forwarded into `reinstall`'s internal install environment, where the actual OS download runs.

The five variables are:

- `http_proxy`, `https_proxy` — HTTP(S) egress.
- `all_proxy` — used by tools that speak a generic proxy (use `socks5://` or `socks5h://` for SOCKS).
- `no_proxy` — comma-separated hosts that bypass the proxy.
- `github_proxy` — a mirror prefix that `reinstall` uses to rewrite GitHub raw URLs.

## Rescue and observability

- **Serial console** — stage0 writes `stage0:`-prefixed progress lines and stage1 writes `[stage1] ...` lines to the serial console.
- **HTTP progress log** — a `busybox httpd` server can serve the log directory (`/var/log/netinstall`) on port 8080. The binary and generator helpers are baked into the image but not started automatically; start it from the rescue shell if needed.
- **Dropbear SSH rescue** — a key-based (no password) dropbear SSH server, plus host-key and `authorized_keys` generators, is baked into the image but not started automatically; start it from the rescue shell if needed.

If a step fails, the orchestrator drops to an interactive rescue shell (`exec sh`) and never proceeds to a later destructive step, leaving the machine bootable/reachable so you can diagnose and retry.

## Troubleshooting

- **Secure Boot must be off.** The Alpine kernel and the GRUB/iPXE boot chain are unsigned. Disable Secure Boot (or provide a signed boot path) or the machine will refuse to boot stage0/stage1.
- **Network reachability for downloads.** A full boot to the interactive menu requires a reachable Alpine apk repository at boot (so `initramfs-init` can install `alpine-base` before `switch_root`). Stage1's `reinstall` also needs to reach the Alpine repositories / distro mirrors / GitHub to download the final OS. Confirm the machine has working DNS and egress, or a correctly configured proxy.
- **Confirm the disk identity.** Always double-check the model/serial/size shown in the confirmation dialog — the wipe is irreversible and targets the disk pinned by `/dev/disk/by-id`.
- **Static IP must include CIDR and gateway.** If you choose Static, provide the IPv4 address in CIDR form (e.g. `192.168.1.10/24`) and a gateway, or stage0 network bring-up fails and drops to rescue.
- **Proxy unreachable.** A configured but unreachable proxy is reported with a clear error; fix the proxy address/port (or the `no_proxy` list) and retry.
- **Unsupported OS.** A selection not in `os-catalog.json` is rejected before any write; choose a supported OS/version.
