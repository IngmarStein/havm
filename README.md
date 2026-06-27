# havm — Home Assistant VM Runner

Zero-config CLI for running [Home Assistant OS][haos] on Apple Silicon using
Apple's native [Virtualization framework][vz]. One command from download to boot.

- **No setup required** — downloads and prepares HA OS automatically on first run.
  No Shortcuts, AppleScript, or manual launchd plists. Works with `brew services`.
- **Starts at login** — designed for headless operation as a launchd service.
  Fire-and-forget: your smart home boots with your Mac.
- **Persistent** — all HA OS data (configs, add-ons, history) lives on a
  raw disk image. NVRAM and MAC address survive reboots.
- **USB accessories** — attach coordinators and other USB devices via the
  menu bar item. Hot-plug, no restart needed.
- **SSH key import** — optional virtual CONFIG disk for root SSH on port 22222.
- **Graceful shutdown** — Supervisor API → SSH → force-stop fallback on SIGTERM.

**Requires macOS 27 (Golden Gate) or later with Apple Silicon.**

https://github.com/user-attachments/assets/aed92929-dfea-4e6f-b62c-4fed7100d34e

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
| `havm import-utm` | Import a Home Assistant VM from UTM |
| `havm cleanup` | Clear cached HA OS downloads from `~/Library/Caches/havm/` |
| `havm version` | Print version and system info |

Run `havm --help` or `havm <command> --help` for flags and options.

## Importing from UTM

If you have an existing Home Assistant VM in [UTM][utm], you can import it
into havm in one command:

```bash
havm import-utm ~/Library/Containers/com.utmapp.UTM/Data/Documents/Home\ Assistant.utm
```

The import copies (not moves) the VM data from the UTM bundle into havm's
data directory and generates a config file with matching settings. Your UTM
bundle is left intact.

**What gets imported:**

| UTM data | havm destination |
|----------|-----------------|
| HA OS disk image (largest writable drive) | `~/Library/Application Support/havm/vm/haos.img` |
| EFI variable store (`efi_vars.fd`) | `NVRAM` |
| Machine identifier | `MachineIdentifier` (stable MAC address) |
| MAC address | `MACAddress` |
| CPU, memory, network settings | `~/.config/havm/config.yml` |

**What's NOT imported:**

- **Auxiliary disks** — UTM VMs may have additional data drives. havm imports
  only the largest writable disk. Auxiliary disks are reported as warnings so
  you can copy them manually if needed.
- **SSH keys** — UTM doesn't use havm's CONFIG disk mechanism. If you had SSH
  keys configured in UTM, add them to `ssh.authorized_keys` in havm's config.
- **UTM-specific settings** — display, audio, clipboard, Rosetta, and other
  UTM-exclusive features are ignored.

**Sparse file handling** — HA OS disk images are APFS sparse files (e.g., 21 GB
physical for a 34 GB logical disk). The import uses `clonefile(2)` for an
instant copy-on-write clone on the same volume, preserving sparseness without
blowing up disk usage. If the source is on a different volume, it falls back
to a sparse-aware copy that skips zero-filled blocks.

If havm data already exists, the command refuses to overwrite it. Use `--force`
(`-f`) to overwrite:

```bash
havm import-utm ~/path/to/Home\ Assistant.utm --force
```

After import, run `havm run` as usual.

[utm]: https://mac.getutm.app

## Configuration

All fields optional — `havm run` works with zero config.
Place overrides in `~/.config/havm/config.yml`:

```yaml
vm:
  cpu_count: 4            # default: 4 — takes effect on next boot
  memory_size: "4 GiB"    # default: 4 GiB — takes effect on next boot
  disk_size: "32 GiB"     # default: 32 GiB — can be increased (not shrunk)

network:
  type: nat               # nat (default) or bridge
  interface: "en0"        # override auto-detected bridge interface
  mac: "02:00:00:00:00:01"  # fixed MAC address (optional, random by default)
  hostname: "homeassistant.local"  # mDNS hostname or static IP

haos:
  release_channel: "pre-release"  # stable (default) or pre-release

ssh:
  authorized_keys: "~/.ssh/id_ed25519.pub"  # imported into HA OS for port 22222

usb:
  enabled: true           # default: true — enable USB accessory passthrough

ha:
  url: "https://homeassistant.local:443"  # default: http://<discovered-ip>:8123
  api_token: "eyJ..."     # HA long-lived access token for REST API calls

logging:
  format: text            # text (default) or json (NDJSON, one object per line)
  level: debug            # debug, info (default), warning, error

shutdown:
  timeout_seconds: 30     # max wait for guest to halt (default: 30)
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

## USB Accessories

To attach a USB accessory while the VM is running, use the menu bar item
that appears when `havm run` starts. Select a device to attach it — it
will be re-attached automatically shortly after boot on
the next run. No restart needed.

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
```

To log to a file, direct stdout via launchd's `StandardOutPath`.

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
   (requires a [long-lived access token](https://www.home-assistant.io/docs/authentication/#your-account-profile) in `ha.api_token`)
2. **Debug SSH (port 22222)** — `ssh root@<ip> -p 22222 shutdown -h now`
   (requires `ssh.authorized_keys` for CONFIG disk import)
3. **SSH add-on (port 22)** — `ssh root@<ip> -p 22 ha host shutdown`
   (requires the SSH add-on installed in HA)
4. **Force-stop** — if all above fail, the VM is stopped immediately

The shutdown timeout and API token are configurable:

```yaml
ha:
  api_token: "eyJ..."     # HA long-lived access token
  url: "https://homeassistant.local:443"  # default: http://<ip>:8123

shutdown:
  timeout_seconds: 30     # max wait for guest to halt (default: 30)
```

Press Ctrl+C twice to skip the graceful shutdown and stop the VM immediately.

## Homebrew Service

```bash
brew services start havm
```

`havm run` runs in the foreground (ideal for launchd / `brew services`). The
formula configures `keep_alive true` so the VM restarts automatically if it exits.

## Building from Source

Ad-hoc signing works for basic VM functionality. USB accessories require
a paid Apple Developer account (the entitlement is gated by Apple).

```bash
git clone https://github.com/username/havm.git
cd havm
cp resources/build.xcconfig.example resources/build.xcconfig
# Set your team ID in build.xcconfig
./scripts/build.sh release
.build/release/havm version
```

**Entitlement tiers:**

| Tier | Account | USB | Bridge | File |
|------|---------|-----|--------|------|
| 1 | Free | No | No | `entitlements-tier1.plist` |
| 2 | Paid | Yes | No | `entitlements-tier2.plist` |
| 3 | Paid + Apple approval | Yes | Yes | `entitlements.plist` |

Set `ENTITLEMENTS_TIER` and `DEVELOPMENT_TEAM` in `resources/build.xcconfig`.
Build `havm.xcodeproj` once in Xcode to generate the provisioning profile
for `ch.ingmar.havm`.

## License

MIT
