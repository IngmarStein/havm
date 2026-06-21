# CLAUDE.md

## Project

`havm` — Zero-config CLI for running Home Assistant OS on Apple Silicon using the native Virtualization framework. macOS 27 minimum. Swift 6.4.

## Build & Test

```bash
./scripts/build.sh release    # Build + ad-hoc sign with dev entitlements
swift test                    # 8 tests in HavmCoreTests
./.build/release/havm run     # Run the VM (blocks; Ctrl+C to stop)
```

## Architecture

```
Havm (CLI, AsyncParsableCommand)
├── RunCommand       → HAOSSetup → VMController → ServiceRuntime
├── ListUSBCommand   → USBManager
└── VersionCommand

HavmCore (library)
├── Config           YAML config, paths, parsing (Yams)
├── HAOSSetup        GitHub release fetch, download .img.xz, xz decompress (CXZ/libzma),
│                    copy+resize disk, SSH CONFIG disk
├── VMController     VZEFIBootLoader + VZEFIVariableStore, storage, network, USB,
│                    machine identifier persistence, @MainActor on start()
├── USBManager       AccessoryAccess framework for USB passthrough
├── KnownCoordinators 15 Zigbee/Z-Wave coordinators (vendor/product IDs)
├── CONFIGDiskBuilder MBR + FAT16 with VFAT LFN, volume label "CONFIG",
│                    authorized_keys file — HA OS auto-imports for SSH
└── Config/MemorySize Human-readable sizes ("4 GiB" → bytes)

HavmRuntime
└── ServiceRuntime   SIGTERM/SIGINT → SSH shutdown (port 22222/22) →
                     force-stop fallback, DHCP lease guest IP detection

CXZ (C target)
└── xz_decompress    dlopen liblzma for XZ decompression (no external tools)
```

## Key Design Decisions

- **VZEFIBootLoader** — boots directly from GPT disk via UEFI. No kernel extraction, no kernel command line, no initrd. Just point at the disk image.
- **NAT networking by default** — no extra entitlements needed. Bridge available via config (`network.type: bridge`).
- **@MainActor on VM start** — `VZVirtualMachine.start()` has `dispatch_assert_queue` requiring the main queue.
- **APFS sparse files** — disk resize uses `ftruncate` (seek + write zero byte). APFS automatically hole-punches.
- **Stable machine ID** — persists `VZGenericMachineIdentifier` for consistent MAC addresses across reboots.
- **EFI variable store** — persists NVRAM file for GRUB boot state survival across reboots.
- **SSH key import** — creates a 2 MB MBR + FAT16 disk with VFAT LFN entries for `authorized_keys`. HA OS auto-imports from USB mass storage on boot for root SSH on port 22222.
- **Graceful shutdown chain** — on Ctrl+C/SIGTERM:
  1. `POST /api/services/hassio/host_shutdown` on port 8123 (REST API service call, requires `shutdown.api_token`)
  2. `ssh root@<ip> -p 22222 shutdown -h now` (debug SSH, requires `ssh.authorized_keys`)
  3. `ssh root@<ip> -p 22 ha host shutdown` (SSH add-on)
  4. `vm.stop()` — force-stop fallback
  ACPI `requestStop()` is not used — HA OS on aarch64 uses PSCI and ignores ACPI power button events.
- **Guest IP detection** — parses `/var/db/dhcpd_leases` by MAC address for instant, reliable IP discovery (no ping/ARP scanning).
- **VFAT LFN** — the `0x40` (LAST_LONG_ENTRY) flag must be on the highest sequence number (end of filename), not the lowest (beginning). Getting this wrong causes both macOS and Linux to truncate the filename.

## Entitlements

| File | Contents | Signing |
|------|----------|---------|
| `resources/entitlements-dev.plist` | virtualization + hypervisor + `device.usb` | Ad-hoc (`--sign -`), no paid account |
| `resources/entitlements.plist` | Above + `vm.networking` + `accessory-access.usb` | Requires paid Developer ID + provisioning profile |

