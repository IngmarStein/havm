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
- **SSH-based graceful shutdown** — on Ctrl+C/SIGTERM, tries SSH `shutdown -h now` (port 22222) then `ha host shutdown` (port 22), with instant force-stop fallback. ACPI `requestStop()` is not used — HA OS on aarch64 uses PSCI and ignores ACPI power button events.
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

## USB Passthrough (parked)

USB passthrough is fully implemented but **gated by Apple**. Cannot be activated without special approval.

**Architecture (ready, waiting on entitlement):**
- `havm-helper` Xcode project at `havm-helper/` — SwiftUI app that discovers USB devices
  via `AAUSBAccessoryManager`, persists selection via `NSKeyedArchiver` to
  `~/Library/Application Support/havm/usb/<registryID>.accessory`
- `USBManager.buildPassthroughConfigurations()` reads persisted `AAUSBAccessory`
  files, creates `VZUSBPassthroughDeviceConfiguration(device:)` objects
- `KnownCoordinators` database (15 devices) provides display hints in UI and `list-usb`
- `CONFIGDiskBuilder` creates minimal FAT16 disk with `authorized_keys` for SSH import
  (separate feature, works without USB entitlement)

**Architecture:**
- `AAUSBAccessory` conforms to `NSSecureCoding` — it's a transferable descriptor
  designed for cross-process persistence (also has XPC transport methods).
- `havm-helper.app` discovers devices via `AAUSBAccessoryManager` (requires Dock app /
  NSApplication) and persists `AAUSBAccessory` objects via `NSKeyedArchiver`.
- The CLI links `AccessoryAccess.framework` for the `AAUSBAccessory` type and
  unarchives the persisted files with `ofClass: AAUSBAccessory.self`. It does NOT
  use `AAUSBAccessoryManager` — only the helper needs NSApplication.
- `VZUSBPassthroughDeviceConfiguration` has exactly one designated initializer:
  `initWithDevice:(AAUSBAccessory *)device`. The persisted `AAUSBAccessory` is
  passed directly to it.

**Blocker:** `com.apple.developer.accessory-access.usb` — Xcode's provisioning system
rejects it: *"not found and could not be included in profile."* Requires explicit
Apple approval. `com.apple.security.device.usb` is also needed (standard Hardened
Runtime entitlement, but insufficient alone).

**To resume work:**
1. Get `com.apple.developer.accessory-access.usb` approved for a developer account
2. Build `havm-helper.app` from the Xcode project at `havm-helper/`
3. Configure it with Personal Team signing + "Accessory Access" capability
4. Select devices in havm-helper → persisted to `~/Library/Application Support/havm/usb/`
5. `havm run` reads them and attaches passthrough configs to the VM

## Known Issues

- **macOS 27**: `Data(count: 67108864)` crashes the process. Our CONFIG disk builder uses 2 MB instead of 64 MB to work around this.
- **ACPI shutdown ignored**: HA OS on aarch64 uses PSCI, not ACPI. `VZVirtualMachine.requestStop()` (ACPI power button) is silently ignored. Use SSH-based shutdown instead.
- **`ha host shutdown`**: Only works if the SSH add-on is installed and running on port 22. The debug SSH on port 22222 runs `shutdown -h now` directly as root on the host.
