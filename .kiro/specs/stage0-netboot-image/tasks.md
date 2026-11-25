# Implementation Plan

## 1. Foundation

- [ ] 1. Containerized build environment
- [x] 1.1 Build the Alpine-based build container with all image tooling and a VM runner
  - Install and pin the initramfs builder, bootloader, ISO tooling, partition utilities, TUI toolkit, SSH server, and a virtual-machine runner for end-to-end tests
  - Done when the container builds successfully and each tool runs with its expected version; the VM runner can boot a test image
  - _Prerequisite for: 3.5 (build), 4.3 (end-to-end tests)_
- [ ] 1.2 Vendor the pinned reinstall bundle
  - Download a specific release of the OS-install tool and its two support scripts, and record the pinned version and checksums
  - Done when the bundle is present with a recorded version and checksums that match the pinned release
  - _Consumed by: 2.2 (adapter), 3.1 (stage1 installer)_
- [ ] 1.3 DeploymentConfig schema and OS catalog
  - Define the cross-stage configuration schema (disk, OS, credentials, network, proxy, access) and the catalog of supported OS/version entries
  - Done when the schema validates a sample config and rejects a malformed one, and the catalog lists each supported OS entry
  - _Requirements: 2.2, 4.1_
- [ ] 1.4 Shared helper libraries
  - Implement network bring-up, disk enumeration/identity, and proxy environment construction as reusable helpers
  - Done when each helper can be exercised from a shell and returns the expected result
  - _Requirements: 3.1, 8.2_

## 2. Core components

- [ ] 2. Core stage0 and stage1 components
- [ ] 2.1 (P) Configuration menu
  - Present a text menu that collects the target disk, OS/version, credentials, and network/proxy settings
  - Display disk identity (model, serial, size) and require an explicit full-wipe confirmation before anything is written
  - Validate the collected choices against the schema and reject unsupported OS selections without writing
  - Done when the menu renders, collects a complete validated config, and writes nothing until the operator confirms
  - _Boundary: Configuration Menu_
  - _Depends: 1.3, 1.4_
  - _Requirements: 2.1, 2.2, 2.3, 3.1, 3.2, 3.3, 4.1, 5.1, 8.1_
- [ ] 2.2 (P) Reinstall adapter and proxy patch
  - Translate a validated config into the OS-install tool's command line and environment, driven by the OS catalog
  - Map credentials and access options to the tool's flags, and own the pinned bundle plus a patch that makes the tool forward proxy environment into its internal install environment
  - Done when a config for each OS category emits the expected command line and environment, an unsupported OS is rejected, and the patch applies cleanly and forwards the proxy variables
  - _Boundary: Reinstall Adapter_
  - _Depends: 1.2, 1.3_
  - _Requirements: 4.2, 4.3, 5.2, 8.2, 9.1_
- [ ] 2.3 (P) Disk provisioner
  - Run the standard disk install to partition the confirmed disk, install a bootloader for both BIOS and UEFI firmware, and install the minimal base OS
  - Operate only on the disk pinned by its stable identifier
  - Done when a loop-device disk is partitioned, made bootable in both firmware modes, and carries the minimal base OS
  - _Boundary: Disk Provisioner_
  - _Depends: 1.4_
  - _Requirements: 6.1, 6.2, 6.3_
- [ ] 2.4 (P) Proxy and network propagator
  - Export proxy environment (including the bypass list and GitHub proxy), detect an unreachable proxy, and author the stage1 proxy profile content
  - Done when a configured proxy is exported correctly, an unreachable proxy produces a reported error without proceeding, and the stage1 profile content is produced
  - _Boundary: Proxy Network Propagator_
  - _Depends: 1.4_
  - _Requirements: 8.2, 8.3_
- [ ] 2.5 (P) Rescue and observability
  - Provide serial-console progress, an HTTP progress log, and a key-based SSH rescue shell
  - Done when progress is visible on serial/HTTP and a failed boot or install drops to a reachable rescue shell
  - _Boundary: Rescue & Observability_
  - _Depends: 1.1_
  - _Requirements: 10.1, 10.2, 10.3_
