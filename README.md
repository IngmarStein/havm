# havm — Home Assistant VM Runner

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Swift 6.4](https://img.shields.io/badge/Swift-6.4-orange?logo=swift&logoColor=white)](https://swift.org)
[![Apple Virtualization](https://img.shields.io/badge/Apple-Virtualization%20Framework-blue?logo=apple&logoColor=white)](https://developer.apple.com/documentation/virtualization)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-lightgrey?logo=apple&logoColor=white)](https://www.apple.com/macos)
[![Sponsor](https://img.shields.io/badge/%E2%99%A5-Sponsor-EC4899?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/IngmarStein)

Zero-config CLI for running [Home Assistant OS][haos] on Apple Silicon using
Apple's native [Virtualization framework][vz]. One command from download to boot.

- **No setup required** — downloads and prepares HA OS automatically on first run.
  No Shortcuts, AppleScript, or manual launchd plists. Works with `brew services`.
- **Starts at login** — designed for headless operation as a launchd service.
  Fire-and-forget: your smart home boots with your Mac.
- **Persistent** — all HA OS data (configs, add-ons, history) lives on a
  raw disk image. NVRAM and MAC address survive reboots.
- **USB accessories** (macOS 27+) — attach coordinators and other USB devices via the
  menu bar item. Hot-plug, no restart needed.
- **SSH key import** — optional virtual CONFIG disk for root SSH on port 22222.
- **Graceful shutdown** — Supervisor API → SSH → force-stop fallback on SIGTERM,
  Ctrl+C, or a logout/restart of the Mac.
- **Dock menu** — while it runs, havm's Dock tile shows boot progress and offers
  the web UI, the SSH command, and a Home Assistant restart.
- **Prometheus metrics** — built-in HTTP endpoint (TCP or a Unix socket) for
  monitoring VM state and USB accessories. Feed into Grafana dashboards or
  alerting rules.

**Requires macOS 15 or later with Apple Silicon.** USB accessory passthrough requires macOS 27 (Golden Gate) or later.

https://github.com/user-attachments/assets/aed92929-dfea-4e6f-b62c-4fed7100d34e

[haos]: https://github.com/home-assistant/operating-system
[releases]: https://github.com/IngmarStein/havm/releases
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

### Without Homebrew

Take `Havm.app` from the [releases][releases], put it wherever you keep apps,
and add it under **System Settings → General → Login Items → Open at Login**.
A login launch carries no arguments, and havm reads that as `run`.

Two things differ from `brew services`. The app is not supervised, so if it
exits — a `poweroff` inside the guest, a crash — it stays down until the next
login. And a login launch has no terminal, so havm's log lines are discarded unless
you set `logging.file` in `config.yml`; the Dock menu shows the guest's address
once Home Assistant answers.

### Build from source

```bash
# Build and sign (no paid developer account needed)
./scripts/build.sh release

# Run — downloads HA OS automatically on first run. Use the app bundle rather
# than .build/release/havm: the bare binary has no bundle around it, so macOS
# has no app identity to attach to the Dock tile or to a USB accessory.
.build/Havm.app/Contents/MacOS/havm run
```

On first run, `havm` automatically:
1. Downloads the latest stable HA OS release that ships a generic aarch64 image
   (`haos_generic-aarch64-*.img.xz`) — a release published for other boards only
   is passed over
2. Decompresses the disk image
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

> **Note:** Only UTM VMs using the **Apple Virtualization** backend can be
> imported. QEMU-based VMs (UTM's default for x86 guests) are not supported —
> the import fails with `Unsupported UTM backend 'QEMU' — only Apple
> Virtualization is supported`.

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

**ASIF disks** — havm creates raw images, but it also accepts an Apple Sparse
Image Format (ASIF) container, which is what a UTM VM on macOS 26 or later may
be using. The format is read from the file's contents rather than its name, and
the disk is then handled as the guest sees it: resizing goes through the
container instead of `ftruncate`, the console cmdline patch runs against the
attached block device, and the `logical` disk metric reports the size recorded
inside the container. On an older host the container cannot be read at all, and
havm says so rather than extending the file and leaving the guest on its
original disk.

If havm data already exists, the command refuses to overwrite it. Use `--force`
(`-f`) to overwrite:

```bash
havm import-utm ~/path/to/Home\ Assistant.utm --force
```

After import, run `havm run` as usual.

[utm]: https://mac.getutm.app

## Configuration

All fields optional — `havm run` works with zero config.
Place overrides in `~/.config/havm/config.yml` (or
`/opt/homebrew/etc/havm/config.yml` when running as a service):

```yaml
vm:
  cpu_count: 4            # default: 4 — takes effect on next boot
  memory_size: "4 GiB"    # default: 4 GiB — takes effect on next boot
  disk_size: "32 GiB"     # default: 32 GiB — can be increased (not shrunk)

network:
  type: bridge            # bridge (default) or nat
  interface: "en0"        # override auto-detected bridge interface
  mac: "02:00:00:00:00:01"  # fixed MAC address (optional, random by default)
  hostname: "homeassistant.local"  # mDNS hostname or static IP

haos:
  release_channel: "pre-release"  # stable (default) or pre-release

ssh:
  authorized_keys: "~/.ssh/id_ed25519.pub"  # imported into HA OS for port 22222

usb:
  enabled: true           # default: true — USB accessory passthrough (macOS 27+)

ha:
  url: "https://homeassistant.local:443"  # default: probed — http://<ip> or http://<ip>:8123
  api_token: "eyJ..."     # HA long-lived access token for REST API calls

logging:
  format: text            # text (default) or json (NDJSON, one object per line)
  level: debug            # debug, info (default), warning, error

metrics:
  enabled: true           # default: false
  type: prometheus        # prometheus (default) — extensibility point for OTLP
  prometheus:
    port: 9210            # default: 9210 — ignored when the host list is socket-only
    host: ["127.0.0.1", "::1"]  # default: both loopbacks — numeric bind addresses; the port
                                # above applies to each. ["::"] for LAN access,
                                # ["unix:///opt/homebrew/var/run/havm.sock"] for a socket

shutdown:
  timeout_seconds: 90     # max wait for Home Assistant to halt (default: 90)
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
| Memory | 4 GiB (configurable) | Balloon lets macOS reclaim idle guest memory under pressure |
| Entropy | VirtIO entropy device | Random numbers for guest kernel crypto and ASLR |
| Disk | 32 GiB raw image, VirtIO block | APFS sparse on disk (only ~6 GiB used after first boot) |
| Network | Bridge with stable MAC | LAN-reachable IP; falls back to NAT without entitlement |
| CONFIG disk | USB mass storage (XHCI) | HA OS imports SSH keys from USB, not VirtIO |
| NVRAM | Persisted EFI variable store | GRUB boot state survives reboots |
| Platform | `VZGenericPlatformConfiguration` | Stable machine ID → consistent MAC |

## USB Accessories

> [!NOTE]
> USB accessory passthrough requires macOS 27 (Golden Gate) or later.
> On macOS 15–26, `havm run` logs a message and continues without it.

To attach a USB accessory while the VM is running, use the menu bar item
that appears when `havm run` starts. Select a device to attach it — it
will be re-attached automatically shortly after boot on
the next run. No restart needed.

The menu bar shows, next to each passed-through accessory, the name of the
app macOS attributes it to — "Havm" when it was opened from Finder or started
by `brew services`, or the terminal app (e.g. "Terminal", "Ghostty") for a
foreground run. This label is decided by macOS; the AccessoryAccess framework
offers no way for havm to change it.

The name comes from the executable's path: a havm started through a symlink
outside its bundle has no app identity, and shows as "unknown app". Earlier
versions of the Homebrew formula started the service through `bin/havm` that
way — `brew update && brew services restart havm` picks up the fix.

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

To log to a file, set `logging.file` — it takes the place of stdout, which is
also the only way to keep a log from a launch with no terminal (Finder, a login
item):

```yaml
logging:
  file: ~/Library/Logs/havm.log
```

Under `brew services`, launchd's `StandardOutPath` already does this, and the
formula points it at `var/log/havm.log`.

## Metrics

`havm` can expose Prometheus metrics on an HTTP endpoint for monitoring
with Prometheus or any compatible scraper. Enable it in the config:

```yaml
metrics:
  enabled: true
```

With metrics enabled, `havm` serves `GET /metrics` on `127.0.0.1:9210` and `[::1]:9210` (both loopbacks) by default.
A `GET /health` endpoint is also available for simple liveness checks.

**Available metrics:**

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `havm_vm_state` | gauge | `state` | VM state (running, stopped, paused, starting, …) |
| `havm_usb_accessories` | gauge | — | USB accessories currently attached to the VM |
| `havm_disk_usage_bytes` | gauge | `disk`, `type` | Disk image size: `type=logical` (configured size) or `allocated` (actual APFS allocation) |

Prometheus also adds its synthetic `up` metric — `1` when the scrape succeeds,
`0` when `havm` is unreachable.

**Prometheus scrape config:**

```yaml
scrape_configs:
  - job_name: 'havm'
    static_configs:
      - targets: ['localhost:9210']
```

An example [Grafana dashboard](docs/metrics.md#grafana-dashboard) is included
in the repository — import `grafana/dashboard.json` to visualize VM status,
USB devices, and disk usage.

The server binds to both loopback addresses by default. To allow LAN access
(e.g., a dedicated Prometheus host), bind to all interfaces:

```yaml
metrics:
  enabled: true
  prometheus:
    host: ["::"]
```

A `host` entry is a bind address, and the port comes from `prometheus.port`
(9210 by default) rather than from the address. Entries must be numeric:
`127.0.0.1`, `::1`, `::`. A host name is not an address `havm` can bind, and a
`host:port` pair puts the port in the wrong key — both are reported rather than
quietly bound somewhere else.

To serve a Unix socket instead of a port — reachable by file permissions
rather than by TCP, which suits a scraper on the same host:

```yaml
metrics:
  enabled: true
  prometheus:
    host: ["unix:///opt/homebrew/var/run/havm.sock"]
```

```bash
curl --unix-socket /opt/homebrew/var/run/havm.sock http://localhost/metrics
```

See [Metrics](docs/metrics.md#unix-socket) for the Prometheus scrape syntax
and the socket-path length limit.

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

1. **HA REST API** — `POST <ha.url>/api/services/hassio/host_shutdown`, where the default
   address is probed: `http://<ip>` on HAOS 2026.8+, `http://<ip>:8123` before it
   (requires a [long-lived access token](https://www.home-assistant.io/docs/authentication/#your-account-profile) in `ha.api_token`)
2. **Debug SSH (port 22222)** — `ssh root@<ip> -p 22222 shutdown -h now`
   (requires `ssh.authorized_keys` for CONFIG disk import)
3. **SSH add-on (port 22)** — `ssh root@<ip> -p 22 ha host shutdown`
   (requires the SSH add-on installed in HA)
4. **Force-stop** — if Home Assistant has not halted by then, the VM is stopped
   immediately (a hard power-off)

The shutdown timeout and API token are configurable:

```yaml
ha:
  api_token: "eyJ..."     # HA long-lived access token
  url: "https://homeassistant.local:443"  # default: probed (see above)

shutdown:
  timeout_seconds: 90     # max wait for Home Assistant to halt (default: 90)
```

`timeout_seconds` covers the whole shutdown rather than each attempt, so it is
the value to raise if the VM gets force-stopped while Home Assistant was still
shutting down cleanly — Home Assistant OS can take a minute or more on installs
with many add-ons or large databases. Under `brew services` launchd sends havm
SIGTERM and kills it 60 seconds later, silently capping the formula's
`stop_timeout` at 60 whatever it says — so a guest that halts within a minute
does so cleanly, and the default 90 only matters outside launchd. A guest that
needs longer has to be stopped outside launchd: run `havm run` in the foreground
and press Ctrl+C, or send SIGTERM to the process directly.

Press Ctrl+C twice to skip the graceful shutdown and stop the VM immediately.

## Homebrew Service

```bash
brew services start havm
```

`havm run` runs in the foreground (ideal for launchd / `brew services`). The
formula configures `keep_alive true` so the VM restarts automatically if it exits.
`brew services stop havm` asks havm to quit and gives it up to 60 seconds to halt
the guest before launchd kills the process.

### Logging Out or Restarting the Mac

The Mac waits for `havm run` during a logout or restart instead of killing it:
havm shuts the guest down first and only then quits, so Home Assistant halts
cleanly instead of being cut off mid-write.

That is also why havm shows a Dock icon while it runs. The icon and the clean
shutdown are the same thing — macOS only waits for a regular application, and
there is no way to hide a regular application's icon. The icon carries a badge
while Home Assistant is still starting. Right-clicking it shows the guest's
address, opens the web UI, and copies the SSH command — plus **Restart Home
Assistant** when `ha.api_token` is configured. Double-clicking `Havm.app` in
Finder starts the VM, the same as `havm run`; stopping it is still Ctrl+C,
SIGTERM, or `brew services stop`.

One thing to know: under `brew services` the VM is supervised, so **Quit** in
the Dock's own menu halts the guest and launchd immediately starts havm again —
it restarts the VM rather than stopping the service. Use `brew services stop
havm` for that. macOS adds Quit to a running app's Dock menu, and an app cannot
remove it.

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

## Comparison

Why use havm instead of other ways to run Home Assistant?

| | havm | UTM | Docker | Raspberry Pi |
|---|---|---|---|---|
| **Setup** | Zero config — `havm run` | Manual download + config | Docker Compose | Flash SD card + configure |
| **HA version** | Full HA OS (Supervisor, add-ons) | Full HA OS | Container only (no add-ons, no Supervisor) | Full HA OS |
| **Headless** | Designed for it | Possible but clunky | Yes | Yes |
| **Background service** | Native launchd / Homebrew | Needs custom wrapper | Docker daemon | systemd |
| **Performance** | Apple Silicon native | Apple Silicon native | Apple Silicon native | Slower (ARM SBC) |
| **Resource use** | ~4 GB RAM (balloon-reclaimable) | ~4 GB RAM | Less (no full OS) | Dedicated device |
| **USB passthrough** | Menu bar accessory | Built-in UI | Not practical | Native GPIO/USB |
| **Snapshots** | Planned (APFS snapshots) | Built-in | Not applicable | Via HA backups |
| **Cost** | $0 (uses existing Mac) | $0 | $0 | $50–200+ |
| **Best for** | Mac users who want a "set and forget" HA | Users who want a VM GUI | Lightweight HA without add-ons | Dedicated always-on appliance |

**In short:** If you have an Apple Silicon Mac that's always on, havm is the
simplest way to run full Home Assistant OS with zero additional hardware.

## License

MIT
