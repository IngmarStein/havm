import Darwin
import Logging

/// Raw terminal mode for `--console`, and putting the terminal back.
///
/// The guest's virtio console expects the bytes as typed, so line buffering,
/// local echo and signal generation all have to go — with `ISIG` cleared,
/// Ctrl+C reaches the guest as `0x03` instead of killing havm.
final class TerminalMode {
    private let logger: Logger
    private var original: termios?
    private(set) var isEnabled = false

    init(logger: Logger) {
        self.logger = logger
    }

    /// Switch stdin to raw mode, remembering the settings to restore. Does
    /// nothing when already enabled, and leaves the terminal alone when the
    /// settings cannot be read or written.
    func enable() {
        guard !isEnabled else { return }
        var raw = termios()
        guard tcgetattr(STDIN_FILENO, &raw) == 0 else {
            logger.warning("Console: tcgetattr failed — terminal may behave unexpectedly")
            return
        }
        original = raw
        cfmakeraw(&raw)
        // Re-enable NL→CR-NL translation so stderr log lines don't drift
        // across the terminal at whatever column the guest cursor left off.
        // OPOST must be set for ONLCR to take effect.
        raw.c_oflag |= tcflag_t(OPOST | ONLCR)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else {
            logger.warning("Console: tcsetattr failed — terminal may behave unexpectedly")
            return
        }
        isEnabled = true
    }

    /// Restore the settings ``enable()`` saved. Safe to call when raw mode was
    /// never enabled, and safe to call twice.
    func restore() {
        guard isEnabled, let original else { return }
        var copy = original
        tcsetattr(STDIN_FILENO, TCSANOW, &copy)
        isEnabled = false
    }
}
