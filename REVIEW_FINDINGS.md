# Review Findings — July 2026

Six subagents performed a comprehensive review of the codebase. This file consolidates
all actionable findings, grouped by priority. Corrections applied during review:
- Homebrew formula is at https://github.com/IngmarStein/homebrew-havm (not missing)
- `VZVirtualMachine.statistics` does not exist (CPU/memory guest metrics not available)

**Status legend:** ✅ Fixed &nbsp;|&nbsp; ⬜ Pending

---

## 🔴 Must-Fix Bugs

| # | Status | Finding | File |
|---|---|---|---|
| 1 | ✅ | **USB VID/PID extraction uses wrong byte offsets (+2) and wrong byte order.** USB descriptor layout: idVendor at offset 8-9, idProduct at 10-11, both little-endian. Code reads from offsets 10 and 12 with big-endian byte order. Logs/metrics show completely wrong IDs. | `VMController.swift:378-382` |
| 2 | ✅ | **Health poll timeout is 75s, not the intended 5 minutes.** Comment says `300 × 1s = 5 minutes` but tick interval is `.milliseconds(250)`. Actual: 300 × 250ms = 75s. On first boot, HA OS can take 2-5 minutes to start the web UI — users may never see the "ready" notification. Fix: change `healthPollMax` to `1200`. | `ServiceRuntime.swift:49,181` |

## 🔴 Documentation Bugs (Factually Wrong)

| # | Status | Finding | File |
|---|---|---|---|
| 3 | ✅ | **Fake CLI flags `--cpu-count` and `--memory-size` documented for `havm run`.** These don't exist in `RunCommand.swift` — they are config-file-only settings. | `docs/commands.md:39-40` |
| 4 | ✅ | **"No memory ballooning" claim contradicts code.** Code explicitly configures `VZVirtioTraditionalMemoryBalloonDeviceConfiguration()`. | `docs/configuration.md:74` |
| 5 | ✅ | **`HavmRuntime` listed as a separate module in 3 docs.** It's not a module — `ServiceRuntime` is a class inside `HavmCore`. | `CONTRIBUTING.md:71`, `DESIGN.md:34-44`, `docs/building.md:111` |
| 6 | ✅ | **DESIGN.md architecture box omitted REST API from shutdown chain.** Box only showed SSH; corrected to show REST API → SSH sequence matching code. | `DESIGN.md:34-44` |
| 7 | ✅ | **CXZ linking documented incorrectly everywhere.** CLAUDE.md, CONTRIBUTING.md, docs/building.md said `dlopen liblzma`, but the code uses static linking via `-llzma`. Also fixed `VZVirtioConsoleDevice` → `VZVirtioConsoleDeviceSerialPortConfiguration` name in CLAUDE.md. | `CLAUDE.md` |

---

## 🟠 High Priority

| # | Status | Finding | File |
|---|---|---|---|
| 8 | ✅ | **`DispatchSemaphore` blocks a cooperative thread pool slot permanently.** `runBlocking()` dispatches to main queue then blocks calling thread on a semaphore that's never signaled (all exits via `exit()`). Replaced with `await withCheckedContinuation { _ in }`. | `ServiceRuntime.swift:113` |
| 9 | ✅ | **JSONLogHandler double-allocates on every log line.** Data → String → Data round-trip just to append `\n`. Write Data directly, append newline byte. | `JSONLogHandler.swift:56-59` |
| 10 | ✅ | **`stream.synchronize()` called on every log entry.** Issues `fsync` per log line to stdout (pipe/terminal). Removed — the OS flushes automatically. | `JSONLogHandler.swift:60` |
| 11 | ❌ | **Add cross-module optimization.** Tested `-Xswiftc -cross-module-optimization`. **Rejected:** binary grows from 2.0→2.1 MB (cross-module inlining outweighs dead-strip savings at this scale), build time increases ~10×, and the Xcode 27 beta linker drops protocol conformance descriptors for `Optional: ExpressibleByArgument` in ArgumentParser, requiring a code workaround (non-optional sentinels) that degrades code quality. Not worth it for a VM launcher where I/O and VM startup dominate. | `scripts/build.sh:58` |
| 12 | ✅ | **Data race in `performGracefulShutdown`.** Unstructured `Task` reads `guestIP`, `config`, `vmController.state` while main queue concurrently writes them. Benign in practice but flagged by TSan. Captured values before spawning task. | `ServiceRuntime.swift:401-451` |

