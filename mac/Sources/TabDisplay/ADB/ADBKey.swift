import Foundation
import Security

/// The RSA key this app uses to authenticate to adbd when talking to a tablet over USB directly
/// (without an adb server). Stored in Application Support, readable only by the user. The tablet
/// asks "Allow USB debugging?" for it once; after that the signature is accepted silently.
final class ADBKey {
    let privateKey: SecKey
    let publicKey: SecKey

    static let shared: ADBKey? = try? ADBKey.loadOrCreate()

    private init(privateKey: SecKey) throws {
        self.privateKey = privateKey
        guard let pub = SecKeyCopyPublicKey(privateKey) else { throw ADBError.key("no public key") }
        publicKey = pub
    }

    private static var keyURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tab Display", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("adbkey.der")
    }

    private static func loadOrCreate() throws -> ADBKey {
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        if let data = try? Data(contentsOf: keyURL),
           let key = SecKeyCreateWithData(data as CFData, attrs as CFDictionary, nil) {
            return try ADBKey(privateKey: key)
        }
        var err: Unmanaged<CFError>?
        let genAttrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        guard let key = SecKeyCreateRandomKey(genAttrs as CFDictionary, &err),
              let data = SecKeyCopyExternalRepresentation(key, &err) as Data? else {
            throw ADBError.key("could not generate a key: \(err?.takeRetainedValue().localizedDescription ?? "?")")
        }
        try data.write(to: keyURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        Log.info("adb: generated a new RSA key")
        return try ADBKey(privateKey: key)
    }

    /// Signs adbd's 20-byte AUTH token (treated as a SHA-1 digest, PKCS#1 v1.5).
    func sign(token: Data) throws -> Data {
        var err: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(privateKey, .rsaSignatureDigestPKCS1v15SHA1, token as CFData, &err) as Data? else {
            throw ADBError.key("sign failed: \(err?.takeRetainedValue().localizedDescription ?? "?")")
        }
        return sig
    }

    /// "<base64 Android RSAPublicKey struct> <name>\0", as sent in AUTH(RSAPUBLICKEY).
    func adbPublicKey(name: String) throws -> Data {
        var err: Unmanaged<CFError>?
        guard let der = SecKeyCopyExternalRepresentation(publicKey, &err) as Data? else { throw ADBError.key("no public key data") }
        let (modulus, exponent) = try ADBKey.parseRSAPublicKey(der)
        // Android's mincrypt RSAPublicKey: len, n0inv, n[64], rr[64], exponent (little-endian u32s).
        let words = 64
        var n = [UInt32](repeating: 0, count: words)
        let m = Array(modulus.drop { $0 == 0 })  // big-endian magnitude
        guard m.count <= words * 4 else { throw ADBError.key("unexpected key size") }
        for (i, byte) in m.reversed().enumerated() { n[i / 4] |= UInt32(byte) << (8 * UInt32(i % 4)) }
        // n0inv = -1 / n[0] mod 2^32 (Newton iteration for the inverse of an odd number).
        var inv: UInt32 = n[0]
        for _ in 0..<5 { inv = inv &* (2 &- n[0] &* inv) }
        let n0inv = 0 &- inv
        // rr = (2^2048)^2 mod n, by doubling 4096 times with conditional subtraction.
        var r = [UInt32](repeating: 0, count: words + 1)
        r[0] = 1
        for _ in 0..<(2 * 32 * words) {
            var carry: UInt32 = 0
            for i in 0...words { let v = r[i]; r[i] = (v << 1) | carry; carry = v >> 31 }
            if ADBKey.compare(r, n) >= 0 { ADBKey.subtract(&r, n) }
        }
        var out = Data()
        func put(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        put(UInt32(words)); put(n0inv)
        n.forEach(put)
        r.prefix(words).forEach(put)
        put(exponent)
        var s = Data(out.base64EncodedString().utf8)
        s.append(contentsOf: " \(name)".utf8)
        s.append(0)
        return s
    }

    // MARK: helpers

    /// r (words+1) vs n (words): -1, 0, 1.
    private static func compare(_ r: [UInt32], _ n: [UInt32]) -> Int {
        if r[n.count] != 0 { return 1 }
        for i in stride(from: n.count - 1, through: 0, by: -1) where r[i] != n[i] { return r[i] > n[i] ? 1 : -1 }
        return 0
    }

    private static func subtract(_ r: inout [UInt32], _ n: [UInt32]) {
        var borrow: Int64 = 0
        for i in 0..<r.count {
            var v = Int64(r[i]) - (i < n.count ? Int64(n[i]) : 0) - borrow
            borrow = v < 0 ? 1 : 0
            if v < 0 { v += 1 << 32 }
            r[i] = UInt32(v)
        }
    }

    /// PKCS#1 RSAPublicKey DER: SEQUENCE { INTEGER n, INTEGER e }.
    static func parseRSAPublicKey(_ der: Data) throws -> (modulus: [UInt8], exponent: UInt32) {
        var p = 0
        let b = [UInt8](der)
        func length() throws -> Int {
            guard p < b.count else { throw ADBError.key("bad DER") }
            var len = Int(b[p]); p += 1
            if len & 0x80 != 0 {
                let n = len & 0x7f
                len = 0
                for _ in 0..<n { guard p < b.count else { throw ADBError.key("bad DER") }; len = len << 8 | Int(b[p]); p += 1 }
            }
            return len
        }
        func integer() throws -> [UInt8] {
            guard p < b.count, b[p] == 0x02 else { throw ADBError.key("bad DER") }
            p += 1
            let len = try length()
            guard p + len <= b.count else { throw ADBError.key("bad DER") }
            defer { p += len }
            return Array(b[p..<p + len])
        }
        guard b.first == 0x30 else { throw ADBError.key("bad DER") }
        p = 1
        _ = try length()
        let n = try integer()
        let e = try integer().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return (n, e)
    }
}

enum ADBError: LocalizedError {
    case key(String), protocolError(String), unauthorized, awaitingApproval, noDevice, failed(String)
    var errorDescription: String? {
        switch self {
        case .key(let s): return "ADB key: \(s)"
        case .protocolError(let s): return "ADB: \(s)"
        case .unauthorized: return "Allow USB debugging on the tablet"
        case .awaitingApproval: return "Tap Allow on the tablet"
        case .noDevice: return "Tablet not found"
        case .failed(let s): return s
        }
    }
}
