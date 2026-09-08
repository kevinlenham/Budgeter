//
//  CategoryPalette.swift
//  Budgeter
//
//  Which colour each category is drawn in, and — more importantly — the guarantee
//  that it is the *same* colour every time.
//
//  The rule this exists to keep is that colour follows the category, never its
//  rank. If Groceries is slot 2 it is slot 2 in the donut, in the breakdown list
//  and in next month's chart, whether it was the largest line or the smallest. A
//  palette assigned by "biggest first" repaints every category the moment spending
//  shifts, which turns the one thing a colour is for — recognition — into noise.
//
//  Stability comes from creation order rather than from name order, because names
//  are editable and a rename would otherwise recolour a category the user thinks of
//  as unchanged.
//
//  The ramp has six slots. Categories past the sixth share the neutral "Other"
//  grey: the alternative is generating hues, and a seventh invented colour is one
//  that has not been checked for colour-vision separation against the other six.
//

import GRDB
import SwiftUI

nonisolated struct CategoryPalette: Equatable, Sendable {
    /// Category id to ramp slot. Absent means "past the ramp" — the neutral grey.
    private var slots: [String: Int]

    init(slots: [String: Int] = [:]) {
        self.slots = slots
    }

    /// Builds the map from the categories that exist, oldest first.
    init(categoriesOldestFirst ids: [String]) {
        slots = Dictionary(
            uniqueKeysWithValues: ids.prefix(Palette.series.count).enumerated().map { ($1, $0) }
        )
    }

    /// Reads the category list in creation order and builds the map.
    static func load(_ db: Database) throws -> CategoryPalette {
        let ids = try String.fetchAll(db, sql: """
        SELECT id FROM categories
         WHERE deleted_at IS NULL
         ORDER BY created_at, id
        """)
        return CategoryPalette(categoriesOldestFirst: ids)
    }

    /// The colour for a category. Uncategorised spending and anything past the
    /// ramp both come back neutral, which is correct for both: neither is an
    /// identity worth learning a hue for.
    func color(for categoryId: String?) -> Color {
        guard let categoryId, let slot = slots[categoryId] else { return Palette.seriesOther }
        return Palette.series(slot)
    }
}
