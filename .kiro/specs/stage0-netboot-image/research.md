# Research & Design Decisions Template

## Summary
- **Feature**: stage0-netboot-image
- **Discovery Scope**: Complex Integration (greenfield boot image that integrates the external `reinstall` tool and Alpine boot tooling)
- **Key Findings**:
  - `reinstall.sh` requires an existing root-on-disk and an existing on-disk bootloader, so it cannot run from a RAM-only netboot image on a blank disk. This confirms stage0 must first install a minimal stage1 system to disk.
  - reinstall's install environment is an Alpine live image with `trans.sh` injected via an initramfs `init` hook; proxy environment variables are **not** forwarded there (only network config and `configs/` are). A small patch to `reinstall.sh` is required.
  - Alpine's netboot artifacts (`vmlinuz-lts`, `initramfs-lts`, `modloop-lts`) plus the `apkovl`/OpenRC `local.d` mechanism is the native, supported way to build both stage0 and stage1.

## Research Log

### reinstall integration mechanics
- **Context**: Determine exactly what `reinstall.sh` needs as a source system and how its install environment receives configuration.
- **Sources Consulted**: `reinstall.sh` (6124 lines) and `trans.sh` (9197 lines) fetched and inspected directly from `raw.githubusercontent.com/bin456789/reinstall/main/`.
- **Findings**:
  - `find_main_disk` reads the running `/` mount's partition-table identifier via `lsblk` + `fdisk`, so a RAM-only live system with a blank disk cannot be the source.
  - Next boot is set up by writing a marked entry into an *existing* bootloader (grub/limine/syslinux/EFI/BCD); the script does not install a bootloader from scratch and sets `LOAD_KEXEC=false`.
  - The install env is built by unpacking the Alpine initramfs, embedding `trans.sh` + `initrd-network.sh` + `configs/`, injecting an `init` hook that configures IP (`get_ip_conf_cmd`, `MAC_ADDRESS=1`) and enables `/etc/local.d`, then repacking. `trans.sh` runs at boot and performs the actual OS install.
  - Proxy support: `github_proxy` env var rewrites `confhome` (GitHub raw) through a proxy; `curl` honors `http_proxy`/`https_proxy`/`all_proxy`/`no_proxy` natively; per-distro mirrors are auto-selected by `is_in_china`. No generic proxy env is propagated into the `trans.sh` install environment.
  - Flags: `--username --password --ssh-key --ssh-port --web-port --frpc-config`, plus `--hold 1/2`, `--image-name --lang --iso` (Windows), `--img` (dd).
- **Implications**: Stage0 must manufacture the "existing OS + bootloader" precondition; the only reinstall-internal change is injecting proxy env into its init hook.

### Alpine netboot, mkinitfs, setup-disk, OpenRC
- **Context**: Confirm the base image and stage1 install mechanics.
- **Sources Consulted**: `mkinitfs` man page + `initramfs-init.in` + `mkinitfs-bootparam.7.in` (gitlab.alpinelinux.org), `setup-disk.in` (alpine-conf), `modloop.initd`, `local.in`/`firstboot.initd` (OpenRC/Alpine aports).
- **Findings**:
  - Netboot files at `https://dl-cdn.alpinelinux.org/alpine/v{VERSION}/releases/{ARCH}/netboot/`: `vmlinuz-lts`, `initramfs-lts`, `modloop-lts` (plus `-virt` variants).
  - Kernel cmdline: `alpine_repo=`, `apkovl=URL`, `modloop=`, `ip=dhcp`, `ssh_key=`; `modloop` is mounted by an OpenRC service (sysinit), signature-verified via apk keys.
  - `apkovl` is a tar.gz overlay extracted into the live root at boot (`{MAC}`/`{UUID}` substitution supported) — the native way to inject stage0 scripts.
  - Custom initramfs: `mkinitfs -F "base <feature>"` with a `features.d/<name>.files` list; `-i` replaces `/init`. OpenRC `local.d/*.start` (enabled via `rc-update add local default`) is the standard boot-time hook.
  - `setup-disk -m sys` installs to disk (root/boot/swap; vfat `/boot` on EFI). There is **no `-m efi` mode**; UEFI is chosen by `USE_EFI` or auto-detection of `/sys/firmware/efi`, which switches the bootloader to grub and the label to gpt. Install lands under `SYSROOT` (default `/mnt`) for chroot injection.