- [ ] 2.6 (P) Stage1 firstboot
  - On the first boot of the disk-installed minimal system, read the config and auto-run the OS-install tool with no operator input
  - Implement against the Reinstall Adapter's documented config-to-command contract rather than duplicating the mapping
  - Done when the firstboot script runs the install unattended from a validated config
  - _Boundary: Stage1 Firstboot_
  - _Depends: 1.3_
  - _Requirements: 7.2, 9.2_

## 3. Integration

- [ ] 3. Integration and wiring
- [ ] 3.1 Stage1 installer
  - Inject the deployment payload — the reinstall bundle, the config, the firstboot hook, and the proxy profile — into the disk-installed system via chroot, without re-partitioning
  - Done when the disk-installed system contains all injected artifacts and boots to a ready firstboot
  - _Depends: 2.2, 2.3, 2.4, 2.6_
  - _Requirements: 7.1_
- [ ] 3.2 Stage0 orchestrator
  - Detect firmware and bring up the network, then drive menu → disk provision → stage1 install → reboot
  - Gate every disk-touching step behind confirmation and drop to rescue on boot/menu failure without writing
  - Done when the full stage0 flow runs in order and never writes before confirmation
  - _Depends: 2.1, 2.3, 2.4, 3.1_
  - _Requirements: 1.4, 7.3_
- [ ] 3.3 Stage0 initramfs feature
  - Define the initramfs feature that bakes the complete stage0 payload (scripts, config, bundle, and tool binaries) into a bootable initramfs
  - Done when a built initramfs contains every payload script and tool and boots into the stage0 menu
  - _Depends: 3.2_
  - _Requirements: 1.2_
- [ ] 3.4 Boot configurations
  - Author the network-boot script, the DHCP/TFTP configuration with firmware-based selection, and the bootloader menu used by the ISO and USB images
  - Done when each configuration chain-loads the same kernel, initramfs, and module bundle for both BIOS and UEFI
  - _Requirements: 1.3_
- [ ] 3.5 Build assembly
  - Assemble the stage0 payload into three bootable forms — network boot, hybrid ISO, and raw USB image — for both BIOS and UEFI
  - Done when all three artifacts build and boot the menu
  - _Depends: 3.3, 3.4_
  - _Requirements: 1.1, 1.2, 1.3_

## 4. Validation

- [ ] 4. Validation
- [ ] 4.1 Unit tests
  - Cover config-to-command-line mapping for each OS category, schema validation, and proxy environment construction
  - Done when the unit suite passes
  - _Requirements: 4.2, 2.2, 8.2_
- [ ] 4.2 Integration tests
  - Cover disk installation on a loop device, stage1 artifact injection, and the proxy patch application
  - Done when the integration suite passes in the build container
  - _Requirements: 6.1, 7.1, 8.2_
- [ ] 4.3 End-to-end tests
  - Boot stage0 via network and ISO in a virtual machine, script the menu, and verify the final OS boots; verify unsupported-OS rejection and proxy traversal
  - Done when end-to-end tests pass for both boot paths and the negative cases
  - _Depends: 3.5_
  - _Requirements: 1.2, 4.3, 7.2, 8.2, 8.3, 9.1, 10.3_

## 5. Documentation

- [ ] 5. Documentation
- [ ] 5.1 README
  - Write the project overview, prerequisites, build instructions for the three images, and a quick boot-start pointer
  - Done when a reader can build and boot all three images from the README alone
  - _Depends: 3.5_
- [ ] 5.2 User guide
  - Write the operator walkthrough: the three boot methods, every menu field (disk, OS, credentials, network/proxy), the stage sequence, and rescue/troubleshooting
  - Done when an operator can complete a deployment and recover a failed one using the guide
  - _Depends: 3.5_
