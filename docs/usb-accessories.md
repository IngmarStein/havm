---
layout: default
title: USB Accessories
---

<div class="doc-page">

<div class="doc-nav">
  <a href="/">← Home</a>
  <a href="getting-started">Getting Started</a>
  <a href="commands">Commands</a>
  <a href="configuration">Configuration</a>
  <a href="ssh-shutdown">SSH & Shutdown</a>
  <a href="metrics">Metrics</a>
  <a href="building">Building</a>
</div>

# USB Accessories

USB accessory passthrough lets you attach physical devices — Zigbee
coordinators, Z-Wave sticks, Bluetooth dongles — directly to the
Home Assistant VM.

<div class="note">
USB accessories require a <strong>paid Apple Developer account</strong>
(Tier 2 or 3). The <code>com.apple.developer.accessory-access.usb</code>
entitlement is gated by Apple.
</div>

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

## Architecture

- `ServiceRuntime.setupUSBDiscovery()` boots `NSApplication.accessory`
  and registers `AAUSBAccessoryListener`. The menu bar item is the user's
  selection UI.
- On connect: listener hot-attaches via `VZUSBPassthroughDevice` +
  `usbControllers.first?.attach(device:)` with fresh registry IDs.
- On boot: listener registers after VM start, hot-attaches previously
  selected devices.

## Entitlements

Two entitlements are required for USB passthrough:

| Entitlement | Description |
|-------------|-------------|
| `com.apple.security.device.usb` | Standard Hardened Runtime entitlement |
| `com.apple.developer.accessory-access.usb` | Restricted — requires provisioning profile |

The CLI builds as a minimal `Havm.app` bundle so Xcode's provisioning
profile covers the restricted entitlement. Build `havm.xcodeproj` once
(⌘B) to generate the profile — the build script picks it up automatically.

## Troubleshooting

**Menu bar item doesn't appear:**
- Make sure `usb.enabled` is `true` (it is by default)
- Verify you're on Tier 2 or 3 (`ENTITLEMENTS_TIER` in `build.xcconfig`)
- Check that the provisioning profile is present

**Device doesn't show in the list:**
- The device must be connected before you open the menu
- Some devices may need to be unplugged and re-plugged to be discovered

</div>
