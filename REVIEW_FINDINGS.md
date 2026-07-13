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

| # | Status | Finding | File |
|---|---|---|---|
| 13 | ✅ | **YAML parsed twice.** `Yams.compose()` builds full node tree for emptiness check, then `YAMLDecoder().decode()` does it again. Removed the redundant `compose()` guard — the `trimmed.isEmpty` check above already catches empty/whitespace-only files. | `Config.swift:410-415` |
| 14 | ✅ | **Boot polling uses recursive `asyncAfter` instead of reusable timer.** Creates a new scheduled work item every 250ms. Replaced with `DispatchSourceTimer` (`.strict` semantics) that reuses a single timer source. | `ServiceRuntime.swift:165-186` |
| 15 | ✅ | **Boot polls create overlapping network tasks without cancellation.** Each 250ms tick spawns an unstructured `Task` even if the previous one hasn't completed (5s timeout). Tracked and cancelled in-flight `observerTask`/`webUITask` before starting new ones. | `ServiceRuntime.swift:624,651` |
| 16 | ✅ | **MAC address string re-parsed to bytes every 250ms.** DHCP lease polling splits and hex-parses the MAC on every tick. Parsed once via `lazy var guestMACBytes` and cached. | `ServiceRuntime.swift:754` |
| 17 | ✅ | **`ensureDiskSize` uses seek+write+synchronize instead of `truncate(atOffset:)`.** APFS already handles sparse regions — `truncate(atOffset:)` extends the file with sparse zero blocks directly, no data written. | `HAOSSetup.swift:436` |
| 18 | ✅ | **XZ memory limit is `UINT64_MAX`.** Restricted to 128 MB (`DECODER_MEMLIMIT`) for safety against malformed/crafted XZ files. | `xz_decompress.c:105` |
| 19 | ✅ | **XZ buffer sizes are 256 KB.** Increased to 1 MB for 4× fewer `fread`/`fwrite` syscalls on SSD. Added `setvbuf(in/out, NULL, _IONBF, 0)` to disable stdio double-buffering since we manage our own buffers. | `xz_decompress.c:72-73` |
| 20 | ✅ | **HTTP request line parsing: `split().first.map(String.init)` allocates intermediate array.** Replaced with index-based scan for `\r\n` — finds the first CRLF without allocating an array of Substrings. | `Metrics.swift:229` |
| 21 | ✅ | **HTTP response built via String concatenation then re-encoded to UTF-8 Data.** Build directly as `Data` with successive `append(contentsOf:)` calls, avoiding the String intermediate allocation and double-encode. | `Metrics.swift:253-269` |

---

## 🟡 Medium Priority — Modernization

| # | Status | Finding | File(s) |
|---|---|---|---|
| 22 | ✅ | **Replace `NSString` path bridging with `URL` APIs.** 8+ sites used `(path as NSString).appendingPathComponent(...)`. Converted to `URL(fileURLWithPath:).appendingPathComponent().path`. `expandingTildeInPath` kept as `NSString(string:)` since there's no URL-native equivalent. | `HAOSSetup.swift`, `ServiceRuntime.swift`, `ImportUTMCommand.swift`, `VMController.swift` |
| 23 | ✅ | **Migrate tests from XCTest to Swift Testing.** `@Suite struct`, `#expect()`, parameterized `@Test(arguments:)` for memory size parsing (5 cases). Removed `print()` debug output from tests. Requires explicit `import Foundation` since Swift Testing doesn't transitively import it like XCTest did. | `Tests/HavmCoreTests/ConfigTests.swift` |
| 24 | ✅ | **Add typed throws.** `UTMImport.init` now `throws(UTMImportError)`. Wrapped `Data(contentsOf:)` call to convert Foundation errors. `VMController.createConfiguration()` and `HAOSSetup.setupIfNeeded()` call Foundation APIs that throw generic `Error` — typed throws would require broader restructuring; deferred. | `UTMImport.swift` |
| 25 | ✅ | **Replace `NSLock` with `Mutex` from Synchronization module.** `SimpleRegistry` now wraps values in `Mutex<>`, uses `withLock` for borrowing-based exclusive access. Class is now plain `Sendable` (no `@unchecked` needed — `Mutex` provides thread safety). | `Metrics.swift` |
| 26 | ❌ | **`NSISO8601DateFormatter` → `DateFormatter`.** Rejected — `ISO8601DateFormatter` is the correct API: thread-safe, handles ISO 8601 variants properly. A custom `DateFormatter` would be thread-unsafe and fragile. | — |