---

## 🟡 Medium Priority — Performance

| # | Finding | File |
|---|---|---|
| 13 | **YAML parsed twice.** `Yams.compose()` builds full node tree for emptiness check, then `YAMLDecoder().decode()` does it again. Remove the `compose()` guard — check `trimmed.isEmpty` instead. | `Config.swift:410-415` |
| 14 | **Boot polling uses recursive `asyncAfter` instead of reusable timer.** Creates a new scheduled work item every 250ms. Replace with `DispatchSourceTimer` with `.strict` for consistent ticks. | `ServiceRuntime.swift:165-186` |
| 15 | **Boot polls create overlapping network tasks without cancellation.** Each 250ms tick spawns an unstructured `Task` even if the previous one hasn't completed (5s timeout). Track and cancel in-flight tasks. | `ServiceRuntime.swift:624,651` |
| 16 | **MAC address string re-parsed to bytes every 250ms.** DHCP lease polling splits and hex-parses the MAC on every tick. Parse once and cache as `[UInt8]`. | `ServiceRuntime.swift:754` |
| 17 | **`ensureDiskSize` uses seek+write+synchronize instead of `truncate(atOffset:)`.** APFS already handles sparse regions. `truncate(atOffset:)` extends the file with sparse zero blocks directly. | `HAOSSetup.swift:436` |
| 18 | **XZ memory limit is `UINT64_MAX`.** Restrict to 128 MB for safety against malformed files: `#define DECODER_MEMLIMIT (128ULL * 1024 * 1024)`. | `xz_decompress.c:105` |
| 19 | **XZ buffer sizes are 256 KB.** Increase to 1 MB for 4x fewer `fread`/`fwrite` syscalls on SSD. Also call `setvbuf(in, NULL, _IONBF, 0)` to disable stdio double-buffering. | `xz_decompress.c:72-73` |
| 20 | **HTTP request line parsing: `split().first.map(String.init)` allocates intermediate array.** Use index-based scan for `\r\n` instead. | `Metrics.swift:229` |
| 21 | **HTTP response built via String concatenation then re-encoded to UTF-8 Data.** Build directly as `Data` to avoid double-encoding. | `Metrics.swift:253-269` |

---

## 🟡 Medium Priority — Modernization

| # | Finding | File(s) |
|---|---|---|
| 22 | **Replace `NSString` path bridging with `URL` APIs.** 8+ sites use `(path as NSString).appendingPathComponent(...)`. Use `URL(fileURLWithPath:).appendingPathComponent().path`. | `HAOSSetup.swift`, `ServiceRuntime.swift`, `ImportUTMCommand.swift`, `VMController.swift` |
| 23 | **Migrate tests from XCTest to Swift Testing.** `@Suite`, `#expect()`, parameterized tests with `@Test(arguments:)`. | `Tests/HavmCoreTests/ConfigTests.swift` |
| 24 | **Add typed throws.** `UTMImport.init`, `VMController.createConfiguration()`, `HAOSSetup.setupIfNeeded()` all throw known error types but use bare `throws`. | Multiple |
| 25 | **Replace `NSLock` with `Mutex` from Synchronization module** (new in Swift 6). | `Metrics.swift` (SimpleRegistry) |
| 26 | **`NSISO8601DateFormatter` where plain `DateFormatter` would work.** Replace with format string `"yyyy-MM-dd'T'HH:mm:ss'Z'"` and `timeZone = TimeZone(secondsFromGMT: 0)`. Saves ~5-10 KB. | `JSONLogHandler.swift:18,43` |

