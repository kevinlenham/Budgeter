//
//  AllTransactionsView.swift
//  Budgeter
//
//  The archive: everything ever logged, grouped by the day it was booked on.
//
//  Reached from the Overview's "See all" rather than from a tab, because a list of
//  every transaction you have ever made is something you go looking for once in a
//  while, not something you open the app to read.
//
//  Grouped by `booked_on` rather than by `occurred_at`, which is the DEC-009
//  distinction made visible: the day heading is the day the user says the purchase
//  happened, not the instant the device recorded it.
//

import GRDB
import SwiftUI

/// Everything ever logged, for the Overview's "See all".
///
/// Deliberately not a tab: this is the archive, reached when you are looking for
/// one specific thing, not the screen you open to see how you are doing.
struct AllTransactionsView: View {
    let database: AppDatabase

    @State private var entries: [LedgerEntry] = []
    @State private var palette = CategoryPalette()
    @State private var editing: UUID?

    private var days: [(day: String, entries: [LedgerEntry])] {
        let grouped = Dictionary(grouping: entries, by: \.bookedOn)
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.stackSpacing, pinnedViews: []) {
                ForEach(days, id: \.day) { day in
                    SectionHeader(title: dayTitle(day.day))
                    Card(padding: 8) {
                        TransactionList(entries: day.entries, palette: palette) { entry in
                            editing = entry.transactionId.asUUID
                        }
                        .padding(.horizontal, 8)
                    }
                }
            }
            .pageInsets()
            .padding(.vertical, 8)
        }
        .screenBackground()
        .navigationTitle("All transactions")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { id in
            TransactionFormView(database: database, editing: id)
        }
        .task { await observe() }
    }

    private func observe() async {
        let observation = ValueObservation.tracking { db in
            AllTransactionsSnapshot(
                entries: try Queries.ledger(db),
                palette: try CategoryPalette.load(db)
            )
        }
        do {
            for try await value in observation.values(in: database.writer) {
                entries = value.entries
                palette = value.palette
            }
        } catch {}
    }

    /// "Today", "Yesterday", or the written date — the three a person reads without
    /// having to work anything out.
    private func dayTitle(_ iso: String) -> String {
        guard let date = CivilDate(iso: iso) else { return iso }
        switch date.days(until: .today()) {
        case 0: return "Today"
        case 1: return "Yesterday"
        default: return date.middayDate().formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
    }
}

nonisolated struct AllTransactionsSnapshot: Equatable, Sendable {
    var entries: [LedgerEntry]
    var palette: CategoryPalette
}
