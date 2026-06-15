# havm — Home Assistant VM Runner

Zero-config CLI for running [Home Assistant OS][haos] on Apple Silicon using
Apple's native [Virtualization framework][vz]. Download, resize, boot — one command.

- **Zero dependencies** — only macOS 27 and Apple Silicon needed.
- **Persistent** — all HA OS data (configs, add-ons, history) lives on a resizable
  raw disk image. NVRAM and MAC address persist across reboots.
- **Headless** — designed to run as a `launchd` background service via Homebrew.
- **USB passthrough** — auto-detects 15 known Zigbee/Z-Wave coordinators (requires
  paid Apple Developer account for the provisioning profile).
- **SSH key import** — optional virtual CONFIG disk for root SSH access on port 22222.
- **Graceful shutdown** — SIGTERM/SIGINT send ACPI shutdown with configurable force-stop
  timeout.

**Requires macOS 27 (Golden Gate) or later with Apple Silicon.**

[haos]: https://github.com/home-assistant/operating-system
[vz]: https://developer.apple.com/documentation/virtualization

## Quick Start

```bash
# Build and sign (no paid developer account needed)
./scripts/build.sh release

# Run — downloads HA OS automatically on first run
.build/release/havm run
```

On first run, `havm` automatically:
1. Downloads the latest stable HA OS release (`haos_generic-aarch64-*.img.xz`)
2. Decompresses it using the system `liblzma` (no external tools)
3. Copies the disk image to persistent storage and resizes it
4. Boots the VM

Subsequent runs skip straight to boot.

## Commands

| Command | Description |
|---------|-------------|
| `havm run` | Start the VM — auto-downloads HA OS on first run |
| `havm run --config <path>` | Use a non-default config file |
| `havm list-usb` | List USB devices with known coordinator detection |
| `havm version` | Print version and system info |

## Configuration

All fields optional — `havm run` works with zero config.
Place overrides in `~/.config/havm/config.yml`:

```yaml
vm:
  cpu_count: 4            # default: 4
  memory_size: "4 GiB"    # default: 4 GiB
  disk_size: "32 GiB"     # default: 32 GiB

network:
  type: bridge            # nat (default) or bridge
  interface: "en0"        # override auto-detected bridge interface

haos:
  release_channel: "pre-release"  # stable (default) or pre-release

ssh:
  authorized_keys: "~/.ssh/id_ed25519.pub"  # imports key into HA OS

usb:
  devices:                # additional USB devices to pass through
    - vendor_id: "0x1CF1"
      product_id: "0x0030"
  auto_connect: true      # default: true — auto-detect known coordinators

shutdown:
  timeout_seconds: 30     # max wait for graceful ACPI shutdown
```

## Data Layout

```
~/Library/Caches/havm/
  haos_generic-aarch64-<version>.img.xz   # Cached download (can be deleted)
  haos_generic-aarch64-<version>.img      # Decompressed cache

~/Library/Application Support/havm/
  vm/haos.img                             # Persistent disk image (raw, VirtIO)
  vm/NVRAM                                # EFI variable store (boot state)
  vm/MachineIdentifier                    # Stable machine ID (consistent MAC)
  vm/config.img                           # SSH key import disk (if configured)
```

## VM Hardware

| Component | Choice | Reason |
|-----------|--------|--------|
| Boot | UEFI | Boots directly from the disk image |
| CPU | 4 cores (configurable) | Sufficient for HA OS + add-ons |
| Memory | 4 GiB (configurable), balloon enabled | macOS reclaims idle guest memory |
| Disk | 32 GiB raw image, VirtIO block | APFS sparse on disk (only ~6 GiB used after first boot) |
| Network | NAT (default), Bridge opt-in | NAT works without extra entitlements |
| USB | XHCI + `VZUSBPassthroughDevice` | Native macOS 27 passthrough |
| Entropy | VirtIO entropy device | Hardware randomness for the guest |
| NVRAM | Persisted EFI variable store | GRUB boot state survives reboots |
| Graphics | None (headless) | Minimizes overhead |

## USB Passthrough

Known coordinators are auto-detected and passed through to the VM:

| Device | Protocol |
|--------|----------|
| ConBee II / ConBee III | Zigbee |
| Home Assistant Connect ZBT-1 / ZBT-2 / SkyConnect | Zigbee |
| Sonoff Zigbee 3.0 Plus (Dongle-E / Dongle-P) | Zigbee |
| SMLIGHT SLZB-06 | Zigbee |
| Tube's ZB Gateway / ZigStar UZG-01 | Zigbee |
| ITead Zigbee 3.0 | Zigbee |
| Aeotec Z-Stick Gen5 / Gen7 | Z-Wave |
| Zooz ZST10 / ZST39 | Z-Wave |
| Z-Wave.Me Z-Station | Z-Wave |
| Nortek GoControl HUSBZB-1 | Zigbee + Z-Wave |
| Home Assistant Yellow | Zigbee + Z-Wave |

Use `havm list-usb` to see what's connected.

**USB passthrough requires a paid Apple Developer account.** The
`com.apple.developer.accessory-access.usb` entitlement needs a provisioning
profile. The VM itself runs fine without it — only USB passthrough is affected.

## SSH Access

Add your public key to the config and HA OS will import it on boot, enabling
root SSH access on port 22222:

```yaml
ssh:
  authorized_keys: "~/.ssh/id_ed25519.pub"
```

`havm` creates a small FAT16 disk image with volume label `CONFIG` containing
your key. HA OS auto-imports it on boot.

## Homebrew Service

Once a Homebrew formula is available:

```bash
brew services start havm
```

The formula's `service` block runs `havm run` with `keep_alive true`.

## Building from Source

No paid Apple Developer account required. Ad-hoc signing works for development.

```bash
git clone https://github.com/username/havm.git
cd havm
./scripts/build.sh release

# Verify
.build/release/havm version
```

**Entitlements:** Two plists are provided:
- `resources/entitlements-dev.plist` — Virtualization + Hypervisor (ad-hoc signing, no paid account)
- `resources/entitlements.plist` — Above + USB passthrough (requires paid account + provisioning profile)

## License

MIT
