//
//  StatisticsView.swift
//  Budgeter
//
//  Three questions, three charts: where the money went, whether more came in than
//  went out, and whether this period is running ahead of its budget.
//
//  Everything here is read-only and everything is drawn from the same views the
//  rest of the app uses, so a figure on this screen can never disagree with the
//  same figure on Finances.
//
//  Colour rules, because charts are where they matter most:
//
//  * Category colours come from `CategoryPalette`, which assigns them by identity
//    and not by rank — a category keeps its hue when it stops being the biggest
//    line. The ramp is validated for colour-vision separation and for contrast
//    against the card surface in both themes.
//  * Nothing is identified by colour alone. The donut is paired with a ranked list
//    that names and labels every slice, and the burn chart carries a written
//    legend.
//  * Green and red keep the meanings they have everywhere else — money in, money
//    out — and are never borrowed as chart series colours for anything else.
//

import Charts
import GRDB
import SwiftUI

struct StatisticsView: View {
    let database: AppDatabase

    @State private var snapshot = StatisticsSnapshot()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.stackSpacing) {
                    if let title = snapshot.periodTitle {
                        Text(title)
                            .font(.subheadline)
                            .foregroundStyle(Palette.textSecondary)
                    }

                    SectionHeader(title: "Where it went")
                    CategoryBreakdownCard(snapshot: snapshot)

                    SectionHeader(title: "In and out").padding(.top, 4)
                    FlowCard(flows: snapshot.flows)

                    SectionHeader(title: "Pace").padding(.top, 4)
                    BurnCard(points: snapshot.burn, hasBudget: snapshot.hasBudget)
                }
                .pageInsets()
                .padding(.vertical, 8)
            }
            .screenBackground()
            .navigationTitle("Statistics")
            .task { await observe() }
        }
    }

    private func observe() async {
        let today = CivilDate.today()
        let observation = ValueObservation.tracking { db in
            try StatisticsSnapshot(today: today, in: db)
        }
        do {
            for try await value in observation.values(in: database.writer) {
                snapshot = value
            }
        } catch {}
    }
}

// MARK: - Snapshot

nonisolated struct StatisticsSnapshot: Equatable, Sendable {
    var currency: Currency?
    var cadence: Cadence?
    var periodTitle: String?
    var categories: [CategorySpend] = []
    var palette = CategoryPalette()
    var flows: [PeriodFlow] = []
    var burn: [BurnPoint] = []
    var hasBudget = false

    init() {}

    init(today: CivilDate, in db: Database) throws {
        let settings = try BudgetSettingsStore().load(db)
        cadence = settings.schedule?.cadence
        palette = try CategoryPalette.load(db)

        guard let currency = try InsightQueries.primaryCurrency(db) else { return }
        self.currency = currency

        // Six periods is roughly three months on a fortnightly budget and half a
        // year on a monthly one — long enough to show a trend, short enough that
        // the bars stay wide enough to read on a phone.
        flows = try InsightQueries.flows(periods: 6, upTo: today, currency: currency, in: db)

        guard let record = try Queries.period(containing: today, in: db),
              let dates = record.dates
        else { return }

        periodTitle = "\(dates.start.middayDate().formatted(.dateTime.day().month(.abbreviated)))"
            + " – \(dates.end.middayDate().formatted(.dateTime.day().month(.abbreviated)))"
        categories = try InsightQueries.categorySpend(
            from: dates.start,
            to: dates.end,
            currency: currency,
            in: db
        )

        let limit = try Queries.overallStatus(periodID: record.id, in: db)?.limit
        hasBudget = limit != nil
        burn = try InsightQueries.burn(
            in: dates,
            limit: limit,
            currency: currency,
            today: today,
            in: db
        )
    }

    var total: Money? {
        guard let currency else { return nil }
        return Money(
            minorUnits: categories.reduce(Int64(0)) { $0 + $1.amountMinor },
            currency: currency
        )
    }

    func share(of row: CategorySpend) -> Double {
        let total = categories.reduce(Int64(0)) { $0 + $1.amountMinor }
        guard total > 0 else { return 0 }
        return Double(row.amountMinor) / Double(total)
    }
}
