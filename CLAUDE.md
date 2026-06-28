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
├── CleanupCommand   → FileManager
├── ImportUTMCommand → UTMImport
└── VersionCommand

HavmCore (library)
├── Config           YAML config, paths, parsing (Yams)
├── HAOSSetup        GitHub release fetch, download .img.xz, xz decompress (CXZ/libzma),
│                    copy+resize disk, SSH CONFIG disk
├── VMController     VZEFIBootLoader + VZEFIVariableStore, storage, network, USB,
│                    machine identifier persistence, @MainActor on start()
├── (ServiceRuntime) AAUSBAccessoryListener + VZUSBPassthroughDevice for USB
├── CONFIGDiskBuilder MBR + FAT16 with VFAT LFN, volume label "CONFIG",
│                    authorized_keys file — HA OS auto-imports for SSH
├── Metrics           Prometheus metrics: MetricsServer (NWListener HTTP),
│                    bootstrap, process gauges
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
  1. `POST /api/services/hassio/host_shutdown` on port 8123 (REST API service call, requires `ha.api_token`)
  2. `ssh root@<ip> -p 22222 shutdown -h now` (debug SSH, requires `ssh.authorized_keys`)
  3. `ssh root@<ip> -p 22 ha host shutdown` (SSH add-on)
  4. `vm.stop()` — force-stop fallback
  ACPI `requestStop()` is not used — HA OS on aarch64 uses PSCI and ignores ACPI power button events.
- **Guest IP detection** — parses `/var/db/dhcpd_leases` by MAC address for instant, reliable IP discovery (no ping/ARP scanning).
- **VFAT LFN** — the `0x40` (LAST_LONG_ENTRY) flag must be on the highest sequence number (end of filename), not the lowest (beginning). Getting this wrong causes both macOS and Linux to truncate the filename.

## Entitlements

Three tiers map to account types. Select via `ENTITLEMENTS_TIER` in `build.xcconfig`.

| Tier | File | Account | USB | Bridge |
|------|------|---------|-----|--------|
| 1 | `entitlements-tier1.plist` | Free | No | No |
| 2 | `entitlements-tier2.plist` | Paid | Yes | No |
| 3 | `entitlements.plist` | Paid + Apple approval | Yes | Yes |

All tiers include `com.apple.security.network.server` for metrics HTTP serving.

| Entitlement | Restriction |
|---|---|
| `com.apple.security.virtualization` | Unrestricted |
| `com.apple.security.hypervisor` | Unrestricted |
| `com.apple.security.network.server` | Unrestricted — present in all tiers for metrics HTTP serving |
| `com.apple.security.device.usb` | Unrestricted (Hardened Runtime) |
| `com.apple.developer.accessory-access.usb` | Restricted — provisioning profile required. Works with Personal Team. |
| `com.apple.vm.networking` | Restricted — requires Apple approval. Tier 3 only. |

`havm-profile/entitlements-helper.plist` has `device.usb` + `accessory-access.usb`.
Open `havm.xcodeproj` and build once to generate the provisioning profile
for `ch.ingmar.havm` — the CLI build script picks it up automatically.

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
a menu bar item. The user selects which devices to attach — they are
hot-attached to the running VM via `VZUSBPassthroughDevice`.

**Architecture:**
- `ServiceRuntime.setupUSBDiscovery()` boots `NSApplication.accessory`, registers
  `AAUSBAccessoryListener`. The menu bar item is the user's selection UI.
- On connect: listener hot-attaches via `VZUSBPassthroughDevice` +
  `usbControllers.first?.attach(device:)` with fresh registryIDs.
- On boot: listener registers after VM start, hot-attaches discovery results.
- The CLI builds as a minimal `Havm.app` bundle so Xcode's provisioning profile
  covers the restricted `accessory-access.usb` entitlement.

**Entitlements:**
- `com.apple.security.device.usb` — standard Hardened Runtime entitlement
- `com.apple.developer.accessory-access.usb` — restricted, requires provisioning profile

`havm.xcodeproj` is a minimal command-line tool target whose sole purpose is
to generate a provisioning profile for `ch.ingmar.havm`. Build once (⌘B),
then `scripts/build.sh` picks up the profile automatically.

## Known Issues

- **macOS 27**: `Data(count: 67108864)` crashes the process. Our CONFIG disk builder uses 2 MB instead of 64 MB to work around this.
- **ACPI shutdown ignored**: HA OS on aarch64 uses PSCI, not ACPI. `VZVirtualMachine.requestStop()` (ACPI power button) is silently ignored. Use SSH-based shutdown instead.
- **`ha host shutdown`**: Only works if the SSH add-on is installed and running on port 22. The debug SSH on port 22222 runs `shutdown -h now` directly as root on the host.
