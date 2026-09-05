//
//  ThemePreference.swift
//  Budgeter
//
//  Which theme the app draws in, and where that choice is kept.
//
//  The default is dark rather than `.system`, which is a deliberate departure from
//  the platform norm: this app is opened in the evening, at a checkout, in a car —
//  and a white flash is the wrong thing to hand someone in any of those. Following
//  the system is offered, it is just not what a fresh install does.
//
//  `AppStorage` rather than the database: this is a device preference, not budget
//  data. It should not travel in an export and it has no business being restored
//  onto a different phone.
//

import SwiftUI

nonisolated enum ThemePreference: String, CaseIterable, Identifiable, Sendable {
    case dark
    case light
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .system: "System"
        }
    }

    var symbol: String {
        switch self {
        case .dark: "moon.fill"
        case .light: "sun.max.fill"
        case .system: "iphone"
        }
    }

    /// `nil` means "whatever the system is doing" — which is what
    /// `preferredColorScheme` already takes to mean exactly that.
    var colorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }
}

/// The stored preference, in one place so the key string is written once.
nonisolated enum ThemeStore {
    static let key = "themePreference"
}
