import Foundation

/// Send a raw HTTP request to a TCP port and return everything the server
/// writes back.
///
/// POSIX rather than `NWConnection`, for the reason ``unixSocketRequest(path:_:)``
/// gives: a `connect(2)` that succeeds is independent evidence that the port is
/// bound and something is listening on it. A listener's own report of where it
/// bound is exactly what issue #12 showed cannot be trusted — it reported
/// success while serving a wildcard ephemeral port.
func tcpRequest(port: UInt16, _ request: String, address: String = "127.0.0.1") throws -> String {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketProbeError.socket(errno) }
    defer { close(fd) }

    var endpoint = sockaddr_in()
    endpoint.sin_family = sa_family_t(AF_INET)
    endpoint.sin_port = port.bigEndian
    endpoint.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    guard address.withCString({ inet_pton(AF_INET, $0, &endpoint.sin_addr) }) == 1 else {
        throw SocketProbeError.malformedAddress(address)
    }

    let connected = withUnsafePointer(to: &endpoint) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { throw SocketProbeError.connect(errno) }

    return try socketExchange(fd: fd, request)
}

/// Ask the kernel for a free loopback TCP port.
///
/// Binding to port 0 and reading back what the kernel chose is the only way to
/// get a port that is free *now*: a fixed port would collide with whatever else
/// is running on a developer's machine or a CI runner. The socket is closed
/// before returning, so the caller's listener gets a fresh bind — and the tests
/// that use this connect to the port afterwards, which is the evidence that
/// matters.
func freeTCPPort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketProbeError.socket(errno) }
    defer { close(fd) }

    var any = sockaddr_in()
    any.sin_family = sa_family_t(AF_INET)
    any.sin_port = 0
    any.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    guard "127.0.0.1".withCString({ inet_pton(AF_INET, $0, &any.sin_addr) }) == 1 else {
        throw SocketProbeError.malformedAddress("127.0.0.1")
    }

    let bound = withUnsafePointer(to: &any) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { throw SocketProbeError.bind(errno) }

    var chosen = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &chosen) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &length)
        }
    }
    guard named == 0 else { throw SocketProbeError.getsockname(errno) }
    return UInt16(bigEndian: chosen.sin_port)
}
