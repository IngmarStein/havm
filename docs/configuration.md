---
layout: default
title: Configuration
---

<div class="doc-page" markdown="1">

<div class="doc-nav">
  <a href="{{ site.baseurl }}/">← Home</a>
  <a href="getting-started.html">Getting Started</a>
  <a href="commands.html">Commands</a>
  <a href="ssh-shutdown.html">SSH & Shutdown</a>
  <a href="usb-accessories.html">USB Accessories</a>
  <a href="metrics.html">Metrics</a>
  <a href="building.html">Building</a>
</div>

# Configuration

All fields are optional — `havm run` works with zero config. Place overrides
in `~/.config/havm/config.yml` (or `/opt/homebrew/etc/havm/config.yml` when
running as a Homebrew service).

## Full Reference

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
  enabled: true           # default: true — enable USB accessory passthrough

ha:
  url: "https://homeassistant.local:443"  # default: http://<discovered-ip>:8123
  api_token: "eyJ..."     # HA long-lived access token for REST API calls

logging:
  format: text            # text (default) or json (NDJSON, one object per line)
  level: debug            # debug, info (default), warning, error

metrics:
  enabled: true           # default: false
  type: prometheus        # prometheus (default) — extensibility point for OTLP
  prometheus:
    port: 9210            # default: 9210
    host: "127.0.0.1"     # default: "127.0.0.1" — set to "0.0.0.0" for LAN access

shutdown:
  timeout_seconds: 30     # max wait for guest to halt (default: 30)
```

## VM Settings

### `cpu_count`
Number of virtual CPU cores. Default is 4, which is sufficient for HA OS
with typical add-ons. Takes effect on the next boot.

### `memory_size`
Memory allocated to the VM. Accepts human-readable sizes like `"4 GiB"`,
`"2048 MiB"`, or `"1 GiB"`. The configured amount is the maximum — a memory
balloon device allows macOS to reclaim idle guest memory under host memory
pressure. Takes effect on the next boot.

### `disk_size`
Size of the persistent disk image. Can be **increased** from the default
of 32 GiB, but **cannot be shrunk**. The underlying file is APFS sparse,
so only actually-used blocks consume physical disk space.

## Network

### `type`
- `bridge` (default) — connects the VM directly to your LAN for mDNS
  discovery and local integrations. Requires the `com.apple.vm.networking`
  entitlement. Distributed binaries include it; self-compiled builds fall
  back to NAT automatically if the entitlement is missing.
- `nat` — the VM shares the Mac's network connection. Works everywhere
  but the guest is behind a NAT with no LAN visibility.

### `interface`
When using bridge networking, specifies the physical interface to bridge
(e.g., `"en0"` for Wi-Fi, `"en5"` for Ethernet). If omitted, havm
auto-detects the primary interface.

### `mac`
A fixed MAC address for the VM's network interface. If not set, a random
address is generated — but `MachineIdentifier` makes it stable across
reboots anyway.

### `hostname`
mDNS hostname (e.g., `"homeassistant.local"`) or static IP. Used for SSH
shutdown connections and HA API calls. If not set, havm discovers the
guest IP from DHCP leases.

## Logging

`havm` logs to stdout. The format and level are configurable both in the
config file and via CLI flags:

```bash
havm run -v                    # debug level
havm run -j                    # NDJSON output
havm run --log-format json --log-level debug
```

For launchd/Homebrew services, JSON logging to a file via
`StandardOutPath` is recommended.

## Metrics

See the [Metrics](metrics.html) page for Prometheus setup, available gauges,
scrape configuration, and Grafana dashboard examples.

</div>