- **Implications**: Stage0 = stock kernel+modloop plus a custom payload (apkovl and/or mkinitfs feature); stage1 = `setup-disk -m sys` + chroot injection.

### ISO / USB / PXE boot chain
- **Context**: How to produce the three boot artifacts from one kernel+initramfs+modloop.
- **Sources Consulted**: GNU GRUB manual (`grub-mkrescue`), xorriso man page, iPXE download/chainloading docs, dnsmasq man page.
- **Findings**:
  - `grub-mkrescue -o out.iso <dir>` yields a hybrid BIOS+UEFI ISO that is also dd-able to USB; raw `xorriso -as mkisofs -isohybrid-mbr` with `-e efi.img` + `-append_partition 2 0xef` achieves the same.
  - PXE: BIOS chainloads `undionly.kpxe`, UEFI chainloads `ipxe.efi`, selected by DHCP option 93 (`client-arch`); iPXE script uses `kernel http://…/vmlinuz-lts <cmdline>` + `initrd` + `boot`. dnsmasq provides DHCP+TFTP (`dhcp-match=set:<tag>,option:client-arch,<n>`, `dhcp-boot=tag:<tag>,<file>`).
- **Implications**: One shared stage0 kernel+initramfs+modloop is packaged three ways; no per-media divergence in stage0 logic.

## Architecture Pattern Evaluation

| Option | Description | Strengths | Risks / Limitations | Notes |
|--------|-------------|-----------|---------------------|-------|
| Adopt Alpine netboot + apkovl/local.d + setup-disk | Stage0/stage1 built from stock Alpine tooling | Battle-tested, tiny, same env reinstall uses, native BIOS+UEFI boot | Requires Alpine build host; apkovl needs repo/URL at boot unless packages are baked | Selected |
| Hand-rolled partition/grub + custom init | Build stage0/stage1 from scratch | Full control | Reimplements well-solved problems (partitioning, bootloader, live boot) | Rejected — high risk, no benefit |
| Buildroot-based image | Buildroot produces a custom mini-Linux | Lean, reproducible | Larger build system; diverges from reinstall's Alpine env; more maintenance | Rejected |

## Design Decisions

### Decision: Base stage0 and stage1 on Alpine Linux
- **Context**: Requirements need a tiny, network-bootable, BIOS+UEFI, menu-driven base that reinstall can run on.
- **Alternatives Considered**: 1) Alpine (netboot + setup-disk), 2) Debian netboot/live, 3) Buildroot.
- **Selected Approach**: Alpine `-lts` netboot artifacts as stage0, and Alpine `setup-disk -m sys` as stage1.
- **Rationale**: Alpine is what reinstall itself boots into, so the integration surface is already aligned; `apkovl`/`local.d`/`setup-disk` give native boot, overlay, and disk-install without custom code.
- **Trade-offs**: Requires an Alpine build container and pinning a version; small musl/busybox differences to be aware of in scripts.
- **Follow-up**: Pin an Alpine version (e.g., 3.21 or latest-stable) and mirror the artifacts.

### Decision: Stage1 via `setup-disk -m sys` + chroot injection
- **Context**: Stage0 must place a bootable minimal system with reinstall pre-configured onto the disk.
- **Alternatives Considered**: 1) `setup-disk` + chroot, 2) manual partition + grub-install + rootfs extract, 3) dd a prebuilt stage1 image.
- **Selected Approach**: Run `setup-disk -m sys` from the stage0 live env, then chroot into the installed system to inject the reinstall bundle, `DeploymentConfig`, and the `local.d` firstboot script.
- **Rationale**: `setup-disk` handles BIOS/UEFI bootloader selection, partition layout, and bootability correctly; injection is a thin, reviewable step.
- **Trade-offs**: Stage1 is a full Alpine sys install (throwaway — reinstall wipes it later); acceptable.
- **Follow-up**: Force grub for both BIOS and UEFI so reinstall always finds a grub bootloader to chain into.

