//
//  UUIDv7Tests.swift
//  BudgeterTests
//
//  DEC-006 wants v7 specifically for the timestamp ordering, so the ordering is
//  what gets tested — not merely that the function returns a UUID.
//

import Foundation
import Testing
@testable import Budgeter

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("UUIDv7")
struct UUIDv7Tests {
    @Test("carries version 7 and the RFC 9562 variant bits")
    func versionAndVariant() {
        var generator = SeededGenerator(seed: 42)
        for _ in 0 ..< 200 {
            let uuid = UUIDv7.generate(millisecondsSinceEpoch: 1_756_000_000_000, using: &generator)
            let bytes = uuid.uuid

            #expect(bytes.6 & 0xF0 == 0x70, "version nibble should be 7")
            #expect(bytes.8 & 0xC0 == 0x80, "variant bits should be 0b10")
        }
    }

    @Test("the embedded timestamp round-trips")
    func timestampRoundTrips() {
        var generator = SeededGenerator(seed: 7)
        for milliseconds in stride(from: Int64(0), to: 5_000_000_000_000, by: 811_111_111) {
            let uuid = UUIDv7.generate(millisecondsSinceEpoch: milliseconds, using: &generator)
            #expect(UUIDv7.timestampMilliseconds(of: uuid) == milliseconds)
        }
    }

    @Test("later timestamps sort after earlier ones — the property DEC-006 wants")
    func sortsByCreationTime() {
        var generator = SeededGenerator(seed: 99)
        var uuids: [UUID] = []
        for step in 0 ..< 500 {
            let milliseconds = 1_756_000_000_000 + Int64(step)
            uuids.append(UUIDv7.generate(millisecondsSinceEpoch: milliseconds, using: &generator))
        }

        // Lexicographic order of the string form must match creation order, because
        // that is the form stored in the `id` column and used by the index.
        let strings = uuids.map(\.uuidString)
        #expect(strings == strings.sorted())
    }

    @Test("uuids generated in the same millisecond are still distinct")
    func distinctWithinAMillisecond() {
        var generator = SeededGenerator(seed: 123)
        let uuids = (0 ..< 1000).map { _ in
            UUIDv7.generate(millisecondsSinceEpoch: 1_756_000_000_000, using: &generator)
        }
        #expect(Set(uuids).count == uuids.count)
    }

    @Test("the live generator produces sane, current timestamps")
    func liveGeneratorUsesNow() {
        let before = Date().timeIntervalSince1970 * 1000
        let uuid = UUIDv7.generate()
        let after = Date().timeIntervalSince1970 * 1000

        let embedded = Double(UUIDv7.timestampMilliseconds(of: uuid))
        #expect(embedded >= before - 1000)
        #expect(embedded <= after + 1000)
    }
}
