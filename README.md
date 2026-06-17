# havm — Home Assistant VM Runner

Zero-config CLI for running [Home Assistant OS][haos] on Apple Silicon using
Apple's native [Virtualization framework][vz]. Download, resize, boot — one command.

- **Zero dependencies** — only macOS 27 and Apple Silicon needed.
- **Persistent** — all HA OS data (configs, add-ons, history) lives on a resizable
  raw disk image. NVRAM and MAC address persist across reboots.
- **Headless** — designed to run as a `launchd` background service via Homebrew.
- **USB passthrough** — attach Zigbee/Z-Wave coordinators via the havm-helper app
  (requires paid Apple Developer account + provisioning profile).
- **SSH key import** — optional virtual CONFIG disk for root SSH access on port 22222.
- **Graceful shutdown** — tries Supervisor API, then SSH (port 22222/22),
  with instant force-stop fallback.

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
| `havm run -c <path>` | Use a non-default config file |
| `havm run -j` | JSON log output (shorthand for `--log-format json`) |
| `havm run -v` | Verbose output (shorthand for `--log-level debug`) |
| `havm list-usb` | List USB devices persisted by havm-helper |
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
  type: nat               # nat (default) or bridge
  interface: "en0"        # override auto-detected bridge interface
  hostname: "homeassistant.local"  # mDNS hostname or static IP

haos:
  release_channel: "pre-release"  # stable (default) or pre-release

ssh:
  authorized_keys: "~/.ssh/id_ed25519.pub"  # imported into HA OS for port 22222

usb:
  enabled: true           # default: true — attach persisted USB accessories

logging:
  format: text            # text (default) or json (NDJSON, one object per line)
  level: debug            # debug, info (default), warning, error
  file: "/var/log/havm.log"  # write logs to a file instead of stdout

shutdown:
  timeout_seconds: 30     # max wait for guest to halt (default: 30)
  api_token: "eyJ..."     # HA long-lived access token for REST API shutdown
  ha_url: "https://homeassistant.local:443"  # override default http://<ip>:8123
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
  vm/havm.pid                             # Process PID (while running)
  usb/<id>.accessory                      # Persisted USB accessories (havm-helper)
```

## VM Hardware

| Component | Choice | Reason |
|-----------|--------|--------|
| Boot | UEFI (`VZEFIBootLoader`) | Boots directly from the GPT disk image |
| CPU | 4 cores (configurable) | Sufficient for HA OS + add-ons |
| Memory | 4 GiB (configurable) | No balloon — keeps it simple |
| Disk | 32 GiB raw image, VirtIO block | APFS sparse on disk (only ~6 GiB used after first boot) |
| Network | NAT with stable MAC | Works without extra entitlements |
| CONFIG disk | USB mass storage (XHCI) | HA OS imports SSH keys from USB, not VirtIO |
| NVRAM | Persisted EFI variable store | GRUB boot state survives reboots |
| Platform | `VZGenericPlatformConfiguration` | Stable machine ID → consistent MAC |

## USB Passthrough

USB passthrough requires the **havm-helper** companion app — a Dock application
that discovers and selects USB devices for the VM.

**Architecture:**
- `havm-helper.app` discovers devices via `AAUSBAccessoryManager` (needs Dock app)
  and persists `AAUSBAccessory` objects to `~/Library/Application Support/havm/usb/`
- `havm run` links `AccessoryAccess.framework` to unarchive the persisted objects
  and create `VZUSBPassthroughDeviceConfiguration` for the VM
- `AAUSBAccessory` conforms to `NSSecureCoding` — it's designed for cross-process transfer

**Requirements:**
- Paid Apple Developer account (for `com.apple.developer.accessory-access.usb`)
- Provisioning profile with the USB passthrough entitlement
- `havm-helper.app` — companion app that persists device selections

The VM runs fine without USB passthrough — only coordinator attachment is affected.

## Logging

`havm` logs to stdout by default. The format and level are configurable both
in the config file and via CLI flags:

```bash
havm run -v                    # debug level (shorthand for --log-level debug)
havm run -j                    # NDJSON output (shorthand for --log-format json)
havm run --log-format json --log-level debug
```

For launchd/Homebrew services, JSON logging to a file is recommended:

```yaml
logging:
  format: json
  level: info
  file: "/opt/homebrew/var/log/havm.log"
```

With `logging.file`, the process still logs to stdout (launchd captures it),
but also writes a structured NDJSON log file for monitoring and debugging.

## SSH Access

Add your public key to the config and HA OS will import it on boot, enabling
root SSH access on port 22222:

```yaml
ssh:
  authorized_keys: "~/.ssh/id_ed25519.pub"
```

`havm` creates a small MBR + FAT16 disk image with volume label `CONFIG` and an
`authorized_keys` file. HA OS auto-imports it on boot and starts `dropbear` on
port 22222. Without this file, HA OS disables the debug SSH server.

For the regular SSH add-on (Terminal & SSH or Advanced SSH & Web Terminal),
install the add-on via the HA web UI — it listens on port 22.

## Graceful Shutdown

On SIGTERM or Ctrl+C, `havm` tries these shutdown methods in order, falling
through to the next if one fails:

1. **HA REST API** — `POST http://<ip>:8123/api/services/hassio/host_shutdown`
   (requires a [long-lived access token](https://www.home-assistant.io/docs/authentication/#your-account-profile) in `shutdown.api_token`)
2. **Debug SSH (port 22222)** — `ssh root@<ip> -p 22222 shutdown -h now`
   (requires `ssh.authorized_keys` for CONFIG disk import)
3. **SSH add-on (port 22)** — `ssh root@<ip> -p 22 ha host shutdown`
   (requires the SSH add-on installed in HA)
4. **Force-stop** — if all above fail, the VM is stopped immediately

The shutdown timeout is configurable:

```yaml
shutdown:
  timeout_seconds: 30     # max wait for guest to halt (default: 30)
  api_token: "eyJ..."     # HA long-lived access token
  ha_url: "https://homeassistant.local:443"  # default: http://<ip>:8123
```

Press Ctrl+C twice to skip the graceful shutdown and stop the VM immediately.

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
