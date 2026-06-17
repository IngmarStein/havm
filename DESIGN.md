# havm — Design

**Zero-config Home Assistant OS VM runner for Apple Silicon.**
macOS 27 (Golden Gate) minimum. Swift 6.4.

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Havm (CLI, AsyncParsableCommand)               │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐         │
│  │ run      │ │ list-usb │ │ version  │         │
│  │ (async)  │ │          │ │          │         │
│  └────┬─────┘ └────┬─────┘ └────┬─────┘         │
├───────┼────────────┼────────────┼───────────────┤
│       ▼            ▼            ▼               │
│  ┌──────────────────────────────────────────┐   │
│  │  HavmCore                                │   │
│  │  ┌────────┐ ┌────────────┐ ┌──────────┐ │   │
│  │  │ Config │ │ HAOSSetup  │ │ VMControl │ │   │
│  │  │(YAML)  │ │Download/XZ │ │ ler (VZ)  │ │   │
│  │  │        │ │Decompress  │ │           │ │   │
│  │  └────────┘ └────────────┘ └──────────┘ │   │
│  │  ┌───────────────────────┐               │   │
│  │  │ CONFIGDiskBuilder     │               │   │
│  │  │ (MBR + FAT16 LFN)     │               │   │
│  │  └───────────────────────┘               │   │
│  │  ┌──────────────┐ ┌──────────────────┐  │   │
│  │  │ KnownCoordi- │ │ USBManager       │  │   │
│  │  │ nators (DB)  │ │ (persisted acc)  │  │   │
│  │  └──────────────┘ └──────────────────┘  │   │
│  │  ┌──────────────────────────────────┐   │   │
│  │  │ JSONLogHandler (NDJSON to        │   │   │
│  │  │ stdout or file)                  │   │   │
│  │  └──────────────────────────────────┘   │   │
│  └──────────────────────────────────────────┘   │
├───────┬─────────────────────────────────────────┤
│       ▼                                          │
│  ┌──────────────────────────────────────────┐   │
│  │  HavmRuntime                             │   │
│  │  ┌──────────────────────────────────┐    │   │
│  │  │ ServiceRuntime                   │    │   │
│  │  │ SIGTERM/SIGINT → SSH shutdown    │    │   │
│  │  │ (port 22222, then port 22)       │    │   │
│  │  │ → waitForStop → forceStop        │    │   │
│  │  └──────────────────────────────────┘    │   │
│  └──────────────────────────────────────────┘   │
└─────────────────────────────────────────────────┘
```

## `havm run` Flow

1. Load config (optional, defaults if absent)
2. `HAOSSetupManager.setupIfNeeded()`:
   a. Fetch latest release from GitHub (stable or pre-release channel)
   b. Download `haos_generic-aarch64-<version>.img.xz` if not cached (streaming)
   c. Verify SHA256 checksum if available
   d. Decompress with `liblzma` via `CXZ` (no external tools)
   e. Copy disk image to persistent location
   f. Resize disk image to configured size via APFS sparse (ftruncate)
3. `VMController.createConfiguration()`:
   - `VZEFIBootLoader` with persisted EFI variable store
   - `VZVirtioBlockDeviceConfiguration` with persistent disk
   - Optional CONFIG disk as USB mass storage (XHCI) for SSH key import
   - `VZNATNetworkDeviceAttachment` (default) or `VZBridgedNetworkDeviceAttachment`
   - Stable MAC address derived from persisted `VZGenericMachineIdentifier`
   - No graphics (headless)
4. `vm.start()` → `ServiceRuntime.runBlocking()`
5. Block until SIGTERM/SIGINT or VM exit

## Signal Handling

```
SIGTERM / SIGINT
  → ServiceRuntime.signalShutdown()
    → SSH root@<ip> -p 22222 shutdown -h now    # Debug SSH (host, direct)
    → waitForStop(timeout)
    → SSH root@<ip> -p 22 ha host shutdown       # SSH add-on (container)
    → waitForStop(timeout)
    → vm.forceStop()                              # Fallback: immediate stop
  → Second signal → _exit(1)
```

ACPI power button (`vm.requestStop()`) is **not used**. HA OS on aarch64 uses
PSCI for power management and ignores ACPI events entirely. SSH-based shutdown
is the only reliable method.

## Data Layout

```
~/.config/havm/config.yml                           # Optional config
~/Library/Application Support/havm/
  vm/haos.img                                       # Persistent disk (raw, GPT, VirtIO)
  vm/NVRAM                                          # EFI variable store (boot state)
  vm/MachineIdentifier                              # Stable machine ID (consistent MAC)
  vm/config.img                                     # SSH key import disk (CONFIG label)
  vm/havm.pid                                       # Process PID for external tooling
  usb/                                              # Persisted USB accessory data (havm-helper)
~/Library/Caches/havm/
  haos_generic-aarch64-<version>.img.xz             # Cached download
  haos_generic-aarch64-<version>.img                # Decompressed cache
```

## VM Hardware Decisions

| Component | Choice | Rationale |
|-----------|--------|-----------|
| Boot | UEFI (`VZEFIBootLoader`) | Boots directly from GPT disk — no kernel extraction |
| Storage | VirtIO block, raw image | HA OS ships VirtIO drivers; APFS sparse for efficiency |
| Network | NAT (default) or Bridge | NAT works without extra entitlements; bridge gets LAN IP |
| Machine ID | Persisted `VZGenericMachineIdentifier` | Stable MAC across reboots |
| NVRAM | Persisted EFI variable store | GRUB boot state survives reboots |
| Graphics | None (headless) | Minimizes overhead, not needed for HA OS |
| USB | XHCI controller + mass storage | CONFIG disk via USB (HA OS imports SSH keys from USB) |
| CONFIG disk | MBR + FAT16 with VFAT LFN | 2 MB image with "CONFIG" label — HA OS auto-imports |

## Homebrew Service

```ruby
service do
  run [opt_bin/"havm", "run"]
  keep_alive true
  run_type :immediate
end
```

`havm run` never daemonizes — it blocks in the foreground, exactly what launchd expects from a `KeepAlive` / `run_type :immediate` job.

## Key Dependencies

| Package | Use |
|---------|-----|
| `Virtualization.framework` | VZVirtualMachine, VZEFIBootLoader, VZUSBDeviceConfiguration |
| `swift-argument-parser` | CLI |
| `Yams` | YAML config parsing |
| `swift-log` | Structured logging |
| `CryptoKit` | SHA256 checksum verification |
