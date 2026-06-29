---
layout: default
title: USB Accessories
---

<div class="doc-page" markdown="1">

<div class="doc-nav">
  <a href="{{ site.baseurl }}/">← Home</a>
  <a href="getting-started.html">Getting Started</a>
  <a href="commands.html">Commands</a>
  <a href="configuration.html">Configuration</a>
  <a href="ssh-shutdown.html">SSH & Shutdown</a>
  <a href="metrics.html">Metrics</a>
  <a href="building.html">Building</a>
</div>

# USB Accessories

USB accessory passthrough lets you attach physical devices — Zigbee
coordinators, Z-Wave sticks, Bluetooth dongles — directly to the
Home Assistant VM.

## Enabling

USB accessories are enabled by default. You can explicitly toggle it:

```yaml
usb:
  enabled: true
```

## Usage

When `havm run` starts, macOS shows a menu bar item. Click it and select
the device you want to attach — it's hot-plugged to the running VM
immediately. No restart needed.

Devices are remembered and re-attached automatically shortly after boot
on the next run.

## Troubleshooting

**Menu bar item doesn't appear:**
- Make sure `usb.enabled` is `true` (it is by default)

**Device doesn't show in the list:**
- The device must be connected before you open the menu
- Some devices may need to be unplugged and re-plugged to be discovered

</div>
