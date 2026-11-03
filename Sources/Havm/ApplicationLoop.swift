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
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runtime else { return .terminateNow }
        // Idempotent: a second quit request while the guest is already halting
        // leaves the shutdown in progress and is answered when it completes.
        runtime.requestTermination()
        return .terminateLater
    }

}
