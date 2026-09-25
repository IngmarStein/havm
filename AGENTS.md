# CLAUDE.md

## Project

`havm` — Zero-config CLI for running Home Assistant OS on Apple Silicon using the native Virtualization framework. macOS 15 minimum (USB accessory passthrough requires macOS 27). Swift 6.4, built with Xcode 27+ — see Build & Test.

## Build & Test

```bash
./scripts/build.sh release    # Release build: -O + strip → ~2.1 MB binary
swift test                    # Unit tests (HavmCoreTests)
./.build/release/havm run     # Run the VM (blocks; Ctrl+C to stop)
./.build/release/havm run --console  # Interactive serial console (hvc0)
```

Binary size is reduced via `strip` (removes ~2.4 MB of symbol tables from LINKEDIT)
before codesigning. Default `-O` is kept — `-Osize` only saves ~300 KB more.

Building needs Xcode 27+ for the Swift 6.4 toolchain and the macOS 27 SDK. The
deployment target is macOS 15 and the macOS 27 APIs are weakly linked, so the
binary still runs on macOS 15 even though the host (and GitHub's `xcode-27`
image, itself macOS 27/arm64) does not. `scripts/select-xcode.sh` picks the
toolchain by the version each bundle reports — `$DEVELOPER_DIR` if it qualifies,
else the newest stable install, else the newest beta — and both workflows plus
`publish.sh` use it.

## Release Process

1. Bump `HavmVersion.current` in `Sources/Havm/main.swift` (CI also auto-bumps from tag).
2. Dry-run on a branch to exercise signing and notarization without publishing:
   `gh workflow run release.yml --ref <branch>` — a dispatch never creates a
   release, it uploads `havm.zip` as an artifact instead.
3. Tag: `git tag -a v0.1.4 -m "v0.1.4" && git push --tags`
4. CI picks up the `v*` tag, builds + notarizes, publishes a GitHub release with
   `gh release create --generate-notes`. The auto-generated notes are a starting
   point — edit the release on GitHub to add a curated changelog. To retry a
   failed tag run, re-run it from the Actions UI (keeps the original push event).

The release job runs on GitHub's `xcode-27` image, where the runner is
ephemeral and carries no signing credentials, so every credential arrives as a
secret in that run:

| Secret | Contents |
|---|---|
| `DEVELOPER_ID_CERT` | base64 of the Developer ID Application `.p12` |
| `DEVELOPER_ID_PASSWORD` | that `.p12`'s password |
| `PROVISIONING_PROFILE` | base64 of the `HAVM Developer ID` profile |
| `NOTARY_KEY` | App Store Connect API key (`.p8`) |

Plus the `DEVELOPMENT_TEAM`, `DEVELOPER_ID`, `NOTARY_KEY_ID`, and `NOTARY_ISSUER`
variables. `PROVISIONING_PROFILE` is load-bearing: without the embedded profile
the restricted entitlements (`accessory-access.usb`, `vm.networking`) still sign
but are ignored at runtime, so the release loses USB passthrough and bridge
networking silently. A "Verify signature" step fails the job if the profile or
any entitlement is missing — do not remove it. The `.p12` is imported into a
throwaway keychain, since the image's login keychain password is unknown and
`set-key-partition-list` needs the *keychain* password, not the `.p12`'s.

## Architecture

```
Havm (CLI, AsyncParsableCommand)
├── RunCommand       → HAOSSetup → VMController → ServiceRuntime
├── CleanupCommand   → FileManager
├── ImportUTMCommand → UTMImport
└── VersionCommand

HavmCore
├── Config           YAML config, paths, parsing (Yams)
├── HAOSSetup        GitHub release fetch, download .img.xz, xz decompress (CXZ/libzma),
│                    copy+resize disk, SSH CONFIG disk
├── VMController     VZEFIBootLoader + VZEFIVariableStore, storage, network, USB,
│                    machine identifier persistence, console mode
│                    (VZVirtioConsoleDeviceSerialPortConfiguration,
│                    VZFileHandleSerialPortAttachment),
│                    @MainActor on start()
├── ServiceRuntime   SIGTERM/SIGINT → SSH shutdown (port 22222/22) →
│                    force-stop fallback, DHCP lease guest IP detection,
│                    console mode: raw terminal, skip SIGINT, restore on exit,
│                    AAUSBAccessoryListener + VZUSBPassthroughDevice for USB
├── CONFIGDiskBuilder MBR + FAT16 with VFAT LFN, volume label "CONFIG",
│                    authorized_keys file — HA OS auto-imports for SSH
├── Metrics           Prometheus metrics: MetricsServer (NWListener HTTP),
│                    bootstrap, process gauges
└── Config/MemorySize Human-readable sizes ("4 GiB" → bytes)

CXZ (C target)
└── xz_decompress    Statically links liblzma (-llzma) for XZ decompression (no external tools)
```

## Key Design Decisions

