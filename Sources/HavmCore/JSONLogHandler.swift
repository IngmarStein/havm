import Foundation
import Logging
import Synchronization

/// A `LogHandler` that writes structured JSON lines to a file handle (e.g. stdout).
///
/// Each log entry is a single JSON object per line (NDJSON):
/// ```json
/// {"timestamp":"2026-06-15T21:30:00Z","level":"info","label":"havm.run","message":"VM started"}
/// ```
///
/// Metadata values are converted to JSON-safe representations:
/// - `.string` → JSON string
/// - `.stringConvertible` → JSON string via `.description`
/// - `.dictionary` → JSON object (recursively converted)
/// - `.array` → JSON array (recursively converted)
public struct JSONLogHandler: LogHandler, Sendable {
    /// Thread-safe since macOS 10.12 (per docs), but Foundation hasn't
    /// adopted Sendable annotations for it yet.
    private nonisolated(unsafe) static let isoFormatter = ISO8601DateFormatter()

    /// Serializes writes so concurrent log calls never interleave mid-line.
    private static let writeLock = Mutex<Void>(())

    private let stream: FileHandle

    public var metadata: Logger.Metadata = [:]
    public var logLevel: Logger.Level
    public var label: String

    public init(label: String, stream: FileHandle, level: Logger.Level = .info) {
        self.label = label
        self.stream = stream
        self.logLevel = level
    }

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(event: Logging.LogEvent) {
        writeEntry(level: event.level, message: event.message, metadata: event.metadata)
    }

    private func writeEntry(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?) {
        var entry: [String: Any] = [:]
        // Merge handler-level metadata first, then per-event metadata so
        // per-event keys take precedence.
        for (k, v) in self.metadata {
            entry[k] = convertMetadataValue(v)
        }
        if let metadata {
            for (k, v) in metadata {
                entry[k] = convertMetadataValue(v)
            }
        }
        // Core fields are written last so arbitrary metadata keys cannot
        // overwrite the structured log schema.
        entry["timestamp"] = Self.isoFormatter.string(from: Date())
        entry["level"] = level.rawValue
        entry["label"] = self.label
        entry["message"] = message.description

        var data = encodeJSON(entry) ?? encodeFallback(label: self.label)
        data.append(0x0A) // '\n'
        Self.writeLock.withLock { _ in
            try? stream.write(contentsOf: data)
        }
    }

    private func encodeFallback(label: String) -> Data {
        let fallback: [String: Any] = [
            "timestamp": Self.isoFormatter.string(from: Date()),
            "level": "error",
            "label": label,
            "message": "Log serialization failed",
        ]
        if let encoded = encodeJSON(fallback) {
            return encoded
        }
        return Data(#"{"level":"error","message":"Log serialization failed"}"#.utf8)
    }
}

// MARK: - Metadata → JSON conversion

/// Recursively convert a `Logger.Metadata.Value` to a JSON-safe type.
private func convertMetadataValue(_ value: Logger.Metadata.Value) -> Any {
    switch value {
    case .string(let s):
        return s
    case .stringConvertible(let c):
        return c.description
    case .dictionary(let d):
        var result: [String: Any] = [:]
        for (k, v) in d {
            result[k] = convertMetadataValue(v)
        }
        return result
    case .array(let a):
        return a.map { convertMetadataValue($0) }
    }
}

/// Encode a dictionary to JSON data. Only fails if values are not
/// JSON-serializable — callers must pre-convert to safe types.
private func encodeJSON(_ dict: [String: Any]) -> Data? {
    guard JSONSerialization.isValidJSONObject(dict) else { return nil }
    return try? JSONSerialization.data(withJSONObject: dict)
}