- `com.apple.developer.accessory-access.usb` is restricted — SIGKILL with ad-hoc signing.
- `com.apple.vm.networking` is restricted — SIGKILL with ad-hoc signing (only needed for bridged networking).
- USB passthrough requires **both** `com.apple.developer.accessory-access.usb` AND `com.apple.security.device.usb` per [Apple Developer Forums](https://developer.apple.com/forums/thread/831902). The former requires a paid account; the latter is a standard Hardened Runtime entitlement.
- Both restricted entitlements require a provisioning profile from a paid Apple Developer account.
- **Confirmed (2026-06-15, extensively tested):** (also [confirmed by UTM](https://github.com/utmapp/UTM/blob/fb61bfe86a2cc39bb3bc884636fa55414f317acb/Documentation/MacDevelopment.md) — "you need to manually request these entitlements and be approved by Apple")
  - `com.apple.vm.networking` (bridge): Causes immediate SIGKILL with Personal Team. The portal will not include it in auto-generated profiles.
  - `com.apple.developer.accessory-access.usb`: Same SIGKILL. Portal refuses even when requested via Xcode's SystemCapabilities + Signing & Capabilities flow. Structured array format (with `idVendor: *`) makes no difference — the entitlement is simply absent from the generated provisioning profile.
  - Building via SPM workspace with `CODE_SIGN_ENTITLEMENTS=resources/entitlements-dev.plist` works and embeds unrestricted entitlements properly.
  - These are **Apple account tier gated**, not build configuration issues. No local workaround exists.

## Data Layout

```
~/Library/Caches/havm/           Cached downloads (can be deleted)
~/Library/Application Support/havm/vm/
  haos.img                       32 GiB raw GPT disk (APFS sparse)
  config.img                     2 MB FAT16 SSH key import disk (optional)
  NVRAM                          EFI variable store
  MachineIdentifier              Stable machine ID
~/.config/havm/config.yml        Optional overrides
```

## USB Accessories

USB accessory passthrough uses `AAUSBAccessoryManager` (macOS 27). When `havm run`
starts with `ENABLE_USB_ACCESSORY=YES`, it registers a listener and macOS shows
a menu bar item. The user selects which devices to attach — they are persisted
and hot-attached to the running VM via `VZUSBPassthroughDevice`.

**Architecture:**
- `ServiceRuntime.setupUSBDiscovery()` boots `NSApplication.accessory`, registers
  `AAUSBAccessoryListener`. The menu bar item is the user's selection UI.
- On connect: listener persists `AAUSBAccessory` via `NSKeyedArchiver` to
  `~/Library/Application Support/havm/usb/<registryID>.accessory`, then
  hot-attaches via `VZUSBPassthroughDevice` + `usbControllers.first?.attach(device:)`.
- On boot: persisted accessories are loaded and attached during VM configuration.
- The CLI builds as a minimal `Havm.app` bundle so Xcode's provisioning profile
  covers the restricted `accessory-access.usb` entitlement.

**Entitlements:**
- `com.apple.security.device.usb` — standard Hardened Runtime entitlement
- `com.apple.developer.accessory-access.usb` — restricted, requires provisioning profile

**HAVM Connect** (at `havm-connect/`) is a minimal Xcode project whose sole purpose
is to generate a provisioning profile for `ch.ingmar.havm`. Build it once in Xcode,
then `scripts/build.sh` picks up the profile automatically. The app itself does
nothing — it just needs to exist as an Xcode target with the USB entitlement.

## Known Issues

- **macOS 27**: `Data(count: 67108864)` crashes the process. Our CONFIG disk builder uses 2 MB instead of 64 MB to work around this.
- **ACPI shutdown ignored**: HA OS on aarch64 uses PSCI, not ACPI. `VZVirtualMachine.requestStop()` (ACPI power button) is silently ignored. Use SSH-based shutdown instead.
- **`ha host shutdown`**: Only works if the SSH add-on is installed and running on port 22. The debug SSH on port 22222 runs `shutdown -h now` directly as root on the host.