---

## 🟡 Medium Priority — CI/CD & Build

| # | Finding | File(s) |
|---|---|---|
| 27 | **Notary key file not cleaned up in release CI.** `echo "$NOTARY_KEY" > notary.p8` but never removed — persists on self-hosted runner. | `.github/workflows/release.yml:90` |
| 28 | **Release workflow and publish.sh are partially duplicated.** Two release paths: CI-triggered (tag push) and manual (publish.sh). Consider deprecating one. | `scripts/publish.sh`, `.github/workflows/release.yml` |
| 29 | **`default.profraw` tracked in repo.** 0-byte coverage data file. Add `*.profraw` to `.gitignore` and `git rm --cached`. | Root directory |

---

## 🟡 Medium Priority — Product & Features

| # | Finding |
|---|---|
| 30 | **Add `havm status` command.** Single most impactful missing feature for background service use. Show VM health, guest IP, HA ready state. Non-zero exit if unhealthy. |
| 31 | **Expand Prometheus metrics.** Add guest uptime, HA OS version (from `/api/discovery_info`), guest IP as label. Note: `VZVirtualMachine.statistics` does not exist, so guest CPU/memory metrics are not available. |
| 32 | **Add `havm logs` command.** Tail the running VM's logs without finding the launchd log path. |
| 33 | **Add `havm open` command.** Open HA web UI in default browser. |
| 34 | **Add `havm ip` command.** Print just the guest IP — scriptable. |
| 35 | **Add SIGHUP graceful restart.** Trigger the shutdown chain + re-launch. |
| 36 | **VM crash notification.** Integrate with `os_log` so crashes appear in Console.app. Optionally `UserNotifications` for local alerts. |
| 37 | **`havm backup` command.** APFS snapshots of the disk image (instant, zero-space until diverge) + NVRAM/machine ID copy. |
| 38 | **Multi-instance support.** `-d` flag exists but undocumented, port/PID conflicts likely. Add `--name` flag that namespaces data directory and metrics port. |
| 39 | **Uninstall experience incomplete.** `havm cleanup` leaves 32+ GB VM data, NVRAM, config. Add `--all`/`--config`/`--dry-run` flags. |
| 40 | **XZ decompression shows no progress.** 300+ MB with no feedback. Pass a progress callback through CXZ. |
| 41 | **Config hot-reload works but is completely undocumented.** Genuinely excellent power-user feature. Document in `docs/configuration.md`. |

---

## 🔵 Lower Priority

