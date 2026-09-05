//
//  Palette.swift
//  Budgeter
//
//  Every colour the app draws, named by the job it does rather than by the hue it
//  happens to be. A screen asks for `Palette.income`, never for "green", so the day
//  income stops being green there is one line to change instead of thirty.
//
//  Both themes are *selected*, not derived. Dark is not light with the lightness
//  flipped: each token carries its own pair, because a green that reads correctly on
//  white is not the green that reads correctly on charcoal. The dark ground is a
//  lifted near-black rather than #000 — cards a shade above it separate by their own
//  fill, so the layout needs no borders to be legible.
//
//  The `series` ramp is the one set of colours here that was not chosen by eye. It
//  is the data-visualisation categorical palette, validated for colour-vision
//  deficiency separation and contrast against these exact card surfaces; see
//  `Statistics` for the labelling rules that come with it.
//

import SwiftUI
import UIKit

nonisolated enum Palette {
    // MARK: - Surfaces

    /// The page behind everything. Lifted off pure black so card edges read.
    static let background = Color(light: 0xF4F5F7, dark: 0x121316)

    /// A card sitting on `background`.
    static let surface = Color(light: 0xFFFFFF, dark: 0x1C1E22)

    /// A card sitting on `surface` — a row inside a card, a pressed state.
    static let surfaceElevated = Color(light: 0xF0F1F4, dark: 0x24272C)

    /// Hairlines and dividers. Never used for text.
    static let separator = Color(light: 0xD9DBE0, dark: 0x2E3238)

    // MARK: - Ink

    static let textPrimary = Color(light: 0x111214, dark: 0xF2F3F5)
    static let textSecondary = Color(light: 0x5C6069, dark: 0x9BA1AC)
    static let textTertiary = Color(light: 0x8B909A, dark: 0x6B7280)

    // MARK: - Semantic roles
    //
    // These four carry meaning and are never reused as decoration. Money in is
    // green wherever it appears; a category tile does not get to borrow it.

    /// Accounts, navigation, anything neutral that still needs to be tappable.
    static let accent = Color(light: 0x0A6CE0, dark: 0x3B96FF)

    /// Money in, and being comfortably inside a limit.
    static let income = Color(light: 0x1B7F3B, dark: 0x38D965)

    /// Money out, and being over a limit.
    static let expense = Color(light: 0xC81E1E, dark: 0xFF5B52)

    /// Due soon, close to a limit, needs attention but is not yet wrong.
    static let warning = Color(light: 0xA35A00, dark: 0xFFA733)

    // MARK: - Charts

    /// The categorical ramp for spending-by-category, in fixed slot order.
    ///
    /// Assigned by position and never cycled: slot 7 onwards folds into "Other"
    /// rather than wrapping back to slot 1, because a colour that means two
    /// different categories in one chart means nothing. Validated for CVD
    /// separation and for contrast against `surface` in both themes.
    static let series: [Color] = [
        Color(light: 0x2A78D6, dark: 0x3987E5), // blue
        Color(light: 0xEB6834, dark: 0xD95926), // orange
        Color(light: 0x1BAF7A, dark: 0x199E70), // aqua
        Color(light: 0xEDA100, dark: 0xC98500), // yellow
        Color(light: 0xE87BA4, dark: 0xD55181), // magenta
        Color(light: 0x008300, dark: 0x008300), // green
    ]

    /// Anything past the ramp. Deliberately a grey: "Other" is a residual, and
    /// giving it a hue would make it look like a category of its own.
    static let seriesOther = Color(light: 0x8B909A, dark: 0x6B7280)

    /// The colour for slot `index`, folding into `seriesOther` past the ramp.
    static func series(_ index: Int) -> Color {
        index < series.count ? series[index] : seriesOther
    }
}

nonisolated extension Color {
    /// A colour that resolves per theme.
    ///
    /// Built on `UIColor`'s dynamic provider rather than an asset catalogue entry,
    /// so the whole palette is one readable file that diffs in review, instead of
    /// forty JSON folders that do not.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

nonisolated extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
