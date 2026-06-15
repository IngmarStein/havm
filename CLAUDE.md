# CLAUDE.md

## Project

`havm` — Zero-config CLI for running Home Assistant OS on Apple Silicon using the native Virtualization framework. macOS 27 minimum. Swift 6.4.

## Build & Test

```bash
./scripts/build.sh release    # Build + ad-hoc sign with dev entitlements
swift test                    # 5 tests in HavmCoreTests
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
├── CONFIGDiskBuilder Minimal FAT16 image with volume label "CONFIG"
└── Config/MemorySize Human-readable sizes ("4 GiB" → bytes)

HavmRuntime
└── ServiceRuntime   SIGTERM/SIGINT → ACPI shutdown → force-stop timeout,
                     print boot instructions

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
- **SSH key import** — creates a 2 MB FAT16 disk with volume label "CONFIG" and `authorized_keys`. HA OS auto-imports on boot for root SSH on port 22222.

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
- `USBManager.buildPassthroughConfigurations()` reads persisted files, creates
  `VZUSBPassthroughDeviceConfiguration` objects
- `KnownCoordinators` database (15 devices) provides display hints in UI and `list-usb`
- `CONFIGDiskBuilder` creates minimal FAT16 disk with `authorized_keys` for SSH import
  (separate feature, works without USB entitlement)

**Blocker:** `com.apple.developer.accessory-access.usb` — Xcode's provisioning system
rejects it: *"not found and could not be included in profile."* Requires explicit
Apple approval. `com.apple.security.device.usb` is also needed (standard Hardened
Runtime entitlement, but insufficient alone).

**Also required:** `AAUSBAccessoryManager` demands a Dock application (NSApplication).
The helper `havm-helper.app` satisfies this. The CLI alone cannot use the framework.

**To resume work:**
1. Get `com.apple.developer.accessory-access.usb` approved for a developer account
2. Build `havm-helper.app` from the Xcode project at `havm-helper/`
3. Configure it with Personal Team signing + "Accessory Access" capability
4. The CLI (`USBManager`) already reads persisted accessory files — no changes needed

## Known Issues

- **macOS 27 beta**: `Data(count: 67108864)` crashes the process. Our CONFIG disk builder uses 2 MB instead of 64 MB to work around this.
