---
layout: default
title: Commands
---

<div class="doc-page" markdown="1">

<div class="doc-nav">
  <a href="{{ site.baseurl }}/">← Home</a>
  <a href="getting-started.html">Getting Started</a>
  <a href="configuration.html">Configuration</a>
  <a href="ssh-shutdown.html">SSH & Shutdown</a>
  <a href="usb-accessories.html">USB Accessories</a>
  <a href="metrics.html">Metrics</a>
  <a href="building.html">Building</a>
</div>

# Commands

| Command | Description |
|---------|-------------|
| `havm run` | Start the VM — auto-downloads HA OS on first run |
| `havm import-utm` | Import a Home Assistant VM from UTM |
| `havm cleanup` | Clear cached HA OS downloads from `~/Library/Caches/havm/` |
| `havm version` | Print version and system info |

Run `havm --help` or `havm <command> --help` for flags and options.

## `havm run`

Starts the VM. On first run, downloads and prepares HA OS automatically.

```bash
havm run                        # start with defaults
havm run -v                     # debug logging
havm run -j                     # NDJSON log output
havm run --console              # debug: interactive serial console (hvc0)
```

Press Ctrl+C once for graceful shutdown (tries REST API → SSH → force-stop).
Press Ctrl+C twice to skip and force-stop immediately.

### Debug Console (`--console`)

Connects your terminal to the VM's virtio serial console (`/dev/hvc0`)
for debugging. You get a direct root shell — no SSH, no network required.
Useful when networking is misconfigured or SSH is unavailable.

```bash
havm run --console
```

In console mode:
- Keystrokes are passed directly to the guest (raw terminal mode)
- Ctrl+C goes to the guest as `^C` — type `poweroff` to shut down
- To force-stop, send SIGTERM from another terminal: `kill <pid>`
- Log output goes to stderr, guest console output goes to stdout
- `--json` is ignored — text log format is forced to keep stdout clean

## `havm import-utm`

Import an existing Home Assistant VM from [UTM][utm] into havm.

```bash
havm import-utm ~/Library/Containers/com.utmapp.UTM/Data/Documents/Home\ Assistant.utm
```

The import **copies** (not moves) the VM data. Your UTM bundle is left intact.

### What gets imported

| UTM data | havm destination |
|----------|-----------------|
| HA OS disk image (largest writable drive) | `~/Library/Application Support/havm/vm/haos.img` |
| EFI variable store (`efi_vars.fd`) | `NVRAM` |
| Machine identifier | `MachineIdentifier` (stable MAC address) |
| MAC address | `MACAddress` |
| CPU, memory, network settings | `~/.config/havm/config.yml` |

### What's NOT imported

- **Auxiliary disks** — additional data drives are reported as warnings
- **SSH keys** — add them to `ssh.authorized_keys` in havm's config
- **UTM-specific settings** — display, audio, clipboard, Rosetta

### Sparse file handling

HA OS disk images are APFS sparse files (e.g., 21 GB physical for 34 GB
logical). The import uses `clonefile(2)` for an instant copy-on-write clone
on the same volume. Cross-volume imports fall back to a sparse-aware copy
that skips zero-filled blocks.

### Force overwrite

```bash
havm import-utm ~/path/to/Home\ Assistant.utm --force
```

[utm]: https://mac.getutm.app

## `havm cleanup`

Clears cached HA OS downloads from `~/Library/Caches/havm/`. Does **not**
touch the persistent VM data in `~/Library/Application Support/havm/`.

Use this to free up disk space or force a re-download of HA OS on the
next `havm run`.

## `havm version`

Prints the havm version, macOS version, and architecture:

```
havm 0.1.4
macOS 27.0 (arm64)
```

</div>
