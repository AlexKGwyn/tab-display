import Foundation

/// A decoded message (payload is a slice copied out of the receive buffer).
struct Message {
    let type: UInt8
    let flags: UInt8
    let seq: UInt32
    let timestamp: Int64
    let payload: Data
    let recvNs: Int64
}

/// Little-endian builder for message payloads and headers.
struct Writer {
    var data = Data()
    init(capacity: Int = 64) { data.reserveCapacity(capacity) }
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func i64(_ v: Int64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func bytes(_ d: Data) { data.append(d) }
}

/// Little-endian reader over a payload. Out-of-range reads return 0.
struct Reader {
    let data: Data
    var pos: Int
    init(_ d: Data) { data = d; pos = d.startIndex }
    var remaining: Int { data.endIndex - pos }
    private mutating func read<T: FixedWidthInteger>(_: T.Type) -> T {
        let n = MemoryLayout<T>.size
        guard pos + n <= data.endIndex else { pos = data.endIndex; return 0 }
        var v: T = 0
        _ = withUnsafeMutableBytes(of: &v) { data.copyBytes(to: $0, from: pos..<pos + n) }
        pos += n
        return T(littleEndian: v)
    }
    mutating func u8() -> UInt8 { read(UInt8.self) }
    mutating func u16() -> UInt16 { read(UInt16.self) }
    mutating func u32() -> UInt32 { read(UInt32.self) }
    mutating func i64() -> Int64 { read(Int64.self) }
    mutating func f32() -> Float { Float(bitPattern: u32()) }
    mutating func bytes(_ n: Int) -> Data {
        let e = min(data.endIndex, pos + n)
        defer { pos = e }
        return data.subdata(in: pos..<e)
    }
}

enum Wire {
    static func header(type: UInt8, flags: UInt8 = 0, seq: UInt32, timestamp: Int64 = nowNs(), length: Int) -> Data {
        var w = Writer(capacity: Proto.headerSize)
        w.u16(Proto.magic); w.u8(type); w.u8(flags); w.u32(seq); w.i64(timestamp); w.u32(UInt32(length))
        return w.data
    }

    static func message(type: UInt8, flags: UInt8 = 0, seq: UInt32, timestamp: Int64 = nowNs(), payload: Data = Data()) -> Data {
        var d = header(type: type, flags: flags, seq: seq, timestamp: timestamp, length: payload.count)
        d.append(payload)
        return d
    }

    static let nop = header(type: MsgType.nop, seq: 0, timestamp: 0, length: 0)

    /// Incremental parser for a byte stream.
    struct Parser {
        private var buf = Data()
        mutating func feed(_ bytes: UnsafeRawBufferPointer, recvNs: Int64, _ emit: (Message) -> Void) throws {
            buf.append(contentsOf: bytes)
            var off = buf.startIndex
            while buf.endIndex - off >= Proto.headerSize {
                var r = Reader(buf.subdata(in: off..<off + Proto.headerSize))
                guard r.u16() == Proto.magic else { throw NSError(domain: "Wire", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad magic"]) }
                let type = r.u8(), flags = r.u8(), seq = r.u32(), ts = r.i64(), len = Int(r.u32())
                guard buf.endIndex - off - Proto.headerSize >= len else { break }
                let start = off + Proto.headerSize
                emit(Message(type: type, flags: flags, seq: seq, timestamp: ts, payload: buf.subdata(in: start..<start + len), recvNs: recvNs))
                off = start + len
            }
            if off != buf.startIndex { buf.removeSubrange(buf.startIndex..<off) }
        }
    }
}
