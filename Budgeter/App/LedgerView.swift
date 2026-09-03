//
//  LedgerView.swift
//  Budgeter
//
//  The list of what happened, newest first, grouped by the day it was booked on.
//
//  Grouped by `booked_on` rather than by `occurred_at`, which is the DEC-009
//  distinction made visible: the day heading is the day the user says the purchase
//  happened, not the instant the device recorded it.
//
//  Driven by GRDB's `ValueObservation`, so a save anywhere in the app — this screen,
//  the budget screen, a future import — redraws the list without anything having to
//  remember to tell it.
//

import GRDB
import SwiftUI

struct LedgerView: View {
    let database: AppDatabase

    @State private var entries: [LedgerEntry] = []
    @State private var isAdding = false
    @State private var editing: UUID?

    private var days: [(day: String, entries: [LedgerEntry])] {
        let grouped = Dictionary(grouping: entries, by: \.bookedOn)
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "Nothing logged yet",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Tap + to add your first transaction.")
                    )
                } else {
                    List {
                        ForEach(days, id: \.day) { day in
                            Section(dayTitle(day.day)) {
                                ForEach(day.entries) { entry in
                                    Button { editing = entry.transactionId.asUUID } label: {
                                        LedgerRow(entry: entry)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Ledger")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { isAdding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add transaction")
                }
            }
            .sheet(isPresented: $isAdding) {
                TransactionFormView(database: database)
            }
            .sheet(item: $editing) { id in
                TransactionFormView(database: database, editing: id)
            }
            .task { await observe() }
        }
    }

    private func observe() async {
        let observation = ValueObservation.tracking(Queries.ledger)
        do {
            for try await rows in observation.values(in: database.writer) {
                entries = rows
            }
        } catch {
            entries = []
        }
    }

    /// "Today", "Yesterday", or the written date — the three a person reads without
    /// having to work anything out.
    private func dayTitle(_ iso: String) -> String {
        guard let date = CivilDate(iso: iso) else { return iso }
        let today = CivilDate.today()
        switch date.days(until: today) {
        case 0: return "Today"
        case 1: return "Yesterday"
        default: return date.middayDate().formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
    }
}

struct LedgerRow: View {
    let entry: LedgerEntry

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.merchant ?? entry.categoryName ?? "—")
                    .font(.body)
                HStack(spacing: 6) {
                    if let category = entry.categoryName {
                        Text(category)
                    }
                    if entry.isDraft {
                        Text("Draft")
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let amount = entry.amount {
                Text(MoneyText.string(from: amount))
                    .font(.body.monospacedDigit())
                    // Money in is worth picking out of a list of money going out.
                    .foregroundStyle(amount.isNegative ? Color.primary : Color.green)
            }
        }
        .padding(.vertical, 2)
    }
}

/// `sheet(item:)` needs an `Identifiable`, and a bare `UUID` is not one.
extension UUID: @retroactive Identifiable {
    public var id: UUID {
        self
    }
}

extension String {
    var asUUID: UUID? {
        UUID(uuidString: self)
    }
}
