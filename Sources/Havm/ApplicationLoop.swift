import AppKit
import HavmCore

/// Answers the system's quit request — a logout, a restart, or Cmd+Q — with a
/// graceful guest shutdown.
///
/// The event loop this delegate lives in is what makes the process a *regular*
/// application. Every other kind (`.accessory`, `.prohibited`,
/// `LSBackgroundOnly`) is classified as a UI element or background app, and
/// loginwindow kills those about 0.2 s after a logout begins without ever
/// asking them to quit. A regular app is waited for, and returning
/// `.terminateLater` holds the quit until `ServiceRuntime` reports the guest
/// stopped.
///
/// The cost is the Dock icon: there is no public API to hide one while keeping
/// the app regular, so havm shows it for as long as it runs. That is the price
/// of the guest getting the chance to halt cleanly.
final class HavmApplicationDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    /// `nil` until the runtime exists — while the config loads, the first-run
    /// download runs, and the disk image is prepared there is no guest to stop,
    /// and a quit can end the process at once.
    private var runtime: ServiceRuntime?

    /// Hand the runtime to the delegate so quit requests reach it. Called once
    /// the runtime is built, from the main thread.
    func attach(runtime: ServiceRuntime) {
        self.runtime = runtime
        runtime.terminationHandler = { _ in
            // The shutdown work is finished by the time this runs; all that is
            // left is answering the quit Apple Event, which AppKit requires on
            // the main thread. Replying terminates the process.
            MainActor.assumeIsolated {
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            } as Void
        }
        runtime.guestStatusChanged = { [weak self] status in
            self?.show(status)
        }
        show(runtime.guestStatus)
    }

    /// The Dock tile is the one piece of UI havm has, so it carries the one
    /// piece of status worth showing: a badge while the guest has not answered
    /// yet, and nothing once it has (or once waiting has been given up on).
    private func show(_ status: GuestStatus) {
        MainActor.assumeIsolated {
            let tile = NSApplication.shared.dockTile
            tile.badgeLabel = status == .booting ? "•" : nil
            tile.display()
        } as Void
    }

    // MARK: - Dock menu

    /// Right-clicking the Dock tile offers the one action that is not a
    /// command: opening the guest's web UI. Quit is not repeated here — the
    /// Dock adds its own, and with the formula's `keep_alive true` quitting
    /// just has launchd start havm again.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        // Decided here rather than by AppKit: the item's availability depends
        // on the guest, not on the responder chain.
        menu.autoenablesItems = false
        let item = NSMenuItem(
            title: "Open Home Assistant",
            action: #selector(openHomeAssistant),
            keyEquivalent: ""
        )
        item.target = self
        item.isEnabled = runtime?.guestStatus.isReady == true
        menu.addItem(item)
        return menu
    }

    @objc private func openHomeAssistant() {
        guard let status = runtime?.guestStatus, case .ready(let url) = status else { return }
        MainActor.assumeIsolated {
            NSWorkspace.shared.open(url)
        } as Void
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runtime else { return .terminateNow }
        // Idempotent: a second quit request while the guest is already halting
        // leaves the shutdown in progress and is answered when it completes.
        runtime.requestTermination()
        return .terminateLater
    }

}
