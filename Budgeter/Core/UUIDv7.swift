//
//  UUIDv7.swift
//  Budgeter
//
//  DEC-006 wants UUIDv7 rather than v4: globally unique like v4, but with the
//  creation timestamp in the leading bits, so primary keys sort by creation time
//  and index writes stay local instead of scattering across the B-tree.
//
//  Swift has no first-party UUIDv7, and this is ~30 lines of bit-laying, so it is
//  written here rather than taken as a dependency.
//
//  Layout (RFC 9562 §5.7):
//    bytes 0-5   48-bit big-endian Unix timestamp in milliseconds
//    byte  6     version (0b0111) in the high nibble, random in the low nibble
//    byte  7     random
//    byte  8     variant (0b10) in the high bits, random in the low 6 bits
//    bytes 9-15  random
//

import Foundation

nonisolated enum UUIDv7 {
    /// Builds a UUIDv7 from an explicit timestamp and random source, for tests.
    static func generate(
        millisecondsSinceEpoch milliseconds: Int64,
        using generator: inout some RandomNumberGenerator
    ) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)

        // Bytes 0-5: the low 48 bits of the timestamp, most significant byte first.
        let timestamp = UInt64(bitPattern: milliseconds)
        for offset in 0 ..< 6 {
            let shift = UInt64(8 * (5 - offset))
            bytes[offset] = UInt8((timestamp >> shift) & 0xFF)
        }

        for offset in 6 ..< 16 {
            bytes[offset] = UInt8.random(in: .min ... .max, using: &generator)
        }

        bytes[6] = (bytes[6] & 0x0F) | 0x70 // version 7
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // variant 0b10

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Builds a UUIDv7 for right now.
    static func generate(now: Date = Date()) -> UUID {
        var generator = SystemRandomNumberGenerator()
        let milliseconds = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        return generate(millisecondsSinceEpoch: milliseconds, using: &generator)
    }

    /// Reads back the embedded timestamp. Used by tests, and by any future sync layer
    /// that wants creation order without consulting `created_at`.
    static func timestampMilliseconds(of uuid: UUID) -> Int64 {
        let bytes = uuid.uuid
        let parts: [UInt8] = [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5]
        return parts.reduce(Int64(0)) { accumulated, byte in
            (accumulated << 8) | Int64(byte)
        }
    }
}