---

## 🟡 Medium Priority — CI/CD & Build

| # | Status | Finding | File(s) |
|---|---|---|---|
| 27 | ✅ | **Notary key file not cleaned up in release CI.** `echo "$NOTARY_KEY" > notary.p8` but never removed — persists on self-hosted runner. Added `trap "rm -f notary.p8" EXIT` to clean up regardless of exit path. | `.github/workflows/release.yml:90` |
| 28 | ⬜ | **Release workflow and publish.sh are partially duplicated.** Skipped — manual publish path intentionally kept for fallback. | `scripts/publish.sh` |
| 29 | ✅ | **`default.profraw` tracked in repo.** Already done — file was already in `.gitignore` and untracked. | — |

---

## 🟡 Medium Priority — Product & Features

| # | Finding |
|---|---|
| 30 | **Add `havm status` command.** Single most impactful missing feature for background service use. Show VM health, guest IP, HA ready state. Non-zero exit if unhealthy. |
| 31 | **Expand Prometheus metrics.** Add guest uptime, HA OS version (from `/api/discovery_info`), guest IP as label. Note: `VZVirtualMachine.statistics` does not exist, so guest CPU/memory metrics are not available. |
| 32 | **Add `havm logs` command.** Tail the running VM's logs without finding the launchd log path. |
| 33 | **Add `havm open` command.** Open HA web UI in default browser. |
| 34 | **Add `havm ip` command.** Print just the guest IP — scriptable. |
| 35 | ✅ | **Add SIGHUP graceful restart.** Added SIGHUP dispatch source alongside SIGTERM/SIGINT. Triggers the full graceful shutdown chain. launchd/Homebrew `keep_alive` restarts the process. Documented in `docs/configuration.md` and `docs/ssh-shutdown.md`. | `ServiceRuntime.swift` |
| 36 | ✅ | **VM crash notification.** Integrate with `os_log` so crashes appear in Console.app. Optionally `UserNotifications` for local alerts. |
| 37 | ✅ | **`havm backup` command.** APFS snapshots of the disk image (instant, zero-space until diverge) + NVRAM/machine ID copy. |
| 38 | ✅ | **Multi-instance support.** `-d` flag is now documented in `docs/commands.md` with guidance on using separate data directories and unique metrics ports. | `docs/commands.md` |
| 39 | ✅ | **Uninstall experience.** `havm cleanup -a` / `--all` now removes persistent VM data and config with a confirmation prompt. Cache removal is the default. | `CleanupCommand.swift` |
| 40 | ⬜ | **XZ decompression shows no progress.** 300+ MB with no feedback. Pass a progress callback through CXZ. |
| 41 | ✅ | **Config hot-reload documented.** Added "Hot Reload" section to `docs/configuration.md` listing which settings take effect immediately (log level/format, metrics, API token, shutdown timeout) and which require a restart. | `docs/configuration.md` |

---

## 🔵 Lower Priority

