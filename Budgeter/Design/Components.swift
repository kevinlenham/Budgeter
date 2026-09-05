//
//  Components.swift
//  Budgeter
//
//  The vocabulary every screen is built from: a card, a tinted card, a section
//  heading, an icon tile, a ring, a bar, a pill, an empty state.
//
//  These exist so that "make the cards a bit rounder" is one edit rather than
//  forty, and so two screens cannot drift into two different ideas of what a card
//  is. Nothing here knows anything about budgets — they take a tint and some
//  content and draw it. The meaning is supplied by the caller, which is what keeps
//  the semantic roles in `Palette` honest.
//

import SwiftUI

// MARK: - Metrics

nonisolated enum Metrics {
    static let cardRadius: CGFloat = 20
    static let tileRadius: CGFloat = 12
    static let cardPadding: CGFloat = 16
    /// The gap between cards, and the page side margin — the same number, so
    /// vertical and horizontal rhythm match.
    static let gutter: CGFloat = 16
    static let stackSpacing: CGFloat = 14
}

// MARK: - Surfaces

/// The page ground. Applied once per screen, behind a scroll view.
struct ScreenBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Palette.background.ignoresSafeArea())
            .scrollContentBackground(.hidden)
    }
}

/// A plain card: content on `surface`, rounded, padded.
struct Card<Content: View>: View {
    var padding: CGFloat = Metrics.cardPadding
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: .rect(cornerRadius: Metrics.cardRadius))
    }
}

/// A card that carries a meaning, shown as a wash of that meaning colour.
///
/// The wash is heavier in dark mode than in light: the same alpha over charcoal
/// reads as almost nothing, while over white it reads as a highlighter. Two
/// numbers rather than one is the price of the tint meaning the same amount in
/// both themes.
struct TintedCard<Content: View>: View {
    let tint: Color
    var padding: CGFloat = Metrics.cardPadding
    @ViewBuilder var content: Content

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(scheme == .dark ? 0.16 : 0.10), in: .rect(cornerRadius: Metrics.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.cardRadius)
                    .strokeBorder(tint.opacity(scheme == .dark ? 0.34 : 0.22), lineWidth: 1)
            }
    }
}

// MARK: - Pieces

/// The heading above a group of cards. Not a `Section` header: this layout is a
/// scroll view of cards, and the stock header inset and capitalisation both fight
/// it.
struct SectionHeader: View {
    let title: String
    var actionLabel: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(Palette.textPrimary)
            Spacer()
            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Palette.accent)
            }
        }
    }
}

/// The outlined glyph square from the reference layouts — a rounded rect stroked
/// in the tint, with the tinted symbol inside.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 40

    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.tileRadius)
            .strokeBorder(tint.opacity(0.7), lineWidth: 1.5)
            .background(tint.opacity(0.12), in: .rect(cornerRadius: Metrics.tileRadius))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(tint)
            }
    }
}

/// A small capsule label — "0%", "Draft", "Over".
struct Pill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.18), in: .capsule)
    }
}

/// The concentric ring from the reference layouts: a full track, and an arc over
/// it for the fraction used.
///
/// The fraction is clamped to one, so an overspend draws a complete ring in the
/// overspend colour and the number beside it says by how much. A ring that wound
/// past 100% would be read as "nearly done".
struct ProgressRing: View {
    let fraction: Double
    let tint: Color
    var size: CGFloat = 56
    var thickness: CGFloat = 7

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.22), lineWidth: thickness)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: thickness, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A horizontal version of the same idea, for rows where a ring would be too big.
struct ProgressBar: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.20))
                Capsule()
                    .fill(tint)
                    .frame(width: geometry.size.width * max(0, min(1, fraction)))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// The two-line "no data yet" block, in the card idiom rather than the stock
/// `ContentUnavailableView`, which draws its own full-screen background.
struct EmptyStateCard: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        Card {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Palette.textTertiary)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Palette.textPrimary)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }
}

// MARK: - Money

/// An amount, in the one type treatment used everywhere money appears.
///
/// Monospaced digits are not decoration here: these numbers sit in vertical lists
/// and in figures that change as the user types, and proportional digits make both
/// jitter.
struct AmountText: View {
    let money: Money?
    var font: Font = .body
    var tint: Color?

    var body: some View {
        Text(money.map { MoneyText.string(from: $0) } ?? "—")
            .font(font.monospacedDigit())
            .foregroundStyle(tint ?? Palette.textPrimary)
    }
}

/// The theme applied to a stock `Form` or `List`.
///
/// The settings sub-screens are genuine forms — text fields, toggles, pickers,
/// swipe-to-delete — and the platform's own list is better at all four than a stack
/// of cards pretending to be one. So they keep the native control and take the
/// palette instead: the page ground, the card colour behind each row, the separator
/// and the accent. The result reads as part of the same app without giving up the
/// behaviour a form is supposed to have.
struct ThemedForm: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Palette.background.ignoresSafeArea())
            .tint(Palette.accent)
    }
    // Row fills are left to the platform deliberately. The grouped-list row colour
    // is within a point or two of `Palette.surface` in both themes, so overriding
    // it per row would buy nothing and would cost the selection and swipe
    // highlights that come with the stock background.
}

// Not `nonisolated`: these build `ViewModifier` values, which are MainActor under
// this target's default isolation, and they are only ever called from a view body.
extension View {
    func screenBackground() -> some View {
        modifier(ScreenBackground())
    }

    /// See `ThemedForm` for why the sub-screens keep a native list.
    func themedForm() -> some View {
        modifier(ThemedForm())
    }

    /// Standard page padding for the card-stack layout.
    func pageInsets() -> some View {
        padding(.horizontal, Metrics.gutter)
    }
}
