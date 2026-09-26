import Foundation

/// Errors from the raw POSIX socket probe below.
enum SocketProbeError: Error, CustomStringConvertible {
    case socket(Int32)
    case bind(Int32)
    case connect(Int32)
    case pathTooLong
    case malformedResponse

    var description: String {
        switch self {
        case .socket(let code): return "socket() failed: \(String(cString: strerror(code)))"
        case .bind(let code): return "bind() failed: \(String(cString: strerror(code)))"
        case .connect(let code): return "connect() failed: \(String(cString: strerror(code)))"
        case .pathTooLong: return "path does not fit in sockaddr_un.sun_path"
        case .malformedResponse: return "response is not UTF-8"
        }
    }
}

/// Send a raw HTTP request to a Unix domain socket and return everything the
/// server writes back.
///
/// Deliberately POSIX rather than `NWConnection`: connecting with `connect(2)`
/// to a real `AF_UNIX` endpoint is independent evidence that the socket file
/// exists and something is listening on it, which is exactly what a
/// Network.framework-only test could not distinguish from a listener that
/// silently never bound. The server closes the connection after responding,
/// so reading to EOF terminates.
func unixSocketRequest(path: String, _ request: String) throws -> String {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketProbeError.socket(errno) }
    defer { close(fd) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let pathBytes = Array(path.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        throw SocketProbeError.pathTooLong
    }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }

    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { throw SocketProbeError.connect(errno) }

    let outbound = Array(request.utf8)
    _ = outbound.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }

    var response: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let received = read(fd, &buffer, buffer.count)
        guard received > 0 else { break }
        response.append(contentsOf: buffer[0..<received])
    }
    // Not `String(decoding:as:)`: that replaces invalid UTF-8 with U+FFFD, and
    // a probe should say the response was malformed rather than hand back
    // mojibake that a string comparison would then quietly fail on.
    guard let text = String(bytes: response, encoding: .utf8) else {
        throw SocketProbeError.malformedResponse
    }
    return text
}
