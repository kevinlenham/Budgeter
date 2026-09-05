//
//  OverviewView.swift
//  Budgeter
//
//  The home screen: what you have left, what came in, what went out, and the last
//  few things you logged.
//
//  It answers one question — "am I alright?" — and everything on it is in service
//  of that. Detail lives one tap away in Finances; nothing here is editable except
//  by going somewhere that owns the write.
//
//  The whole screen is one `ValueObservation`. That is not an optimisation: the
//  hero figure, the ring, the income and expense split and the recent list are all
//  views of the same period, and fetching them separately is how the ring ends up a
//  frame out of step with the number inside it.
//

import GRDB
import SwiftUI

struct OverviewView: View {
    let database: AppDatabase

    @Environment(AppModel.self) private var model

    @State private var snapshot = OverviewSnapshot()
    @State private var isAdding = false
    @State private var editing: UUID?
    @State private var isShowingAll = false

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.stackSpacing) {
                    HeroCard(snapshot: snapshot)

                    // DEC-036's fallback card, kept from the old ledger screen and
                    // moved here. It is a question the app is asking, and the home
                    // screen is where a question gets asked — buried in a list it
                    // was easy to scroll straight past.
                    if case let .unlogged(since) = snapshot.payStatus {
                        PayPromptCard(payday: since) { model.isLoggingPay = true }
                    }

                    if snapshot.overall != nil || snapshot.periodDates != nil {
                        PaceTiles(snapshot: snapshot)
                    }

                    recentSection
                }
                .pageInsets()
                .padding(.vertical, 8)
            }
            .screenBackground()
            .navigationTitle("Overview")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { isAdding = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add transaction")
                }
            }
            .navigationDestination(isPresented: $isShowingAll) {
                AllTransactionsView(database: database)
            }
            .sheet(isPresented: $isAdding) {
                TransactionFormView(database: database)
            }
            .sheet(item: $editing) { id in
                TransactionFormView(database: database, editing: id)
            }
            // Both routes into logging pay — the notification's "Log now" and the
            // card above — land on the same empty income form.
            .sheet(isPresented: $model.isLoggingPay) {
                TransactionFormView(database: database, kind: .income)
            }
            .task { await observe() }
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        if snapshot.recent.isEmpty {
            SectionHeader(title: "Recent")
                .padding(.top, 4)
            EmptyStateCard(
                symbol: "tray",
                title: "Nothing logged yet",
                message: "Tap + to add your first transaction."
            )
        } else {
            SectionHeader(title: "Recent", actionLabel: "See all") { isShowingAll = true }
                .padding(.top, 4)
            Card(padding: 8) {
                TransactionList(entries: snapshot.recent, palette: snapshot.palette) { entry in
                    editing = entry.transactionId.asUUID
                }
                .padding(.horizontal, 8)
            }
        }
    }

    private func observe() async {
        let today = CivilDate.today()
        let observation = ValueObservation.tracking { db in
            try OverviewSnapshot(today: today, in: db)
        }
        do {
            for try await value in observation.values(in: database.writer) {
                snapshot = value
            }
        } catch {
            // A failed observation leaves the last good snapshot on screen rather
            // than blanking it. The database failing to read is not something the
            // user can act on from here, and an empty dashboard would imply the
            // much more alarming "you have no money".
        }
    }
}

// MARK: - Snapshot

