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

    @Environment(AppModel.self) private var model

    @State private var entries: [LedgerEntry] = []
    @State private var payStatus: PayStatus = .upToDate
    @State private var isAdding = false
    @State private var editing: UUID?

    private var days: [(day: String, entries: [LedgerEntry])] {
        let grouped = Dictionary(grouping: entries, by: \.bookedOn)
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            List {
                // DEC-036's fallback card. Shown regardless of notification
                // permission, because it is the only thing standing between a
                // prompt the user declined and a feature that silently does
                // nothing. Pinned above the ledger rather than folded into it: it
                // is a question, not a transaction.
                if case let .unlogged(since) = payStatus {
                    Section {
                        PayPromptCard(payday: since) { model.isLoggingPay = true }
                    }
                }

                if entries.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "Nothing logged yet",
                            systemImage: "list.bullet.rectangle",
                            description: Text("Tap + to add your first transaction.")
                        )
                    }
                }

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
            // DEC-036: "tapping opens a blank income entry form; nothing is written
            // until the user saves." Both routes into it — the notification's "Log
            // now" and the card above — land here, on an empty form.
            .sheet(isPresented: $model.isLoggingPay) {
                TransactionFormView(database: database, kind: .income)
            }
            .task { await observe() }
        }
    }

    /// One observation for both the list and the pay card, so they cannot be a
    /// frame out of step — logging a payday must make the card disappear in the
    /// same redraw that puts the row in the list.
    private func observe() async {
        let today = CivilDate.today()
        let observation = ValueObservation.tracking { db in
            LedgerSnapshot(
                entries: try Queries.ledger(db),
                payStatus: PayStatus.evaluate(
                    paySchedule: try BudgetSettingsStore().load(db).paySchedule,
                    lastIncomeBookedOn: try Queries.lastIncomeBookedOn(db),
                    today: today
                )
            )
        }
        do {
            for try await snapshot in observation.values(in: database.writer) {
                entries = snapshot.entries
                payStatus = snapshot.payStatus
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

/// Everything the ledger screen draws, in one fetch.
nonisolated struct LedgerSnapshot: Equatable, Sendable {
    var entries: [LedgerEntry]
    var payStatus: PayStatus
}

/// DEC-036's card: "no pay logged since 14 March".
///
/// It names the payday and asks; it never states an amount, and it offers no way
/// to accept a figure the app made up, because there is no figure. Pay varies, and
/// DEC-012's argument applies here with less excuse than it does to capture drafts:
/// a projected salary comes from nothing at all.
struct PayPromptCard: View {
    let payday: CivilDate
    let onLog: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Payday has been and gone", systemImage: "calendar.badge.clock")
                .font(.headline)
            Text("Nothing logged since \(payday.middayDate().formatted(.dateTime.day().month(.wide))).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Log what you were paid", action: onLog)
                .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 4)
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
