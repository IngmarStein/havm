---
layout: default
title: Getting Started
---

<div class="doc-page" markdown="1">

<div class="doc-nav">
  <a href="{{ site.baseurl }}/">← Home</a>
  <a href="commands.html">Commands</a>
  <a href="configuration.html">Configuration</a>
  <a href="ssh-shutdown.html">SSH & Shutdown</a>
  <a href="usb-accessories.html">USB Accessories</a>
  <a href="metrics.html">Metrics</a>
  <a href="building.html">Building</a>
</div>

# Getting Started

## Prerequisites

- macOS 27 (Golden Gate) or later
- Apple Silicon Mac

## Installation

### Homebrew (recommended)

```bash
brew install ingmarstein/havm/havm
```

Verify the installation:

```bash
havm version
```

### Run in the foreground

```bash
havm run
```

The VM boots and stays attached to your terminal. Press Ctrl+C to stop.

### Run as a background service

```bash
brew services start havm
```

The VM starts at login and restarts automatically if it exits. View logs with:

```bash
brew services info havm
```

When running as a service, havm uses these paths:

| Purpose | Path |
|---------|------|
| Config | `/opt/homebrew/etc/havm/config.yml` |
| VM data | `/opt/homebrew/var/lib/havm` |

Override configs go in the service config path. VM data (disk images, NVRAM)
are kept separate from user data to avoid conflicts with foreground runs.

## First Run

On first run, `havm` handles everything automatically:

1. **Download** — fetches the latest stable [Home Assistant OS][haos] release
   for generic aarch64 (`.img.xz`)
2. **Decompress** — decompresses the XZ archive using the built-in libzma wrapper
3. **Copy & resize** — copies the raw disk image to `~/Library/Application
   Support/havm/vm/haos.img` and resizes it (default 32 GiB, configurable)
4. **Boot** — boots via UEFI from the GPT disk image

The download is cached in `~/Library/Caches/havm/`, so subsequent installs or
re-runs skip the fetch.

[haos]: https://github.com/home-assistant/operating-system

## Next Steps

- [Configure](configuration.html) CPU, memory, disk, and network settings
- [Set up SSH access](ssh-shutdown.html) for debug shell and graceful shutdown
- [Enable Prometheus metrics](metrics.html) for monitoring
- [Attach USB accessories](usb-accessories.html) like Zigbee coordinators

## Updating HA OS

HA OS updates are handled from within Home Assistant itself (Settings →
System → Updates). `havm` only manages the VM; it doesn't re-download HA OS
after the initial setup unless you run `havm cleanup` first to clear the cache.

</div>
