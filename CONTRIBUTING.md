# Contributing to havm

Thanks for your interest in contributing! havm is a zero-config CLI for running
Home Assistant OS on Apple Silicon using the native Virtualization framework.

## Getting Started

### Prerequisites

- **macOS 27 (Golden Gate) or later** with **Apple Silicon**
- **Xcode 27+** (for the toolchain and provisioning profile generation)
- **Swift 6.4** (included with Xcode)
- A **GitHub account** for submitting pull requests

### Clone and Build

```bash
git clone https://github.com/IngmarStein/havm.git
cd havm

# Create build configuration
cp resources/build.xcconfig.example resources/build.xcconfig
# Edit build.xcconfig to set your DEVELOPMENT_TEAM

# Build
./scripts/build.sh release
.build/release/havm version
```

### Run Tests

```bash
swift test
```

Tests live in `Tests/HavmCoreTests/` and cover the core library. The test suite
is fast — around 10 tests that finish in a few seconds.

### Build Configuration

Copy `resources/build.xcconfig.example` to `resources/build.xcconfig` and set:

| Key | Description |
|-----|-------------|
| `DEVELOPMENT_TEAM` | Your Apple Developer team ID (find in [developer.apple.com/account](https://developer.apple.com/account)) |
| `ENTITLEMENTS_TIER` | `1` (free), `2` (paid, USB), or `3` (paid + Apple approval, USB + bridge) |

Free accounts get Tier 1 — NAT networking, no USB passthrough, no bridge
networking. That's enough for core VM work.

### Provisioning Profile (USB Entitlement)

The `com.apple.developer.accessory-access.usb` entitlement is restricted and
requires a provisioning profile. Build `havm.xcodeproj` once in Xcode (⌘B) to
generate the profile — the CLI build script picks it up automatically.

```
open havm.xcodeproj
# Build once (⌘B), then close Xcode — the profile is cached
```

## Architecture

For a detailed architecture overview, see [CLAUDE.md](CLAUDE.md). The short
version:

| Module | Role |
|--------|------|
| `Havm` | CLI entry point (Swift Argument Parser) — `run`, `import-utm`, `cleanup`, `version` |
| `HavmCore` | Core library — config parsing, HA OS download/setup, VM controller, CONFIG disk builder, metrics server |
| `HavmRuntime` | Service runtime — graceful shutdown chain, DHCP lease parsing, USB accessory listener |
| `CXZ` | C target — XZ decompression via `dlopen`'d `liblzma` (no external CLI tools) |

Key design principles:

- **Zero-config by default** — everything works out of the box with sensible defaults
- **Self-contained** — no external dependencies beyond what ships with macOS (no Homebrew at runtime, no Python, no shell scripts)
- **Sparse-aware** — uses APFS sparse files and `clonefile(2)` for efficient disk handling
- **Main actor on VM start** — `VZVirtualMachine.start()` requires the main queue

## Finding Something to Work On

- **Good first issues** — look for issues labeled [`good first issue`][gfi] in the GitHub issue tracker
- **Documentation** — improvements to the README, config examples, or this guide are always welcome
- **Tests** — additional test coverage for edge cases in the core library
- **Metrics** — additional Prometheus gauges for VM or system stats
- **Bug reports** — if you find a bug, please open an issue with:
  - macOS version (`sw_vers`)
  - havm version (`havm version`)
  - Steps to reproduce
  - Relevant log output (run with `-v` for debug logging)

[gfi]: https://github.com/IngmarStein/havm/labels/good%20first%20issue

## Development Workflow

### Branching

- Fork the repository and create a feature branch from `main`
- Use descriptive branch names: `fix/memory-leak`, `feat/virtiofs-support`

### Code Style

- **Swift 6.4** with complete concurrency checking (`SWIFT_STRICT_CONCURRENCY = complete`)
- Follow the existing style: no self-imposed line length limit, but keep lines
  reasonable. The project uses 4-space indentation.
- Prefer `let` over `var`. Use `guard` for early returns.
- Annotate MainActor-isolated state explicitly with `@MainActor`.
- No force-unwraps in production code — use `guard let` or `throws`.
- Log through the project's logging facility rather than `print()`.

### Commit Messages

Follow [conventional commits][cc] — the repo uses them and the changelog
generation benefits from structured messages:

```
feat: add FooBarProvider for Zigbee coordinator passthrough
fix: handle nil EFI variable store on first boot
docs: clarify bridge networking setup in README
chore: update Yams dependency to 5.3
```

[cc]: https://www.conventionalcommits.org

### Before Submitting

- [ ] `swift test` passes
- [ ] `./scripts/build.sh release` succeeds
- [ ] The binary runs: `.build/release/havm version`
- [ ] If adding a feature, consider adding tests
- [ ] If changing behavior, update relevant documentation

## Pull Requests

1. Push your branch and open a pull request against `main`
2. Describe what the change does and why — link to any related issues
3. CI will build and test automatically on each push
4. A maintainer will review your PR — feedback is normal and intended to be collaborative

Keep PRs focused. If you're tackling something large, open an issue first to
discuss the approach before investing significant time.

## License

By contributing, you agree that your contributions will be licensed under the
project's [MIT License](LICENSE).