| # | Finding | File |
|---|---|---|
| 42 | **Eliminate swift-metrics dependency.** Only uses `Gauge`. Direct implementation saves ~50-100 KB. | `Metrics.swift` |
| 43 | **Replace Yams with lightweight parser.** havm's config is simple flat key-value pairs. Yams is ~300-500 KB. | `Config.swift`, `Package.swift` |
| 44 | **Replace `JSONEncoder`/`JSONDecoder` with `JSONSerialization`** for the two-field release cache. Saves ~20-30 KB. | `HAOSSetup.swift:244-262` |
| 45 | **Deduplicate boot banner strings.** NAT and bridge variants share ~90% identical text. Saves ~500 bytes. | `ServiceRuntime.swift:126-156` |
| 46 | **`filter` + `.first` should be `first(where:)`.** Avoids intermediate array for GitHub release assets. | `HAOSSetup.swift:310-313` |
| 47 | **Add SPM dependency caching to CI.** Cache `.build/checkouts` and `.build/artifacts`. | `.github/workflows/ci.yml` |
| 48 | **Extract Xcode selection into composite GitHub Action.** Duplicated identically in ci.yml and release.yml. | `.github/workflows/` |
| 49 | **Pin SwiftLint Docker image to version tag** (e.g., `ghcr.io/realm/swiftlint:0.58.2`). | `.github/workflows/ci.yml:24-25` |
| 50 | **Build with `ENTITLEMENTS_TIER=3` and ad-hoc signing in CI** to verify tier-3 code compiles. Currently only tier 1 is built. | `.github/workflows/ci.yml:50` |
| 51 | **`reloadConfig()` not guarded against running during shutdown.** Could restart metrics server mid-shutdown. Add `guard !shutdownRequested else { return }`. | `ServiceRuntime.swift:332` |
| 52 | **Force-unwrapped `URL(string:)` on hardcoded GitHub URL.** Extract to throwing expression for robustness. | `HAOSSetup.swift:179` |
| 53 | **`fatalError` in EFI store creation should throw.** User gets cryptic crash on disk-full instead of readable error. | `VMController.swift:182` |
| 54 | **No-op poll ticks continue scheduling every 250ms after timeout.** Negligible but restructure guard to stop scheduling. | `ServiceRuntime.swift:179-183` |
| 55 | **Release cache stores full JSON for two values (etag + tag).** Store as plain text. | `HAOSSetup.swift:244-262` |
| 56 | **Orphaned cached disk images never cleaned up.** Old HA OS version images accumulate (~300 MB XZ + ~6 GB .img per version). Delete decompressed images not matching current release tag. | `HAOSSetup.swift:106-122` |
| 57 | **`stateDescription` duplicated in `VMController` and `ServiceRuntime`.** Identical switch statements. Extract to shared extension on `VZVirtualMachine.State`. | `VMController.swift:310-320`, `ServiceRuntime.swift:826-836` |
| 58 | **`ensureDiskSize` runs on every boot** but is already efficient (only opens FileHandle when resize needed). Acceptable as-is. | `HAOSSetup.swift:427-439` |
| 59 | **Observer /ping polling (port 4357) is undocumented** in external docs outside CLAUDE.md. | — |
| 60 | **`--data-dir` flag undocumented** in README and docs, but exists in both `RunCommand` and `ImportUTMCommand`. | — |
| 61 | **`havm version` example output in docs shows architecture** (`arm64`) that isn't actually printed. | `docs/commands.md:116-118` |
| 62 | **DESIGN.md architecture diagram omits `cleanup` command.** | `DESIGN.md:12-15` |
| 63 | **No troubleshooting guide or FAQ.** Top 5 failure modes should be documented. | — |
| 64 | **No comparison with alternatives** (UTM, Docker, dedicated hardware). | — |
| 65 | **Test `print()` calls clutter test output.** Remove or guard with env var. | `Tests/HavmCoreTests/ConfigTests.swift:140-161` |
| 66 | **Hardcoded byte offsets in CONFIG disk tests** are fragile — extract shared constants. | `Tests/HavmCoreTests/ConfigTests.swift:28-97` |
| 67 | **`VZVirtualMachine.stop(completionHandler:)`** has no async variant. Current `withCheckedThrowingContinuation` bridge is the correct pattern. | `VMController.swift:328-332` |

---

## Architecture Notes (No Action Needed)

- `VZVirtualMachine.start()` requires main queue — `@MainActor` and `DispatchQueue.main.async` usage is correct
- `@unchecked Sendable` on 6 classes is reasonable for a CLI. `VMController` could be fully `@MainActor`
- `@preconcurrency import Virtualization` and `@preconcurrency import AppKit` are necessary until Apple adds Sendable annotations
- `AppKit` loaded at process start even when USB disabled — framework limitation, not fixable
- Swift 6 language mode workarounds (`nonisolated(unsafe)`, `@unchecked Sendable`) are acceptable for CLI tool
- `Combine.framework` pulled in transitively by swift-argument-parser — requires upstream change
- xcodeproj needed solely for provisioning profile generation — no Apple SPM alternative for restricted entitlements
