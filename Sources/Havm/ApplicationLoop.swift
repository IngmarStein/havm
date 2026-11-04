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

    /// Right-clicking the Dock tile is where havm answers "what is it doing"
    /// and offers the two things you would otherwise reach for a browser or a
    /// terminal to do. Quit is not repeated here — the Dock adds its own, and
    /// with the formula's `keep_alive true` quitting just has launchd start
    /// havm again.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let runtime else { return nil }
        let status = runtime.guestStatus

        let menu = NSMenu()
        // Decided here rather than by AppKit: what is available depends on the
        // guest, not on the responder chain.
        menu.autoenablesItems = false

        let summary = NSMenuItem(title: Self.summary(for: status), action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        menu.addItem(.separator())

        menu.addItem(action("Open Home Assistant", #selector(openHomeAssistant), enabled: status.isReady))
        menu.addItem(action("Copy SSH Command", #selector(copySSHCommand), enabled: status.isReady))

        // Left out rather than greyed when no token is configured: an item that
        // can never be enabled is noise in a menu this short.
        if runtime.canRestartHomeAssistant {
            menu.addItem(.separator())
            menu.addItem(action("Restart Home Assistant", #selector(restartHomeAssistant), enabled: status.isReady))
        }
        return menu
    }

    /// The one line at the top of the menu: what the guest is doing, and where.
    private static func summary(for status: GuestStatus) -> String {
        switch status {
        case .booting:
            return "Starting Home Assistant…"
        case .ready(let url):
            return "Home Assistant at \(url.host ?? url.absoluteString)"
        case .unreachable:
            return "Home Assistant is not responding"
        }
    }

    private func action(_ title: String, _ selector: Selector, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    @objc private func openHomeAssistant() {
        guard let status = runtime?.guestStatus, case .ready(let url) = status else { return }
        MainActor.assumeIsolated {
            NSWorkspace.shared.open(url)
        } as Void
    }

    /// Copies the command havm prints in its startup banner, in the same form,
    /// so the two cannot drift apart.
    @objc private func copySSHCommand() {
        guard let status = runtime?.guestStatus, case .ready(let url) = status,
              let host = url.host else { return }
        MainActor.assumeIsolated {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString("ssh root@\(host) -p 22222", forType: .string)
        } as Void
    }

    @objc private func restartHomeAssistant() {
        runtime?.restartHomeAssistant()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runtime else { return .terminateNow }
        // Idempotent: a second quit request while the guest is already halting
        // leaves the shutdown in progress and is answered when it completes.
        runtime.requestTermination()
        return .terminateLater
    }

}
