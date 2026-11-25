# Requirements Document

## Introduction

Operators who need to deploy Linux or Windows onto bare-metal or VPS machines over the network currently have no automated path. The `reinstall` tool can install 20+ Linux distributions and Windows, but only from an already-running operating system with an on-disk bootloader, so it cannot run directly from a RAM-only network-booted image on a blank disk. This project delivers a menu-driven "stage0" installer that (1) boots a machine from the network, a USB drive, or an ISO image, (2) lets the operator choose the target disk and operating system, (3) prepares the disk and installs a bootloader, (4) installs a minimal stage1 system with `reinstall` and the operator's network/proxy settings baked in, and (5) reboots into stage1, which automatically runs `reinstall` to install the final operating system.

## Boundary Context

- **In scope**: the stage0 installer and the operator-visible workflow it drives — booting from network, USB, or ISO media, configuration menu, disk selection and preparation, bootloader installation, installation of a minimal stage1 system with `reinstall` pre-configured, proxy/network propagation, and the unattended handoff that ends with the machine booting the chosen final operating system.
- **Out of scope**: the actual operating-system installation logic (that is performed by the integrated `reinstall` tool, not reimplemented here); fleet management or inventory; secure-boot signing of the boot chain; and the internal design of the stage1 environment beyond the observable requirement that it is a minimal system capable of running `reinstall`.
- **Adjacent expectations**: the integrated `reinstall` tool must be able to install the selected operating system given a running minimal system and an on-disk bootloader; target machines must be reachable on the network and have Secure Boot disabled (or a signed boot path provided) so the network-booted and disk-installed boot chain can run.

## Requirements

### Requirement 1: Boot Media

**Objective:** As an operator, I want to boot the stage0 installer from the network, a USB drive, or an ISO image, so that I can start an OS deployment on machines with or without a network boot path or a pre-existing operating system.

#### Acceptance Criteria
1. The stage0 installer shall be provided as a network-boot image, a bootable USB image, and a bootable ISO image.
2. When an operator boots a target machine from any of these media, the stage0 installer shall load into memory without requiring a pre-existing operating system on the target disk.
3. The stage0 installer shall boot on machines with either BIOS or UEFI firmware.
4. If booting from a supported medium fails, the stage0 installer shall not modify any disk.

### Requirement 2: Configuration Menu

**Objective:** As an operator, I want an interactive menu after boot, so that I can select the target disk, operating system, and installation options before anything is written.

#### Acceptance Criteria
1. When the stage0 installer finishes loading, it shall present a menu of configuration choices.
2. The menu shall allow the operator to select the target disk, the operating system type and version, credentials, and network/proxy settings.
3. While the operator is configuring options, the stage0 installer shall not modify any disk.

### Requirement 3: Disk Selection and Safety

**Objective:** As an operator, I want to choose the exact target disk and confirm its identity, so that I do not erase the wrong disk.

#### Acceptance Criteria
1. When the operator selects a target disk, the stage0 installer shall display identifying information for that disk, including model, serial, and size.
2. The stage0 installer shall require the operator to confirm that the selected disk's entire content will be erased before proceeding.
3. If the operator does not confirm, the stage0 installer shall not modify the disk.

### Requirement 4: Operating System Selection

**Objective:** As an operator, I want to choose the operating system type and version to install, so that the deployment installs the intended system.

#### Acceptance Criteria
1. The stage0 installer shall offer a catalog of supported operating systems, including Linux distributions, Windows, and raw disk images.
2. When the operator chooses an operating system and version, the stage0 installer shall record that selection and use it to drive the subsequent installation.
3. If the operator selects an operating system that the integrated `reinstall` tool cannot install, the stage0 installer shall report the selection as unsupported rather than proceeding.

### Requirement 5: Installation Credentials

**Objective:** As an operator, I want to specify the login credentials for the final operating system, so that the installed system is immediately accessible with known credentials.

#### Acceptance Criteria
1. The stage0 installer shall allow the operator to specify a username, password, and/or SSH key for the final installed operating system.
2. When the final operating system boots, it shall accept the credentials the operator specified during configuration.

### Requirement 6: Disk Preparation and Bootloader

**Objective:** As an operator, I want the selected disk to be partitioned and made bootable, so that the machine can boot into the next installation stage from disk.

#### Acceptance Criteria
1. When the operator confirms the target disk, the stage0 installer shall partition the selected disk and install a bootloader on it.
2. The installed bootloader shall support booting the disk on both BIOS and UEFI firmware.
3. While preparing the disk, the stage0 installer shall not modify any disk other than the selected target disk.

### Requirement 7: Minimal System Installation and Automatic Handoff

**Objective:** As an operator, I want the installer to place a minimal system with `reinstall` pre-configured onto the disk, so that the OS installation proceeds automatically without further input.

#### Acceptance Criteria
1. When disk preparation completes, the stage0 installer shall install a minimal operating system onto the target disk with the integrated `reinstall` tool and the operator's configuration baked in.
2. When the machine next boots from the disk, the disk-installed minimal system shall automatically start the OS installation for the selected operating system.
3. The stage0 installer shall reboot the machine into the disk-installed minimal system after installation completes.

### Requirement 8: Proxy and Network Configuration

**Objective:** As an operator, I want to configure an egress proxy and network settings, so that all download stages succeed in restricted or firewalled networks.

#### Acceptance Criteria
1. The stage0 installer shall allow the operator to specify a proxy, a list of hosts that bypass the proxy, and DHCP or static network settings.
2. Where a proxy is configured, the stage0 installer shall apply it to its own downloads and to the downloads performed by the integrated `reinstall` tool during installation.
3. If the configured proxy is unreachable, the stage0 installer shall report the network error and leave the machine recoverable.

### Requirement 9: Final Operating System Boot

**Objective:** As an operator, I want the machine to boot into the selected operating system at the end of the process, so that the deployment is complete without further intervention.

#### Acceptance Criteria
1. When the integrated `reinstall` tool completes the OS installation, the machine shall boot into the selected operating system.
2. The stage0 installer shall not require operator input after the machine reboots into the disk-installed minimal system.

### Requirement 10: Observability and Rescue

**Objective:** As an operator, I want to monitor installation progress and recover a failed deployment, so that I can diagnose problems without physical access.

#### Acceptance Criteria
1. While installation is in progress, the stage0 installer and the integrated `reinstall` tool shall expose progress through a serial console and an HTTP log.
2. The stage0 installer shall allow the operator to reach a recovery shell or SSH session when installation fails.
3. If installation fails, the machine shall remain bootable or reachable so the operator can retry or diagnose.
