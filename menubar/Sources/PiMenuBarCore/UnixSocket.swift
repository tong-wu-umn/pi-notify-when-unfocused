import Darwin
import Foundation

public enum SocketError: Error, Equatable, CustomStringConvertible {
    case pathTooLong(Int)
    case createFailed(Int32)
    case connectFailed(Int32)
    case connectTimeout
    case writeFailed(Int32)
    case readFailed(Int32)
    case closed
    case frameTooLarge(Int)

    public var description: String {
        switch self {
        case let .pathTooLong(length): return "socket path is \(length) bytes; the kernel limit is 104"
        case let .createFailed(code): return "socket() failed: \(String(cString: strerror(code)))"
        case let .connectFailed(code): return "connect() failed: \(String(cString: strerror(code)))"
        case .connectTimeout: return "connect() timed out"
        case let .writeFailed(code): return "write() failed: \(String(cString: strerror(code)))"
        case let .readFailed(code): return "read() failed: \(String(cString: strerror(code)))"
        case .closed: return "the peer closed the connection"
        case let .frameTooLarge(limit): return "a frame exceeded \(limit) bytes"
        }
    }
}

/// Blocking `AF_UNIX` client with explicit timeouts.
///
/// herdr's socket is a plain stream socket; `URLSession` and `FileHandle` cannot target
/// it, so this is the only transport in the app. Every operation is bounded: the app is
/// a menu bar item, and a hung read must never wedge a thread forever. All calls block
/// the calling thread, so callers use a background queue.
public final class UnixSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1

    public static let unixPathLimit = 104

    public init(path: String) throws {
        let length = path.utf8.count
        guard length < Self.unixPathLimit else { throw SocketError.pathTooLong(length) }
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SocketError.createFailed(errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: Array(path.utf8) + [0])
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            let code = errno
            close()
            throw SocketError.connectFailed(code)
        }
        Self.setNonBlocking(descriptor)
    }

    deinit { close() }

    /// Wakes any blocked `poll()` and makes the stream report EOF.
    ///
    /// `close()` alone does not reliably interrupt a poll running on another thread
    /// (and can race with file-descriptor reuse), so cancellation shuts the socket down
    /// first and lets the blocked reader observe EOF.
    @discardableResult
    public func interrupt() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { return false }
        return shutdown(descriptor, SHUT_RDWR) == 0
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    public var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return descriptor >= 0
    }

    /// Writes all bytes or throws when the deadline passes.
    public func send(_ data: Data, timeout: TimeInterval) throws {
        var remaining = data
        let deadline = Date().addingTimeInterval(timeout)
        while !remaining.isEmpty {
            guard try wait(for: Int16(POLLOUT), deadline: deadline) else { throw SocketError.connectTimeout }
            let written = remaining.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return writeCurrentFd(base, buffer.count)
            }
            if written > 0 {
                remaining = remaining.dropFirst(written)
            } else if written < 0 {
                let code = errno
                if code == EAGAIN || code == EINTR { continue }
                throw SocketError.writeFailed(code)
            }
        }
    }

    /// Returns nil when the deadline passes with no data. An empty `Data` means EOF.
    public func receive(maxBytes: Int = 64 * 1024, timeout: TimeInterval) throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        let deadline = Date().addingTimeInterval(timeout)
        guard try wait(for: Int16(POLLIN), deadline: deadline) else { return nil }
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return readCurrentFd(base, raw.count)
        }
        if count == 0 { return Data() }
        if count < 0 {
            let code = errno
            if code == EAGAIN || code == EINTR { return nil }
            throw SocketError.readFailed(code)
        }
        return Data(buffer[0..<count])
    }

    private func writeCurrentFd(_ base: UnsafeRawPointer, _ count: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { return -1 }
        return Darwin.write(descriptor, base, count)
    }

    private func readCurrentFd(_ base: UnsafeMutableRawPointer, _ count: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { return -1 }
        return Darwin.read(descriptor, base, count)
    }

    private static func setNonBlocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    private func wait(for events: Int16, deadline: Date) throws -> Bool {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return false }
            var pollDescriptor = pollfd()
            lock.lock()
            let current = descriptor
            lock.unlock()
            guard current >= 0 else { throw SocketError.closed }
            pollDescriptor.fd = current
            pollDescriptor.events = events
            let milliseconds = Int32(min(remaining * 1000, Double(Int32.max)))
            let ready = poll(&pollDescriptor, 1, milliseconds)
            if ready > 0 {
                if pollDescriptor.revents & Int16(POLLNVAL) != 0 { throw SocketError.closed }
                return true
            }
            if ready == 0 { return false }
            let code = errno
            if code == EINTR { continue }
            throw SocketError.readFailed(code)
        }
    }
}

