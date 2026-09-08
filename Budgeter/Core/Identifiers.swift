//
//  Identifiers.swift
//  Budgeter
//
//  Two conveniences for moving between the string ids the database stores and the
//  `UUID`s the app works in.
//
//  They lived in the old ledger screen, which is a strange home for something four
//  other screens use. They are here now so that deleting a view cannot take them
//  with it.
//

import Foundation

/// `sheet(item:)` needs an `Identifiable`, and a bare `UUID` is not one.
extension UUID: @retroactive Identifiable {
    public var id: UUID {
        self
    }
}

nonisolated extension String {
    /// The string as a `UUID`, or nil if it is not one. Ids come out of SQLite as
    /// text, and every screen that wants to hand one back to a store needs this.
    var asUUID: UUID? {
        UUID(uuidString: self)
    }
}