### Decision: Proxy reaches `trans.sh` via a patch to pinned `reinstall.sh`
- **Context**: Proxy config must apply to all three download stages, including reinstall's install environment.
- **Alternatives Considered**: 1) Patch reinstall.sh init hook to export proxy env, 2) bake proxy into `trans.sh`, 3) transparent proxy/redsocks.
- **Selected Approach**: Apply a small patch to the pinned `reinstall.sh` that emits `export http_proxy https_proxy all_proxy no_proxy github_proxy` alongside the existing `get_ip_conf_cmd`/`MAC_ADDRESS=1` injection.
- **Rationale**: Minimal, upstreamable, matches the existing injection pattern; stage0/stage1 use env vars natively (curl honors them).
- **Trade-offs**: Patch is version-coupled to the pinned reinstall release; SOCKS needs `socks5h://` via `all_proxy` (wget/apk paths may not honor it).
- **Follow-up**: Verify the patch applies cleanly to the pinned version; add a CI check.

### Decision: Single `DeploymentConfig` JSON as the cross-stage contract
- **Context**: Menu choices (disk, OS, credentials, network, proxy) must flow from stage0 into stage1 without re-asking.
- **Alternatives Considered**: 1) JSON file on the stage1 root, 2) kernel cmdline, 3) env vars only.
- **Selected Approach**: Stage0 writes `/etc/netinstall/config.json` (validated against a schema) into the stage1 chroot; stage1 firstboot reads it and maps to reinstall argv/env.
- **Rationale**: One authoritative, schema-validated artifact; avoids cmdline length/leakage issues and keeps secrets out of `/proc/cmdline`.
- **Trade-offs**: Secrets live on the target disk until reinstall wipes it.
- **Follow-up**: Set restrictive permissions; wipe config explicitly if stage1 aborts.

### Decision: Three boot artifacts from one stage0 image
- **Context**: Requirement 1 needs netboot, USB, and ISO boot.
- **Alternatives Considered**: 1) One kernel+initramfs+modloop packaged three ways, 2) separate builds per medium.
- **Selected Approach**: A single stage0 kernel+initramfs+modloop is packaged as (a) an iPXE/dnsmasq netboot tree, (b) a hybrid ISO via `grub-mkrescue`, and (c) a dd-able USB image.
- **Rationale**: Identical stage0 behavior across media; only the bootloader handoff differs.
- **Trade-offs**: ISO/USB must carry `modloop` and the apkovl locally (no network dependency at menu time).
- **Follow-up**: Confirm grub-mkrescue hybrid BIOS+UEFI boot on QEMU.

## Risks & Mitigations
- **Wrong-disk wipe** — Mitigate with disk identity display (model/serial/size) + explicit full-wipe confirmation + `/dev/disk/by-id` pinning.
- **Secure Boot** — Alpine kernel is unsigned; require Secure Boot off or a signed boot path (out of scope for this spec).
- **Proxy not honored in one stage** — Mitigate with the reinstall patch + `no_proxy` for directly-reachable mirrors; test with a local proxy.
- **reinstall version drift** — Pin the bundle (reinstall.sh + trans.sh + initrd-network.sh) and mirror it; do not curl `main` at deploy time.
- **Static-IP drift across reboots** — `initrd-network.sh` re-applies the previous IP; keep stage0/1 network config consistent.
- **Build reproducibility** — Containerize the build (Alpine base) and pin all artifact versions.

## References
- [bin456789/reinstall](https://github.com/bin456789/reinstall) — integrated OS-install tool (README + source inspected)
- [mkinitfs](https://gitlab.alpinelinux.org/alpine/mkinitfs) — initramfs build + boot parameters
- [alpine-conf / setup-disk](https://gitlab.alpinelinux.org/alpine/alpine-conf/-/raw/master/setup-disk.in) — disk install + bootloader selection
- [Alpine netboot directory](https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/x86_64/netboot/) — vmlinuz/initramfs/modloop artifacts
- [GNU GRUB manual](https://www.gnu.org/software/grub/manual/grub/html_node/Making-a-GRUB-bootable-CD_002dROM.html) — hybrid ISO via grub-mkrescue
- [iPXE chainloading](https://ipxe.org/howto/chainloading) — PXE/UEFI boot chain
- [dnsmasq man page](https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html) — DHCP/TFTP + client-arch matching
