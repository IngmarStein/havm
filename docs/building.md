---
layout: default
title: Building from Source
---

<div class="doc-page">

<div class="doc-nav">
  <a href="/">← Home</a>
  <a href="getting-started.html">Getting Started</a>
  <a href="commands.html">Commands</a>
  <a href="configuration.html">Configuration</a>
  <a href="ssh-shutdown.html">SSH & Shutdown</a>
  <a href="usb-accessories.html">USB Accessories</a>
  <a href="metrics.html">Metrics</a>
</div>

# Building from Source

## Prerequisites

- macOS 27+ with Apple Silicon
- Xcode 27+ (for the toolchain and provisioning profile)
- Swift 6.4

## Quick Build

```bash
git clone https://github.com/IngmarStein/havm.git
cd havm

# Create build configuration
cp resources/build.xcconfig.example resources/build.xcconfig

# Edit build.xcconfig:
#   DEVELOPMENT_TEAM = <your team ID>
#   ENTITLEMENTS_TIER = 1  (or 2/3 if you have a paid account)

# Build
./scripts/build.sh release
.build/release/havm version
```

The release build is optimized with `-O` and stripped — the binary is
about 2.1 MB. `-Osize` only saves ~300 KB more, so the default `-O` is kept.

## Entitlement Tiers

Three tiers control which features are available, based on your Apple
Developer account type:

| Tier | Account | USB | Bridge | File |
|------|---------|-----|--------|------|
| 1 | Free | No | No | `entitlements-tier1.plist` |
| 2 | Paid | Yes | No | `entitlements-tier2.plist` |
| 3 | Paid + Apple approval | Yes | Yes | `entitlements.plist` |

Set `ENTITLEMENTS_TIER` and `DEVELOPMENT_TEAM` in `resources/build.xcconfig`.

### Tier 1 (Free)

NAT networking, no USB passthrough, no bridge. Core VM functionality
works fully — this is all most users need.

### Tier 2 (Paid Developer)

Adds USB accessory passthrough. Requires building `havm.xcodeproj` once
in Xcode to generate a provisioning profile for the restricted
`com.apple.developer.accessory-access.usb` entitlement:

```bash
open havm.xcodeproj
# Build once (⌘B), then close Xcode
./scripts/build.sh release
```

### Tier 3 (Paid + Apple Approval)

Adds bridge networking via `com.apple.vm.networking`. This entitlement
requires explicit approval from Apple.

## Running Tests

```bash
swift test
```

Tests are in `Tests/HavmCoreTests/` — about 10 tests covering the core
library. They run in a few seconds.

## Build Script

`scripts/build.sh release` does the following:

1. Resolves the provisioning profile for Tier 2/3 if available
2. Builds with `swift build -c release`
3. Strips symbol tables from the binary (`strip`)
4. Re-signs with entitlements

The binary lands at `.build/release/havm`.

## Architecture

For a detailed architecture overview and key design decisions, see
[CLAUDE.md](https://github.com/IngmarStein/havm/blob/main/CLAUDE.md).

| Module | Role |
|--------|------|
| `Havm` | CLI entry point (Swift Argument Parser) |
| `HavmCore` | Config parsing, HA OS download/setup, VM controller, CONFIG disk builder, metrics |
| `HavmRuntime` | Graceful shutdown chain, DHCP lease parsing, USB accessory listener |
| `CXZ` | C target — XZ decompression via `dlopen`'d `liblzma` |

</div>
