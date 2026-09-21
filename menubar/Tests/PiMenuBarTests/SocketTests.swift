import Darwin
import Foundation
@testable import PiMenuBarCore

/// A throwaway AF_UNIX server so socket tests exercise the real transport instead of a
/// mock. Only ever bound under the test's temporary directory.
final class TestUnixServer: @unchecked Sendable {
    let path: String
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "pimenubar.test-server")
    private var connections: [Int32] = []
    private var running = true

    /// `handler` receives everything the client sends and returns what to answer.
    /// A nil return closes the connection (simulating herdr going away).
    init(name: String = "herdr", responder: @escaping @Sendable (Data) -> [Data]) throws {
        // AF_UNIX paths are limited to 104 bytes, and NSTemporaryDirectory() alone is
        // already ~49 on macOS, so the server binds under /tmp with a short unique name.
        path = "/tmp/pmb-\(UUID().uuidString.prefix(8)).sock"

        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SocketError.createFailed(errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: Array(path.utf8) + [0])
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else {
            let code = errno
            close(descriptor)
            throw SocketError.createFailed(code)
        }

        queue.async { [descriptor] in
            while self.running {
                let client = accept(descriptor, nil, nil)
                if client < 0 { break }
                self.connections.append(client)
                DispatchQueue.global().async {
                    var framer = NdjsonFramer()
                    while self.running {
                        var buffer = [UInt8](repeating: 0, count: 4096)
                        let count = read(client, &buffer, buffer.count)
                        if count <= 0 { break }
                        guard let frames = try? framer.append(Data(buffer[0..<count])) else { break }
                        for frame in frames {
                            for response in responder(frame) {
                                guard let newline = response.first.map({ _ in true }) else { continue }
                                var payload = response
                                if newline, payload.last != 0x0A { payload.append(0x0A) }
                                _ = payload.withUnsafeBytes { raw in
                                    write(client, raw.baseAddress, raw.count)
                                }
                            }
                        }
                    }
                    close(client)
                }
            }
        }
    }

    deinit {
        running = false
        close(descriptor)
        for connection in connections { close(connection) }
        try? FileManager.default.removeItem(atPath: path)
    }
}

func registerUnixSocketTests(_ t: TestRunner) {
    t.test("RequestReceivesResponseFrame") {
        let server = try TestUnixServer { request in
            expectTrue(String(decoding: request, as: UTF8.self).contains("\"method\":\"session.snapshot\""))
            return [Data("{\"id\":\"x\",\"result\":{\"snapshot\":{\"protocol\":22}}}".utf8)]
        }
        let frame = try HerdrTransport.request(
            socketPath: server.path,
            request: try HerdrCoding.encodeLine(HerdrRequests.snapshot(id: "x"))
        )
        let response = try HerdrCoding.decodeFrame(frame, as: HerdrResponse<HerdrSnapshotEnvelope>.self)
        expectEqual(response.result?.snapshot.protocol, 22)
    }

    t.test("RequestSurfacesHerdrErrors") {
        let server = try TestUnixServer { _ in
            [Data(Fixtures.errorAgentNotFoundJSON.utf8)]
        }
        // Transports succeed; the failure is carried in herdr's `error` object and
        // surfaces when the frame is decoded.
        let frame = try HerdrTransport.request(
            socketPath: server.path,
            request: try HerdrCoding.encodeLine(HerdrRequests.focusAgent(id: "x", paneId: "nope"))
        )
        expectThrows(try HerdrTransport.decodeResult(frame, as: HerdrSubscribeAck.self)) { error in
            expectEqual((error as? HerdrRequestError)?.code, "agent_not_found")
        }
    }

    t.test("RequestFailsWhenTheSocketIsMissing") {
        expectThrows(try HerdrTransport.request(
            socketPath: "/tmp/pimenubar-does-not-exist.sock",
            request: Data("{}\n".utf8)
        ))
    }

    t.test("EventStreamYieldsMultipleFramesAndDetectsEof") {
        let server = try TestUnixServer { _ in
            [Data("{\"id\":\"s\",\"result\":{\"type\":\"subscription_started\"}}\n{\"event\":\"pane_updated\",\"data\":{}}\n".utf8)]
        }
        let stream = try HerdrEventStream(socketPath: server.path)
        try stream.send(try HerdrCoding.encodeLine(
            HerdrRequests.subscribe(id: "s", [HerdrSubscription(type: "pane.updated")])
        ))
        let frames = try stream.nextFrames(timeout: 3)
        expectEqual(frames.count, 2, "one read delivered two frames")
        let ack = try HerdrCoding.decodeFrame(frames[0], as: HerdrResponse<HerdrSubscribeAck>.self)
        expectEqual(ack.result?.type, "subscription_started")
        let event = try HerdrCoding.decodeFrame(frames[1], as: HerdrEvent.self)
        expectEqual(HerdrEventKind.kind(for: event.event), HerdrEventKind.paneUpdated)
        stream.cancel()
    }

    t.test("EventStreamCancelUnblocksAWaitingReader") {
        let server = try TestUnixServer { _ in [] }
        let stream = try HerdrEventStream(socketPath: server.path)
        let started = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { stream.cancel() }
        expectThrows(try stream.nextFrames(timeout: 10))
        expectTrue(Date().timeIntervalSince(started) < 5, "cancel() must not wait for the read timeout")
    }

    t.test("RejectsAnOverlongPath") {
        expectThrows(try UnixSocket(path: "/" + String(repeating: "a", count: 200))) { error in
            expectEqual(error as? SocketError, .pathTooLong(201))
        }
    }

    t.test("UsableSocketChecksTypeOwnerAndConnectability") {
        let server = try TestUnixServer { _ in [] }
        expectTrue(HerdrSocketDiscovery.isUsableSocket(server.path))
        expectFalse(HerdrSocketDiscovery.isUsableSocket("/tmp/pimenubar-missing.sock"))
        let file = "/tmp/pmb-regular-\(UUID().uuidString.prefix(8)).txt"
        FileManager.default.createFile(atPath: file, contents: Data("x".utf8))
        expectFalse(HerdrSocketDiscovery.isUsableSocket(file), "a regular file is not a socket")
        try? FileManager.default.removeItem(atPath: file)
    }
}

