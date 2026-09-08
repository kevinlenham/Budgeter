//
//  SettingsView.swift
//  Budgeter
//
//  The fourth tab, and the answer to a gap Sprint 3 left open: once onboarding had
//  run there was no way to change any of its answers. A budget period anchored on
//  the wrong payday, or a category named wrong on the first day, was permanent.
//
//  Everything here is a door to a screen that owns its own writes, with one
//  exception: the appearance control, which writes a device preference rather than
//  budget data and so has nowhere else to live.
//
//  The summaries all come from `AppModel.settings` — one read, refreshed when a
//  child screen says something changed.
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @AppStorage(ThemeStore.key) private var theme = ThemePreference.dark

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.stackSpacing) {
                    SectionHeader(title: "Appearance")
                    appearanceCard

                    SectionHeader(title: "Budget").padding(.top, 4)
                    Card(padding: 0) {
                        VStack(spacing: 0) {
                            NavigationRow(
                                symbol: "calendar",
                                tint: Palette.accent,
                                title: "Budget period",
                                detail: cadenceSummary
                            ) {
                                CadenceSwitchView(
                                    database: model.database,
                                    current: model.settings.schedule?.cadence ?? .fortnightly,
                                    // A full restart rather than a settings re-read:
                                    // a switch changes where future boundaries fall,
                                    // and `start()` is what generates periods against
                                    // the new schedule.
                                    onSwitched: { Task { await model.start() } }
                                )
                            }
                            RowDivider()
                            NavigationRow(
                                symbol: "banknote",
                                tint: Palette.income,
                                title: "Payday",
                                detail: paydaySummary
                            ) {
                                PayReminderView()
                            }
                        }
                    }

                    SectionHeader(title: "Categorising").padding(.top, 4)
                    Card(padding: 0) {
                        VStack(spacing: 0) {
                            NavigationRow(
                                symbol: "square.grid.2x2",
                                tint: Palette.series(0),
                                title: "Categories",
                                detail: nil
                            ) {
                                CategoriesView(database: model.database)
                            }
                            RowDivider()
                            NavigationRow(
                                symbol: "storefront",
                                tint: Palette.series(1),
                                title: "Remembered merchants",
                                detail: nil
                            ) {
                                MerchantRulesView(database: model.database)
                            }
                        }
                    }

                    SectionHeader(title: "Your data").padding(.top, 4)
                    Card(padding: 0) {
                        NavigationRow(
                            symbol: "arrow.up.doc",
                            tint: Palette.warning,
                            title: "Export and restore",
                            detail: nil
                        ) {
                            ExportView(database: model.database)
                        }
                    }

                    Text("Budgeter keeps everything on this device and sends nothing anywhere. "
                        + "That makes an export the only copy that survives losing the phone, "
                        + "so it is worth taking one occasionally.")
                        .font(.footnote)
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, 4)
                }
                .pageInsets()
                .padding(.vertical, 8)
            }
            .screenBackground()
            .navigationTitle("Settings")
        }
        .task { await model.reloadSettings() }
    }

    /// Three explicit choices rather than a single dark-mode switch, because
    /// "follow the system" is a real preference and a two-state toggle cannot
    /// express it.
    private var appearanceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Appearance", selection: $theme) {
                    ForEach(ThemePreference.allCases) { option in
                        Label(option.title, systemImage: option.symbol).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                Text(theme == .system
                    ? "Following your device setting."
                    : "Always \(theme.title.lowercased()), whatever the device is set to.")
                    .font(.footnote)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private var cadenceSummary: String {
        model.settings.schedule?.cadence.title ?? "Not set"
    }

    private var paydaySummary: String {
        guard let schedule = model.settings.paySchedule else { return "Not set" }
        guard model.settings.payReminderEnabled else { return schedule.cadence.title }
        return "\(schedule.cadence.title), reminder on"
    }
}

// MARK: - Rows

/// A row that pushes a screen, in the card idiom: icon tile, title, current value,
/// chevron.
struct NavigationRow<Destination: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String?
    @ViewBuilder var destination: Destination

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: 12) {
                IconTile(symbol: symbol, tint: tint, size: 34)
                Text(title)
                    .font(.body)
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.textTertiary)
            }
            .padding(.horizontal, Metrics.cardPadding)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// The hairline between two rows inside one card, inset past the icon tile so it
/// reads as a separator rather than as a line across the card.
struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Palette.separator)
            .frame(height: 0.5)
            .padding(.leading, Metrics.cardPadding + 34 + 12)
    }
}
