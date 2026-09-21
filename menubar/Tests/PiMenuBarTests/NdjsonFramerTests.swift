import Foundation
@testable import PiMenuBarCore

func registerNdjsonFramerTests(_ t: TestRunner) {
    t.test("SplitsMultipleFramesFromOneChunk") {
        var framer = NdjsonFramer()
        let frames = try framer.append(Data("{\"a\":1}\n{\"b\":2}\n".utf8))
        expectEqual(frames.count, 2)
        expectEqual(String(decoding: frames[0], as: UTF8.self), "{\"a\":1}")
        expectEqual(String(decoding: frames[1], as: UTF8.self), "{\"b\":2}")
        expectEqual(framer.pendingBytes, 0)
    }

    t.test("ReassemblesFrameSplitAcrossChunks") {
        var framer = NdjsonFramer()
        expectTrue(try framer.append(Data("{\"event\":\"pane_up".utf8)).isEmpty)
        expectEqual(framer.pendingBytes, 17)
        let frames = try framer.append(Data("dated\"}\n".utf8))
        expectEqual(String(decoding: frames[0], as: UTF8.self), "{\"event\":\"pane_updated\"}")
    }

    t.test("IgnoresEmptyLines") {
        var framer = NdjsonFramer()
        let frames = try framer.append(Data("\n\n{\"a\":1}\n\n".utf8))
        expectEqual(frames.count, 1)
    }

    t.test("OversizedFrameThrowsAndDropsBuffer") {
        var framer = NdjsonFramer(maxFrameBytes: 32)
        expectThrows(try framer.append(Data(repeating: 0x41, count: 64))) { error in
            expectEqual(error as? NdjsonError, .frameTooLarge(limit: 32))
        }
        // The connection is unusable after this, but the framer must not keep the bytes.
        expectEqual(framer.pendingBytes, 0)
    }

    t.test("CompleteFramesSurviveALargeTrailingPartialFrame") {
        var framer = NdjsonFramer(maxFrameBytes: 64)
        let frames = try framer.append(Data("{\"a\":1}\n{\"partial\":".utf8))
        expectEqual(frames.count, 1)
        expectThrows(try framer.append(Data(repeating: 0x42, count: 128)))
    }

    t.test("ResetClearsPartialBytes") {
        var framer = NdjsonFramer()
        _ = try framer.append(Data("{\"partial\":".utf8))
        framer.reset()
        expectEqual(framer.pendingBytes, 0)
    }

    t.test("DecodesFrameIntoAType") {
        let ack = try HerdrCoding.decodeFrame(Data("{\"type\":\"subscription_started\"}".utf8), as: HerdrSubscribeAck.self)
        expectEqual(ack.type, "subscription_started")
    }

    t.test("EncodedRequestIsASingleLine") {
        let line = try HerdrCoding.encodeLine(HerdrRequests.snapshot(id: "x"))
        expectEqual(line.filter { $0 == 0x0A }.count, 1, "a request must be exactly one frame")
    }
}