nonisolated struct OverviewSnapshot: Equatable, Sendable {
    var currency: Currency?
    var cadence: Cadence?
    var periodDates: (start: CivilDate, end: CivilDate)?
    var overall: OverallBudgetLine?
    var income: Money?
    var expenses: Money?
    var recent: [LedgerEntry] = []
    var payStatus: PayStatus = .upToDate
    var palette = CategoryPalette()
    var daysRemaining = 0

    init() {}

    init(today: CivilDate, in db: Database) throws {
        let settings = try BudgetSettingsStore().load(db)
        cadence = settings.schedule?.cadence
        palette = try CategoryPalette.load(db)
        recent = try InsightQueries.recentEntries(limit: 5, in: db)
        payStatus = PayStatus.evaluate(
            paySchedule: settings.paySchedule,
            lastIncomeBookedOn: try Queries.lastIncomeBookedOn(db),
            today: today
        )

        guard let currency = try InsightQueries.primaryCurrency(db) else { return }
        self.currency = currency

        guard let record = try Queries.period(containing: today, in: db),
              let dates = record.dates
        else { return }

        periodDates = dates
        overall = try Queries.overallStatus(periodID: record.id, in: db)
        income = try InsightQueries.income(from: dates.start, to: dates.end, currency: currency, in: db)
        expenses = try InsightQueries.spend(from: dates.start, to: dates.end, currency: currency, in: db)
        daysRemaining = SafeToSpend.daysRemaining(
            in: BudgetPeriod(index: 0, startsOn: dates.start, endsOn: dates.end),
            asOf: today
        )
    }

    /// Equatable by hand: the tuple stops the compiler synthesising it.
    static func == (lhs: OverviewSnapshot, rhs: OverviewSnapshot) -> Bool {
        lhs.currency == rhs.currency
            && lhs.cadence == rhs.cadence
            && lhs.periodDates?.start == rhs.periodDates?.start
            && lhs.periodDates?.end == rhs.periodDates?.end
            && lhs.overall == rhs.overall
            && lhs.income == rhs.income
            && lhs.expenses == rhs.expenses
            && lhs.recent == rhs.recent
            && lhs.payStatus == rhs.payStatus
            && lhs.palette == rhs.palette
            && lhs.daysRemaining == rhs.daysRemaining
    }

    // MARK: - Derived

    /// The headline figure.
    ///
    /// With an overall budget set this is what is left of it — the number the app
    /// exists to keep in front of you. Without one there is no "left", so it falls
    /// back to what the period has actually netted, and the label changes to match
    /// rather than calling a different quantity by the same name.
    var headline: Money? {
        if let remaining = overall?.remaining { return remaining }
        guard let income, let expenses else { return nil }
        return try? income.subtracting(expenses)
    }

    var headlineLabel: String {
        overall == nil ? "Net this period" : "Left to spend"
    }

    var isHealthy: Bool {
        guard let headline else { return true }
        return !headline.isNegative
    }

    var headlineTint: Color {
        isHealthy ? Palette.income : Palette.expense
    }

    /// How much of the budget is gone, for the ring. Without a budget the ring has
    /// nothing to fill against, and the card draws none.
    var fractionSpent: Double? {
        overall?.fractionSpent
    }

    var percentLabel: String? {
        fractionSpent.map { "\(Int(($0 * 100).rounded()))%" }
    }

    /// What can be spent per day for the rest of the period without going over.
    var safeDaily: Money? {
        guard let remaining = overall?.remaining, daysRemaining > 0 else { return nil }
        return try? SafeToSpend.daily(remaining: remaining, daysRemaining: daysRemaining)
    }
}

// MARK: - Cards

/// The card the screen leads with: one big number, the ring behind the budget it
/// belongs to, and the two flows that produced it.
private struct HeroCard: View {
    let snapshot: OverviewSnapshot

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(snapshot.headlineLabel)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Palette.textSecondary)
                            if let percent = snapshot.percentLabel {
                                Pill(text: percent, tint: snapshot.headlineTint)
                            }
                        }

                        AmountText(
                            money: snapshot.headline,
                            font: .system(size: 40, weight: .bold),
                            tint: snapshot.headlineTint
                        )
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    if let fraction = snapshot.fractionSpent {
                        ProgressRing(fraction: fraction, tint: snapshot.headlineTint, size: 62)
                    }
                }

                Rectangle()
                    .fill(Palette.separator)
                    .frame(height: 0.5)

                HStack(spacing: 0) {
                    FlowColumn(
                        label: "Income",
                        symbol: "arrow.up.right",
                        amount: snapshot.income,
                        tint: Palette.income
                    )
                    Rectangle()
                        .fill(Palette.separator)
                        .frame(width: 0.5, height: 34)
                    FlowColumn(
                        label: "Expenses",
                        symbol: "arrow.down.left",
                        amount: snapshot.expenses,
                        tint: Palette.expense
                    )
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FlowColumn: View {
    let label: String
    let symbol: String
    let amount: Money?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(tint)
            AmountText(money: amount, font: .headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 2)
    }
}

/// The pair of small tiles under the hero — the two numbers that turn "you have
/// $340 left" into something actionable.
private struct PaceTiles: View {
    let snapshot: OverviewSnapshot

    var body: some View {
        HStack(spacing: Metrics.stackSpacing) {
            TintedCard(tint: Palette.warning) {
                VStack(alignment: .leading, spacing: 10) {
                    IconTile(symbol: "gauge.medium", tint: Palette.warning, size: 36)
                    Text("Safe per day")
                        .font(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                    AmountText(money: snapshot.safeDaily, font: .title3.weight(.bold))
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
            }

            TintedCard(tint: Palette.accent) {
                VStack(alignment: .leading, spacing: 10) {
                    IconTile(symbol: "calendar", tint: Palette.accent, size: 36)
                    Text("Days left")
                        .font(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                    Text("\(snapshot.daysRemaining)")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(Palette.textPrimary)
                }
            }
        }
    }
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
        TintedCard(tint: Palette.warning) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    IconTile(symbol: "calendar.badge.clock", tint: Palette.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Payday has been and gone")
                            .font(.headline)
                            .foregroundStyle(Palette.textPrimary)
                        Text("Nothing logged since \(payday.middayDate().formatted(.dateTime.day().month(.wide))).")
                            .font(.subheadline)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                Button("Log what you were paid", action: onLog)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Palette.warning.opacity(0.22), in: .capsule)
                    .foregroundStyle(Palette.warning)
            }
        }
    }
}