func registerHerdrSocketDiscoveryTests(_ t: TestRunner) {
    t.test("PrecedenceIsConfigThenEnvironmentThenRegistryThenDefault") {
        let records = [
            TestSupport.record(["updatedAt": Date(millis: 200).millis, "herdr": ["paneId": "w1:p1", "socketPath": "/tmp/older.sock"]]),
            TestSupport.record(["updatedAt": Date(millis: 900).millis, "herdr": ["paneId": "w1:p1", "socketPath": "/tmp/newer.sock"]]),
        ]
        let candidates = HerdrSocketDiscovery.candidates(
            configuredPath: "/tmp/configured.sock",
            registry: records,
            environment: ["HERDR_SOCKET_PATH": "/tmp/env.sock"],
            defaultPath: "/tmp/default.sock"
        )
        expectEqual(
            candidates.map(\.path),
            ["/tmp/configured.sock", "/tmp/env.sock", "/tmp/newer.sock", "/tmp/older.sock", "/tmp/default.sock"]
        )
        expectEqual(candidates[0].source, "config herdrSocketPath")
        expectEqual(candidates[2].source, "registry")
    }

    t.test("DiscoveryWorksWithNoEnvironmentAtAll") {
        // The LaunchAgent case: no shell environment, herdr alive, registry on disk.
        let records = [TestSupport.record(["herdr": ["paneId": "w1:p1", "socketPath": "/tmp/from-registry.sock"]])]
        let candidates = HerdrSocketDiscovery.candidates(
            configuredPath: nil,
            registry: records,
            environment: [:],
            defaultPath: "/tmp/default.sock"
        )
        expectEqual(candidates.map(\.path), ["/tmp/from-registry.sock", "/tmp/default.sock"])
    }

    t.test("DuplicatesAndTildePathsAreNormalized") {
        let records = [TestSupport.record(["herdr": ["paneId": "w1:p1", "socketPath": "~/.config/herdr/herdr.sock"]])]
        let candidates = HerdrSocketDiscovery.candidates(
            configuredPath: "~/.config/herdr/herdr.sock",
            registry: records,
            environment: ["HERDR_SOCKET_PATH": "~/.config/herdr/herdr.sock"],
            defaultPath: HerdrProtocol.defaultSocketPath
        )
        expectEqual(candidates.count, 1, "the same path from three sources must appear once")
        expectFalse(candidates[0].path.hasPrefix("~"))
    }

    t.test("RelativePathsAreIgnored") {
        let candidates = HerdrSocketDiscovery.candidates(
            configuredPath: "relative/herdr.sock",
            registry: [],
            environment: [:],
            defaultPath: "/tmp/default.sock"
        )
        expectEqual(candidates.map(\.path), ["/tmp/default.sock"])
    }
}
