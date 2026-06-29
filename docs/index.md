---
title: Home
nav_order: 1
permalink: /
---

# havm — Home Assistant VM Runner

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://github.com/IngmarStein/havm/blob/main/LICENSE)
[![Swift 6.4](https://img.shields.io/badge/Swift-6.4-orange?logo=swift&logoColor=white)](https://swift.org)
[![Apple Virtualization](https://img.shields.io/badge/Apple-Virtualization%20Framework-blue?logo=apple&logoColor=white)](https://developer.apple.com/documentation/virtualization)
[![macOS 27+](https://img.shields.io/badge/macOS-27%2B-lightgrey?logo=apple&logoColor=white)](https://www.apple.com/macos)
[![Sponsor](https://img.shields.io/badge/%E2%99%A5-Sponsor-EC4899?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/IngmarStein)

**havm** is a zero-config CLI for running [Home Assistant OS][haos] on Apple
Silicon using Apple's native [Virtualization framework][vz]. One command from
download to boot.

- **No setup required** — downloads and prepares HA OS automatically on first run.
  No Shortcuts, AppleScript, or manual launchd plists. Works with `brew services`.
- **Starts at login** — designed for headless operation as a launchd service.
  Fire-and-forget: your smart home boots with your Mac.
- **Persistent** — all HA OS data (configs, add-ons, history) lives on a raw disk
  image. NVRAM and MAC address survive reboots.
- **USB accessories** — attach coordinators and other USB devices via the menu bar
  item. Hot-plug, no restart needed.
- **SSH key import** — optional virtual CONFIG disk for root SSH on port 22222.
- **Graceful shutdown** — Supervisor API → SSH → force-stop fallback on SIGTERM.
- **Prometheus metrics** — built-in HTTP endpoint for monitoring VM state and USB
  accessories.

**Requires macOS 27 (Golden Gate) or later with Apple Silicon.**

[haos]: https://github.com/home-assistant/operating-system
[vz]: https://developer.apple.com/documentation/virtualization

## Quick Start

### Homebrew (recommended)

```bash
brew install ingmarstein/havm/havm
havm run
```

Or run as a background service:

```bash
brew services start havm
```

### Build from source

```bash
./scripts/build.sh release
.build/release/havm run
```

On first run, `havm` automatically:

1. Downloads the latest stable HA OS release (`haos_generic-aarch64-*.img.xz`)
2. Decompresses the disk image
3. Copies the disk image to persistent storage and resizes it
4. Boots the VM

Subsequent runs skip straight to boot.

## VM Hardware

| Component | Choice | Reason |
|-----------|--------|--------|
| Boot | UEFI (`VZEFIBootLoader`) | Boots directly from the GPT disk image |
| CPU | 4 cores (configurable) | Sufficient for HA OS + add-ons |
| Memory | 4 GiB (configurable) | No balloon — keeps it simple |
| Disk | 32 GiB raw image, VirtIO block | APFS sparse on disk |
| Network | NAT with stable MAC | Works without extra entitlements |
| CONFIG disk | USB mass storage (XHCI) | HA OS imports SSH keys from USB |
| NVRAM | Persisted EFI variable store | GRUB boot state survives reboots |
| Platform | `VZGenericPlatformConfiguration` | Stable machine ID → consistent MAC |

## Data Layout

```
~/Library/Caches/havm/
  haos_generic-aarch64-<version>.img.xz   # Cached download
  haos_generic-aarch64-<version>.img      # Decompressed cache

~/Library/Application Support/havm/
  vm/haos.img                             # Persistent disk image (raw, VirtIO)
  vm/NVRAM                                # EFI variable store
  vm/MachineIdentifier                    # Stable machine ID
  vm/config.img                           # SSH key import disk (if configured)
  vm/havm.pid                             # Process PID (while running)
```

## License

MIT — see [LICENSE](https://github.com/IngmarStein/havm/blob/main/LICENSE).
