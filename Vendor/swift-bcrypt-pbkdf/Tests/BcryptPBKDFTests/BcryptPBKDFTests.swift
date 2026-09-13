import XCTest

@testable import BcryptPBKDF

final class BcryptPBKDFTests: XCTestCase {
    /// Known-answer vector from the OpenBSD reference implementation (also used by
    /// Go's x/crypto bcrypt_pbkdf tests): password "password", salt "salt",
    /// 12 rounds, 32-byte output.
    func testKnownAnswerVector() throws {
        let key = try XCTUnwrap(BcryptPBKDF.derive(
            passphrase: Array("password".utf8),
            salt: Array("salt".utf8),
            rounds: 12,
            keyLength: 32))
        XCTAssertEqual(
            Data(key).map { String(format: "%02x", $0) }.joined(),
            "1ae42c05d487bc02f64921a4ebe4ea93bcacfe135fda99974c06b7b01fae149a")
    }

    func testIsDeterministic() {
        let a = BcryptPBKDF.derive(passphrase: Array("hunter2".utf8), salt: [1, 2, 3, 4], rounds: 8, keyLength: 48)
        let b = BcryptPBKDF.derive(passphrase: Array("hunter2".utf8), salt: [1, 2, 3, 4], rounds: 8, keyLength: 48)
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a?.count, 48)
    }

    /// FIPS 180-4 vectors plus the message lengths that exercise every branch of the
    /// padding block (a tail below 112, exactly 112, and one that spills into a
    /// second block). The KDF above only reaches SHA-512 indirectly, so a padding
    /// bug at a length bcrypt never produces would otherwise go unseen.
    func testSHA512KnownAnswers() {
        func hex(_ bytes: [UInt8]) -> String {
            bytes.map { String(format: "%02x", $0) }.joined()
        }
        XCTAssertEqual(
            hex(BcryptPBKDF.sha512([])),
            "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce"
                + "47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e")
        XCTAssertEqual(
            hex(BcryptPBKDF.sha512(Array("abc".utf8))),
            "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
                + "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
        XCTAssertEqual(
            hex(BcryptPBKDF.sha512(Array((
                "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmno"
                    + "ijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu").utf8))),
            "8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018"
                + "501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909")
        XCTAssertEqual(
            hex(BcryptPBKDF.sha512([UInt8](repeating: 0x78, count: 111))),
            "9a2a120825c2319867758ec277924f6faa254968bf752046dacdd948d8ad299b"
                + "10359fd04bfd7d3810b5fa1b16a294236138baff981cbb85248478053ac4d3dd")
        XCTAssertEqual(
            hex(BcryptPBKDF.sha512([UInt8](repeating: 0x78, count: 112))),
            "a3722b515ef40c910f2419f6e0da8ca51d410114ce6272faae64045f9e9f630e"
                + "7fa8dd5a3243c9860b899d148c3da4bc0f9e07454542604d030bb55531fe0d5b")
        XCTAssertEqual(
            hex(BcryptPBKDF.sha512([UInt8](repeating: 0x78, count: 127))),
            "1d5a8893e7b7ed83d485d26f88cfb846f3760279916976fe538e539fc16f7cd1"
                + "9ba3e1c2cd5fda78749a74205755cdf694e8fa90b2bfed8815f406af76c1d7bf")
        XCTAssertEqual(
            hex(BcryptPBKDF.sha512([UInt8](repeating: 0x78, count: 128))),
            "e2e22f8422b54b06e35c3ea30a383d1de7a8fbc27992923074103117020d8dd7"
                + "024c3ecf7d6d1a15a6de5a75ff32fb486b9e8ced4c02ffe05822bf2cb734d0e0")
    }

    func testRejectsInvalidArguments() {
        XCTAssertNil(BcryptPBKDF.derive(passphrase: [], salt: [1], rounds: 4, keyLength: 16))
        XCTAssertNil(BcryptPBKDF.derive(passphrase: [1], salt: [], rounds: 4, keyLength: 16))
        XCTAssertNil(BcryptPBKDF.derive(passphrase: [1], salt: [1], rounds: 0, keyLength: 16))
        XCTAssertNil(BcryptPBKDF.derive(passphrase: [1], salt: [1], rounds: 4, keyLength: 0))
    }
}
