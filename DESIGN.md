# havm — Design

**Zero-config Home Assistant OS VM runner for Apple Silicon.**
macOS 27 (Golden Gate) minimum. Swift 6.4.

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Havm (CLI, AsyncParsableCommand)               │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐         │
│  │ run      │ │ setup    │ │ list-usb │         │
│  │ (async)  │ │ (async)  │ │          │         │
│  └────┬─────┘ └────┬─────┘ └────┬─────┘         │
├───────┼────────────┼────────────┼───────────────┤
│       ▼            ▼            ▼               │
│  ┌──────────────────────────────────────────┐   │
│  │  HavmCore                                │   │
│  │  ┌────────┐ ┌────────────┐ ┌──────────┐ │   │
│  │  │ Config │ │ HAOSSetup  │ │ VMControl │ │   │
│  │  │(YAML)  │ │Download/   │ │ ler (VZ)  │ │   │
│  │  │        │ │Extract/Disk│ │           │ │   │
│  │  └────────┘ └────────────┘ └──────────┘ │   │
│  │  ┌──────────────┐ ┌──────────────────┐  │   │
│  │  │ KnownCoordi- │ │ USBManager       │  │   │
│  │  │ nators (DB)  │ │ (IOKit, VZUSB)   │  │   │
│  │  └──────────────┘ └──────────────────┘  │   │
│  └──────────────────────────────────────────┘   │
├───────┬─────────────────────────────────────────┤
│       ▼                                          │
│  ┌──────────────────────────────────────────┐   │
│  │  HavmRuntime                             │   │
│  │  ┌──────────────────────────────────┐    │   │
│  │  │ ServiceRuntime                   │    │   │
│  │  │ SIGTERM/SIGINT → ACPI → timeout  │    │   │
│  │  │ → forceStop                      │    │   │
│  │  └──────────────────────────────────┘    │   │
│  └──────────────────────────────────────────┘   │
└─────────────────────────────────────────────────┘
```

## `havm run` Flow

1. Load config (optional, defaults if absent)
2. `HAOSSetupManager.setupIfNeeded()`:
   a. Fetch latest release from GitHub (stable or pre-release channel)
   b. Download `haos_generic-aarch64-<version>.img.xz` if not cached
   c. Decompress with `/usr/bin/xz`
   d. `hdiutil attach` → auto-mount FAT32 EFI partition
   e. Extract `Image` (kernel) and `uInitrd` (initrd)
   f. Copy disk image to persistent location
   g. Resize disk image to configured size via `truncate`
3. `VMController.createConfiguration()`:
   - `VZLinuxBootLoader` with kernel + initrd + command line
   - `VZVirtioBlockDeviceConfiguration` with persistent disk
   - `VZBridgedNetworkDeviceAttachment` (auto-detect primary interface) or NAT
   - `VZVirtioEntropyDeviceConfiguration`
   - No graphics (headless)
4. `vm.start()` → `ServiceRuntime.runBlocking()`
5. Block until SIGTERM/SIGINT or VM exit

## Signal Handling

```
SIGTERM / SIGINT
  → ServiceRuntime.handleShutdownSignal()
    → vm.requestStop()           # ACPI shutdown
    → poll state (up to timeout)
      → VM stopped → exit 0
      → timeout → vm.forceStop() → exit 1
  → Second signal → immediate forceStop()
```

## Data Layout

```
~/.config/havm/config.yml                           # Optional config
~/Library/Application Support/havm/
  vm/haos.img                                       # Persistent disk (raw, VirtIO)
  vm/Image                                          # Extracted kernel
  vm/uInitrd                                        # Extracted initrd
  vm/MachineIdentifier                              # Stable machine ID
~/Library/Caches/havm/
  haos_generic-aarch64-<version>.img.xz             # Cached downloads
```

## VM Hardware Decisions

| Component | Choice | Rationale |
|-----------|--------|-----------|
| Storage | VirtIO block, raw image | HA OS ships VirtIO drivers; NVMe would need kernel config audit |
| Network | Bridged, primary interface | LAN-reachable IP needed for HomeKit/Matter/web UI |
| Machine ID | Persisted `VZGenericMachineIdentifier` | Stable MAC across reboots |
| Graphics | None (headless) | Minimizes overhead, not needed for HA OS |
| USB | XHCI + VZUSBPassthroughDevice | macOS 27 AccessoryAccess framework |
| Entropy | VirtIO entropy device | Standard for Linux guests |

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
| `Virtualization.framework` | VZVirtualMachine, VZLinuxBootLoader, VZUSBPassThroughDevice |
| `swift-argument-parser` | CLI |
| `Yams` | YAML config parsing |
| `swift-log` | Structured logging |