// MARK: - Request/response helpers

public enum HerdrTransport {
    /// Sends one request frame and returns the first response frame.
    ///
    /// herdr answers a request on a fresh connection immediately, so one frame is
    /// enough. `events.subscribe` is the exception and uses `HerdrEventStream`.
    public static func request(
        socketPath: String,
        request: Data,
        readTimeout: TimeInterval = 4
    ) throws -> Data {
        let socket = try UnixSocket(path: socketPath)
        defer { socket.close() }
        try socket.send(request, timeout: 2)

        var framer = NdjsonFramer()
        let deadline = Date().addingTimeInterval(readTimeout)
        while Date() < deadline {
            guard let chunk = try socket.receive(timeout: max(0.05, deadline.timeIntervalSinceNow)) else { break }
            if chunk.isEmpty { break }
            let frames = try framer.append(chunk)
            if let first = frames.first { return first }
        }
        throw SocketError.connectTimeout
    }

    /// Decodes a response frame, surfacing herdr's `error` object as a thrown value.
    ///
    /// Decode failures keep their description instead of collapsing into a bare errno:
    /// protocol drift must be diagnosable from the log.
    public static func decodeResult<Result: Decodable & Sendable>(
        _ frame: Data,
        as type: Result.Type
    ) throws -> Result {
        let response: HerdrResponse<Result>
        do {
            response = try HerdrCoding.decodeFrame(frame, as: HerdrResponse<Result>.self)
        } catch {
            throw HerdrDecodeError(description: "\(error)", frame: String(decoding: frame.prefix(400), as: UTF8.self))
        }
        if let herdrError = response.error {
            throw HerdrRequestError(code: herdrError.code, message: herdrError.message)
        }
        guard let result = response.result else {
            throw HerdrDecodeError(description: "response carried neither result nor error", frame: String(decoding: frame.prefix(400), as: UTF8.self))
        }
        return result
    }
}

public struct HerdrDecodeError: Error, CustomStringConvertible {
    public let description: String
    public let frame: String

    public init(description: String, frame: String) {
        self.description = "\(description) (frame: \(frame))"
        self.frame = frame
    }
}

public struct HerdrRequestError: Error, Equatable, CustomStringConvertible {
    public let code: String
    public let message: String

    public var description: String { "\(code): \(message)" }
}

/// Long-lived subscription socket. One connection carries the event stream; a request
/// sent on it afterwards is never answered, so it is used for nothing else.
public final class HerdrEventStream: @unchecked Sendable {
    private let socket: UnixSocket
    private var framer = NdjsonFramer()
    private let lock = NSLock()

    public init(socketPath: String) throws {
        socket = try UnixSocket(path: socketPath)
    }

    public func send(_ data: Data) throws {
        try socket.send(data, timeout: 3)
    }

    /// Blocks until the next frames arrive. Throws on EOF, timeout, bad framing.
    public func nextFrames(timeout: TimeInterval = 30) throws -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        while true {
            guard let chunk = try socket.receive(timeout: timeout) else {
                throw SocketError.connectTimeout
            }
            if chunk.isEmpty { throw SocketError.closed }
            let frames = try framer.append(chunk)
            if !frames.isEmpty { return frames }
        }
    }

    /// Unblocks a reader waiting in `nextFrames` and disconnects the stream.
    public func cancel() {
        socket.interrupt()
    }

    public var isOpen: Bool { socket.isOpen }
}