- **VZEFIBootLoader** — boots directly from GPT disk via UEFI. No kernel extraction, no kernel command line, no initrd. Just point at the disk image.
- **Bridge networking by default** — LAN-reachable IP for Home Assistant discovery. Falls back to NAT at runtime if the binary lacks the `com.apple.vm.networking` entitlement (e.g. self-compiled). Explicit `network.type: nat` available for manual override.
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
  All four share a **single deadline** (`shutdown.timeout_seconds`, default 90) rather
  than each getting a fresh timeout: the request attempts are capped inside it (10 s REST,
  5 s SSH connect) and the wait for `.stopped` consumes the rest. Restarting the budget per
  method used to force-stop a guest that was still halting cleanly after an accepted
  shutdown request (issue #11), and grew the total to `min(budget, 10) + 3 x budget`.
  Budget + force-stop + cleanup must stay under the Homebrew formula's
  `stop_timeout 120` (launchd `ExitTimeOut`), or launchd `SIGKILL`s havm mid-shutdown —
  and with `KeepAlive true` restarts it, booting a guest whose disk was yanked mid-halt.
  ACPI `requestStop()` is not used — HA OS on aarch64 uses PSCI and ignores ACPI power button events.
- **Guest addressed by name, not by a resolved address** — readiness checks, SSH shutdown,
  and HA API calls all target `network.hostname` (bridge-mode default `homeassistant.local`)
  and let the resolver try a name's addresses at connect time. Resolving once and committing
  to the first result pins a stale address when mDNS serves records from an earlier DHCP lease
  (issue #10). NAT mode has no name and parses `/var/db/dhcpd_leases` by MAC address instead
  (no ping/ARP scanning).
- **VFAT LFN** — the `0x40` (LAST_LONG_ENTRY) flag must be on the highest sequence number (end of filename), not the lowest (beginning). Getting this wrong causes both macOS and Linux to truncate the filename.
- **`--console` interactive mode** — `VZVirtioConsoleDeviceSerialPortConfiguration` with
  `VZFileHandleSerialPortAttachment(stdin, stdout)` maps the host terminal to the guest's
  `/dev/hvc0` virtio console. Terminal is set to raw mode (`cfmakeraw` + `ONLCR` for CR-LF
  translation) after VM start, restored on all exit paths. SIGINT is not intercepted — raw
  mode's cleared ISIG means Ctrl+C passes `0x03` to the guest. Shutdown via `poweroff` in
  guest, or SIGTERM from outside. Forces text log format (stderr) to keep stdout clean.
  Primarily a debugging tool, not a headline feature.

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

USB accessory passthrough uses `AAUSBAccessoryManager` (macOS 27 only). When `havm run`
starts with `ENABLE_USB_ACCESSORY=YES` on macOS 27+, it registers a listener and macOS shows
a menu bar item. On macOS 15–26, USB discovery is skipped with a log message. The user
selects which devices to attach — they are hot-attached to the running VM via
`VZUSBPassthroughDevice`.

**Architecture:**
- All AccessoryAccess/`VZUSBPassthroughDevice` code lives in `USBAccessorySupport.swift`
  (`USBAccessoryCoordinator`), annotated `@available(macOS 27.0, *)`; AccessoryAccess is
  imported `@_weakLinked` so the binary runs on macOS 15+.
- `ServiceRuntime.setupUSBDiscovery()` gates on `#available(macOS 27.0, *)`, then
  `USBAccessoryCoordinator.start()` boots `NSApplication.accessory` and registers
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

## Secure Boot

havm offers no Secure Boot option, and the blocker is Home Assistant OS, not the
framework.

macOS 27 has the API. Secure Boot state lives *inside* the EFI variable store —
`VZEFIBootLoader` has no secure-boot property at all — so it is the NVRAM file
havm already owns: `enrollDefaultSecureBootSignatures()` plus
`enableSecureBootUsingDefaultPlatformKey()` enables it, a caller-supplied
`SecCertificate` goes through `enableSecureBoot(platformKey:)` and the
`VZEFISignature*` classes, and `disableSecureBoot()` / `resetSecureBoot()` back
out. It is all `macOS 27.0+`, so it would sit behind `#available` much like the
AccessoryAccess code. UTM drives these methods from a macOS 12 deployment target
(`utmapp/UTM#7886`, which closed `#7874`), so havm's macOS 15 target is no
obstacle for the `VZEFIVariableStore` methods; whether the newer
`VZEFISignature*` classes weak-link from an old target is unproven.

What stops it: Apple's default enrollment trusts Microsoft's UEFI CA, and HAOS
boots an unsigned, Buildroot-built GRUB2. In `home-assistant/operating-system`
the aarch64 defconfig enables only `BR2_TARGET_GRUB2` and
`BR2_TARGET_GRUB2_INSTALL_TOOLS`, with no secure-boot or signing option, and
`buildroot-external/package/` contains no shim, mokutil, sbsigntools or
efitools — so the firmware would refuse `bootaa64.efi` and the guest would stop
booting. UTM shipped the option default **off** for that reason, its manual test
recording that "a disk whose only loader is not Microsoft-signed is refused by
the firmware".

The framework enrolls signatures, it never produces them: Virtualization has no
signing API, and macOS ships no `sbsign`/`pesign` equivalent, so a custom
platform key would mean signing HAOS's bootloader out of band. Enrolling the
SHA-256 hash of `bootaa64.efi` into db needs no key, but HAOS's A/B OTA updates
replace the bootloader, so the enrolled hash goes stale and the guest stops
booting on the next OS update.

Enabling rewrites the existing variable store, so it applies retroactively to an
installed guest, and `resetSecureBoot()` is the only documented way back. It
would also buy little here: the disk image is a file in the user's own account,
and the host stays the trust boundary.

Revisit if HAOS ships a Microsoft-signed boot chain — shim plus a signed GRUB.

## Known Issues

- **macOS 27**: `Data(count: 67108864)` crashes the process. Our CONFIG disk builder uses 2 MB instead of 64 MB to work around this.
- **ACPI shutdown ignored**: HA OS on aarch64 uses PSCI, not ACPI. `VZVirtualMachine.requestStop()` (ACPI power button) is silently ignored. Use SSH-based shutdown instead.
- **`ha host shutdown`**: Only works if the SSH add-on is installed and running on port 22. The debug SSH on port 22222 runs `shutdown -h now` directly as root on the host.
