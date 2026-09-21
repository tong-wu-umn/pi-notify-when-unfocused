import Foundation

public enum NdjsonError: Error, Equatable {
    /// A single frame exceeded the configured ceiling. herdr snapshots are a few KB;
    /// 8 MiB means something is wrong and the connection should be torn down.
    case frameTooLarge(limit: Int)
}

/// Incremental newline-delimited JSON framer.
///
/// herdr speaks one JSON object per line in both directions. `URLSession` is not
/// involved; the app reads raw `AF_UNIX` sockets, so this is the only place that
/// knows about framing. Bytes are bounded so a hostile or broken peer cannot make the
/// app allocate without limit.
public struct NdjsonFramer: Sendable {
    public let maxFrameBytes: Int
    private var buffer = Data()

    public init(maxFrameBytes: Int = 8 * 1024 * 1024) {
        self.maxFrameBytes = maxFrameBytes
    }

    public var pendingBytes: Int { buffer.count }

    /// Appends a chunk and returns every complete frame it completed.
    public mutating func append(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var frames: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let frame = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if !frame.isEmpty {
                frames.append(Data(frame))
            }
        }
        if buffer.count > maxFrameBytes {
            buffer.removeAll(keepingCapacity: false)
            throw NdjsonError.frameTooLarge(limit: maxFrameBytes)
        }
        return frames
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
    }
}

/// JSON encoder/decoder configured for herdr's snake_case wire format.
public enum HerdrCoding {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder().encode(value)
        data.append(0x0A)
        return data
    }

    public static func decodeFrame<T: Decodable>(_ frame: Data, as type: T.Type) throws -> T {
        try decoder().decode(type, from: frame)
    }
}
