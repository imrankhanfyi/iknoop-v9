import Foundation
import CryptoKit
import CommonCrypto
import Compression

/// Payload encryption. Both primitives are chosen for native WebCrypto interop so the viewer needs
/// no JS crypto library: PBKDF2-HMAC-SHA256 and AES-256-GCM with a 96-bit nonce and 128-bit tag.
enum Payload {
    /// Iteration count. Deliberately high and explicit: the ciphertext is expected to be readable by
    /// whoever hosts it, so an offline dictionary attack on the passphrase is the real threat model and
    /// there is no rate limit to fall back on. PBKDF2 is not memory-hard, so the count is the only
    /// lever. 600k matches current OWASP guidance for PBKDF2-HMAC-SHA256.
    ///
    /// This value is a COMPATIBILITY CONTRACT with the viewer: it is written into the envelope and the
    /// browser reads it from there, so changing it here does not break old payloads mid-flight.
    static let pbkdf2Iterations = 600_000
    static let saltBytes = 16
    static let nonceBytes = 12   // 96 bits — required for WebCrypto AES-GCM interop
    static let formatVersion = 1

    struct Sealed {
        var saltB64: String
        var nonceB64: String
        var ciphertextB64: String
        var aad: String
    }

    /// Derive, then seal. A FRESH random salt and nonce are generated on every publish.
    ///
    /// WHY FRESH SALT EVERY TIME: a stable salt means one derived key encrypts every daily payload for
    /// years, which makes GCM nonce hygiene load-bearing and gives a single key leak retrospective
    /// access to every stored copy. A fresh salt per publish makes each day's key unique, so nonce
    /// reuse across publishes is harmless by construction. It is also why the viewer cannot cache a
    /// derived key across publishes — that trade is deliberate.
    static func seal(plaintext: Data, passphrase: String) throws -> Sealed {
        var salt = Data(count: saltBytes)
        try randomize(&salt)
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: pbkdf2Iterations)

        var nonceData = Data(count: nonceBytes)
        try randomize(&nonceData)
        let nonce = try AES.GCM.Nonce(data: nonceData)

        // AAD binds the KDF/cipher parameters to the ciphertext, so a tampered envelope that tries to
        // downgrade the iteration count (or swap the salt) fails the tag check instead of being
        // silently honoured. The viewer reconstructs this exact string from the envelope fields.
        let aad = aadString(iterations: pbkdf2Iterations, saltB64: salt.base64EncodedString(),
                            nonceB64: nonceData.base64EncodedString())
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce,
                                   authenticating: Data(aad.utf8))
        // combined = nonce ‖ ciphertext ‖ tag; the viewer is given ciphertext‖tag and the nonce
        // separately, which is what WebCrypto's decrypt(iv:) expects.
        guard let combined = box.combined else { throw PublishError("AES-GCM seal produced no combined box") }
        let ctAndTag = combined.dropFirst(nonceBytes)

        return Sealed(saltB64: salt.base64EncodedString(),
                      nonceB64: nonceData.base64EncodedString(),
                      ciphertextB64: Data(ctAndTag).base64EncodedString(),
                      aad: aad)
    }

    /// Round-trip check used by `--self-test`: proves the sealed payload decrypts back to the exact
    /// input bytes with the same parameters the viewer will use.
    static func open(sealed: Sealed, passphrase: String) throws -> Data {
        guard let salt = Data(base64Encoded: sealed.saltB64),
              let nonceData = Data(base64Encoded: sealed.nonceB64),
              let ctAndTag = Data(base64Encoded: sealed.ciphertextB64) else {
            throw PublishError("envelope base64 is malformed")
        }
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: pbkdf2Iterations)
        let box = try AES.GCM.SealedBox(combined: nonceData + ctAndTag)
        return try AES.GCM.open(box, using: key, authenticating: Data(sealed.aad.utf8))
    }

    static func aadString(iterations: Int, saltB64: String, nonceB64: String) -> String {
        "noopv\(formatVersion):\(iterations):\(saltB64):\(nonceB64)"
    }

    private static func deriveKey(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        var out = Data(count: 32)
        let pass = Array(passphrase.utf8)
        let status: Int32 = out.withUnsafeMutableBytes { outBuf in
            salt.withUnsafeBytes { saltBuf in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    // CommonCrypto takes the password as bytes; passing the UTF-8 bytes explicitly
                    // (rather than a C string) keeps a passphrase containing NUL or non-ASCII exactly
                    // in step with the browser's `new TextEncoder().encode(passphrase)`.
                    pass.withUnsafeBufferPointer { $0.baseAddress?.withMemoryRebound(to: CChar.self, capacity: pass.count) { $0 } },
                    pass.count,
                    saltBuf.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    outBuf.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        guard status == kCCSuccess else { throw PublishError("PBKDF2 failed (status \(status))") }
        return SymmetricKey(data: out)
    }

    private static func randomize(_ data: inout Data) throws {
        let status = data.withUnsafeMutableBytes { buf -> Int32 in
            SecRandomCopyBytes(kSecRandomDefault, buf.count, buf.baseAddress!)
        }
        guard status == errSecSuccess else { throw PublishError("SecRandomCopyBytes failed (\(status))") }
    }
}

/// gzip compression.
///
/// Built on the system `Compression` framework's raw DEFLATE (`COMPRESSION_ZLIB` produces a raw
/// deflate stream) plus a hand-written gzip container: 10-byte header, deflate body, CRC32, ISIZE.
/// Done in-process rather than by shelling out to /usr/bin/gzip so a publish has no subprocess
/// failure modes. The browser reads it with the native `DecompressionStream('gzip')`.
enum Gzip {
    static func compress(_ input: Data) throws -> Data {
        let deflated = try rawDeflate(input)
        var out = Data([0x1f, 0x8b, 0x08, 0x00,   // magic, DEFLATE, no flags
                        0x00, 0x00, 0x00, 0x00,   // mtime 0 — deliberately not the wall clock, so an
                                                  // unchanged payload compresses to identical bytes
                        0x00, 0xff])              // XFL, OS = unknown
        out.append(deflated)
        var crc = crc32(input).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        var isize = UInt32(truncatingIfNeeded: input.count).littleEndian
        withUnsafeBytes(of: &isize) { out.append(contentsOf: $0) }
        return out
    }

    private static func rawDeflate(_ input: Data) throws -> Data {
        guard !input.isEmpty else { return Data() }
        // Worst case for incompressible input is slightly larger than the input; pad generously.
        let capacity = input.count + (input.count / 2) + 1024
        var out = Data(count: capacity)
        let written: Int = out.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw PublishError("deflate failed") }
        return out.prefix(written)
    }

    /// Standard CRC-32 (IEEE 802.3, reflected, poly 0xEDB88320) — the gzip trailer checksum.
    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