| # | Finding | File |
|---|---|---|
| 42 | ❌ | **Eliminate swift-metrics dependency.** Only uses `Gauge`. **Rejected** — the MetricsSystem bootstrap pattern and Recorder protocol abstraction are clean and well-tested. The ~50-100 KB savings on a 2 MB binary aren't compelling, and swift-metrics provides infrastructure for future metric types. | `Metrics.swift` |
| 43 | ✅ | **Replace Yams with lightweight parser.** havm's config is simple flat key-value pairs. Yams is ~300-500 KB. | `Config.swift`, `Package.swift` |
| 44 | ❌ | **Replace `JSONEncoder`/`JSONDecoder` with `JSONSerialization`.** **Rejected** — JSONEncoder/Decoder provides type-safe Codable conformance. The release cache is read/written once per startup, not in a hot path. The 20-30 KB savings aren't worth losing compile-time safety. | `HAOSSetup.swift:244-262` |
| 45 | ✅ | **Deduplicate boot banner strings.** NAT and bridge variants now share header/footer. Saves ~500 bytes. | `ServiceRuntime.swift:126-156` |
| 46 | ✅ | **`filter` + `.first` should be `first(where:)`.** Replaced with `first(where:)` — avoids intermediate array allocation. | `HAOSSetup.swift:310-313` |
| 47 | ✅ | **Add SPM dependency caching to CI.** Added `actions/cache@v4` with Package.resolved hash key. | `.github/workflows/ci.yml` |
| 48 | ✅ | **Extract Xcode selection into composite GitHub Action.** Duplicated identically in ci.yml and release.yml. | `.github/workflows/` |
| 49 | ✅ | **Pin SwiftLint Docker image to version tag** (e.g., `ghcr.io/realm/swiftlint:0.58.2`). | `.github/workflows/ci.yml:24-25` |
| 50 | ✅ | **Build with `ENTITLEMENTS_TIER=3` and ad-hoc signing in CI** to verify tier-3 code compiles. Currently only tier 1 is built. | `.github/workflows/ci.yml:50` |
| 51 | ✅ | **`reloadConfig()` now guarded against running during shutdown.** Added `guard !shutdownRequested else { return }`. | `ServiceRuntime.swift:369` |
| 52 | ✅ | **Force-unwrapped `URL(string:)`** — URL is built from hardcoded constants, cannot fail. Added comment explaining why the unwrap is safe. | `HAOSSetup.swift:179` |
| 53 | ✅ | **`fatalError` in EFI store creation** — improved error message to suggest checking disk space and permissions. | `VMController.swift:182` |
| 54 | ✅ | **No-op poll ticks** — already resolved by DispatchSourceTimer refactor (#14): timer is cancelled and set to nil when both notifications fire. | `ServiceRuntime.swift` |
| 55 | ✅ | **Release cache stores full JSON for two values (etag + tag).** Store as plain text. | `HAOSSetup.swift:244-262` |
| 56 | ❌ | **Orphaned cached disk images** — N/A: fresh images are never downloaded after initial setup. The cached image stays the same unless the user explicitly clears the cache. | `HAOSSetup.swift:106-122` |
| 57 | ✅ | **`stateDescription` duplicated.** Extracted as shared `VZVirtualMachine.State.description` extension in VMController.swift, used from both VMController and ServiceRuntime. | `VMController.swift`, `ServiceRuntime.swift` |
| 58 | ✅ | **`ensureDiskSize` runs on every boot** — already efficient, only opens FileHandle when resize needed. | `HAOSSetup.swift:427-439` |
| 59 | ✅ | **Observer /ping polling (port 4357) is undocumented** in external docs outside CLAUDE.md. | — |
| 60 | ✅ | **`--data-dir` flag** — already documented in earlier docs update (#38). | — |
| 61 | ✅ | **Stale version numbers in docs** — updated 0.1.4 → 0.2.2 in commands.md and index.md. | `docs/commands.md`, `docs/index.md` |
| 62 | ✅ | **DESIGN.md architecture diagram** — added `cleanup` command box. | `DESIGN.md:11-13` |
| 63 | ✅ | **No troubleshooting guide or FAQ.** Top 5 failure modes should be documented. | — |
| 64 | ✅ | **Comparison with alternatives** — added comparison table to README (havm vs UTM vs Docker vs Raspberry Pi). | `README.md` |
| 65 | ✅ | **Test `print()` calls** — already resolved by Swift Testing migration (#23): `print()` debug output removed. | `Tests/HavmCoreTests/ConfigTests.swift` |
| 66 | ✅ | **Hardcoded byte offsets in CONFIG disk tests** — acceptable; tests are tightly coupled to the disk layout by design. | `Tests/HavmCoreTests/ConfigTests.swift` |
| 67 | ✅ | **`VZVirtualMachine.stop(completionHandler:)`** — current `withCheckedThrowingContinuation` bridge is the correct pattern; no async API exists yet. | `VMController.swift:328-332` |

---

## Architecture Notes (No Action Needed)

- `VZVirtualMachine.start()` requires main queue — `@MainActor` and `DispatchQueue.main.async` usage is correct
- `@unchecked Sendable` on 6 classes is reasonable for a CLI. `VMController` could be fully `@MainActor`
- `@preconcurrency import Virtualization` and `@preconcurrency import AppKit` are necessary until Apple adds Sendable annotations
- `AppKit` loaded at process start even when USB disabled — framework limitation, not fixable
- Swift 6 language mode workarounds (`nonisolated(unsafe)`, `@unchecked Sendable`) are acceptable for CLI tool
- `Combine.framework` pulled in transitively by swift-argument-parser — requires upstream change
- xcodeproj needed solely for provisioning profile generation — no Apple SPM alternative for restricted entitlements
