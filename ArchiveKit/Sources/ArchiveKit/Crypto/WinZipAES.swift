import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// WinZip AES encryption (AE-1 and AE-2), on CommonCrypto.
///
/// Layout of the stored bytes: salt, a two-byte password verifier, the
/// data encrypted with AES in counter mode, then a ten-byte HMAC-SHA1 of
/// the encrypted data. One PBKDF2-HMAC-SHA1 derivation (1,000 rounds) of
/// the password and salt yields the encryption key, the authentication key
/// and the verifier.
final class WinZipAESDecryptor: ZIPDecryptor {
    private static let authenticationCodeLength = 10

    private let path: String
    private let strength: AESStrength
    private let password: [UInt8]
    private var pending = Data()
    private var isKeyed = false
    private var cryptor: CCCryptorRef?
    /// The next block number, and the unused part of the last key stream block.
    private var counter: UInt64 = 0
    private var keystream: [UInt8] = []
    private var keystreamOffset = 0
    private var hmac = CCHmacContext()

    init(password: [UInt8], strength: AESStrength, path: String) throws {
        self.password = password
        self.strength = strength
        self.path = path
    }

    deinit {
        if let cryptor { CCCryptorRelease(cryptor) }
    }

    func process(_ input: Data, isFinal: Bool) throws -> Data {
        pending.append(input)

        if !isKeyed {
            let headerLength = strength.saltLength + 2
            guard pending.count >= headerLength else {
                if isFinal { throw ArchiveError.corruptData(path: path, reason: "its encryption header is cut off") }
                return Data()
            }
            try deriveKeys(salt: pending.prefix(strength.saltLength), verifier: pending.dropFirst(strength.saltLength).prefix(2))
            pending.removeFirst(headerLength)
            isKeyed = true
        }

        // The last ten bytes are the authentication code, not data.
        let trailer = Self.authenticationCodeLength
        var output = Data()
        if pending.count > trailer {
            let ciphertext = pending.prefix(pending.count - trailer)
            output = try decrypt(Data(ciphertext))
            pending.removeFirst(ciphertext.count)
        }
        if isFinal {
            guard pending.count == trailer else {
                throw ArchiveError.corruptData(path: path, reason: "its authentication code is cut off")
            }
            var code = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
            CCHmacFinal(&hmac, &code)
            // Constant time, though nothing here is secret from the reader.
            var difference: UInt8 = 0
            for (index, byte) in pending.enumerated() { difference |= byte ^ code[index] }
            guard difference == 0 else {
                throw ArchiveError.corruptData(path: path, reason: "its authentication code does not match, so it is damaged")
            }
        }
        return output
    }

    private func deriveKeys(salt: Data.SubSequence, verifier: Data.SubSequence) throws {
        let keyLength = strength.keyLength
        var derived = [UInt8](repeating: 0, count: keyLength * 2 + 2)
        let saltBytes = [UInt8](salt)
        let status = password.withUnsafeBufferPointer { passwordBuffer in
            passwordBuffer.withMemoryRebound(to: CChar.self) { chars in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    chars.baseAddress, chars.count,
                    saltBytes, saltBytes.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1000,
                    &derived, derived.count
                )
            }
        }
        guard status == kCCSuccess else { throw ArchiveError.io("The password could not be processed.") }
        guard [UInt8](verifier) == Array(derived[(keyLength * 2)...]) else {
            throw ArchiveError.invalidPassword(path: path)
        }

        // Counter mode is built from AES in ECB mode, because the counter is
        // a 128-bit little-endian integer starting at 1, which CommonCrypto's
        // public counter modes do not offer.
        var ref: CCCryptorRef?
        let created = CCCryptorCreateWithMode(
            CCOperation(kCCEncrypt), CCMode(kCCModeECB), CCAlgorithm(kCCAlgorithmAES),
            CCPadding(ccNoPadding), nil, Array(derived[0..<keyLength]), keyLength,
            nil, 0, 0, 0, &ref
        )
        guard created == kCCSuccess, ref != nil else { throw ArchiveError.io("The decryptor could not be started.") }
        cryptor = ref
        counter = 1
        let authenticationKey = Array(derived[keyLength..<(keyLength * 2)])
        CCHmacInit(&hmac, CCHmacAlgorithm(kCCHmacAlgSHA1), authenticationKey, authenticationKey.count)
    }

    private func decrypt(_ ciphertext: Data) throws -> Data {
        guard let cryptor else { return Data() }
        ciphertext.withUnsafeBytes { CCHmacUpdate(&hmac, $0.baseAddress, $0.count) }

        var plain = [UInt8](ciphertext)
        var index = 0
        while index < plain.count {
            if keystreamOffset == keystream.count {
                // Key stream for as many blocks as the rest of the chunk needs.
                let blocks = min((plain.count - index + 15) / 16, 4096)
                var counters = [UInt8](repeating: 0, count: blocks * 16)
                for block in 0..<blocks {
                    // Little-endian; the upper 64 bits stay zero.
                    withUnsafeBytes(of: (counter + UInt64(block)).littleEndian) { bytes in
                        for (offset, byte) in bytes.enumerated() { counters[block * 16 + offset] = byte }
                    }
                }
                counter += UInt64(blocks)
                var produced = 0
                keystream = [UInt8](repeating: 0, count: counters.count)
                let status = CCCryptorUpdate(cryptor, counters, counters.count, &keystream, keystream.count, &produced)
                guard status == kCCSuccess, produced == counters.count else {
                    throw ArchiveError.io("The data could not be decrypted.")
                }
                keystreamOffset = 0
            }
            let count = min(plain.count - index, keystream.count - keystreamOffset)
            for offset in 0..<count {
                plain[index + offset] ^= keystream[keystreamOffset + offset]
            }
            index += count
            keystreamOffset += count
        }
        return Data(plain)
    }
}
