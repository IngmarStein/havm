import Foundation
import Logging

/// A `LogHandler` that writes structured JSON lines to a file handle (e.g. stdout).
///
/// Each log entry is a single JSON object per line (NDJSON):
/// ```json
/// {"timestamp":"2026-06-15T21:30:00Z","level":"info","label":"havm.run","message":"VM started"}
/// ```
public struct JSONLogHandler: LogHandler {
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

    public func log(level: Logger.Level,
                    message: Logger.Message,
                    metadata: Logger.Metadata?,
                    source: String,
                    file: String,
                    function: String,
                    line: UInt) {
        var entry: [String: EncodableValue] = [
            "timestamp": .string(ISO8601DateFormatter().string(from: Date())),
            "level": .string(level.rawValue),
            "label": .string(self.label),
            "message": .string(message.description),
        ]
        if let metadata {
            for (k, v) in metadata {
                entry[k] = .string(v.description)
            }
        }
        // Write JSON line
        if let data = try? JSONSerialization.data(withJSONObject: entry.mapValues(\.rawValue)),
           var line = String(data: data, encoding: .utf8) {
            line.append("\n")
            if let encoded = line.data(using: .utf8) {
                try? stream.write(contentsOf: encoded)
                try? stream.synchronize()
            }
        }
    }
}

/// Helper to bridge Logger.Metadata.Value → JSON-compatible raw values.
private enum EncodableValue {
    case string(String)

    var rawValue: Any {
        switch self {
        case .string(let s): s
        }
    }
}
