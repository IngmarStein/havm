---
title: Getting Started
nav_order: 2
---

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

## First Run

On first run, `havm` handles everything automatically:

1. **Download** — fetches the latest stable [Home Assistant OS][haos] release
   for generic aarch64 (`.img.xz`)
2. **Decompress** — decompresses the XZ archive using the built-in liblzma wrapper
3. **Copy & resize** — copies the raw disk image to `~/Library/Application
   Support/havm/vm/haos.img` and resizes it (default 32 GiB, configurable)
4. **Boot** — boots via UEFI from the GPT disk image

The download is cached in `~/Library/Caches/havm/`, so subsequent installs or
re-runs skip the fetch.

[haos]: https://github.com/home-assistant/operating-system

## Next Steps

- [Configure]({% link configuration.md %}) CPU, memory, disk, and network settings
- [Set up SSH access]({% link ssh-shutdown.md %}) for debug shell and graceful shutdown
- [Enable Prometheus metrics]({% link metrics.md %}) for monitoring
- [Attach USB accessories]({% link usb-accessories.md %}) like Zigbee coordinators

## Updating HA OS

HA OS updates are handled from within Home Assistant itself (Settings →
System → Updates). `havm` only manages the VM; it doesn't re-download HA OS
after the initial setup unless you run `havm cleanup` first to clear the cache.
