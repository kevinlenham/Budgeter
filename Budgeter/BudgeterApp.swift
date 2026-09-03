//
//  BudgeterApp.swift
//  Budgeter
//
//  Created by Kevin-Le Nham on 1/9/2026.
//

import SwiftUI

@main
struct BudgeterApp: App {
    @State private var model = makeModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }

    /// The database is opened once, here. If it cannot be opened at all, an
    /// in-memory one keeps the app launchable so the failure is visible on screen
    /// rather than as a crash on a phone with no debugger attached.
    private static func makeModel() -> AppModel {
        do {
            return try AppModel.live()
        } catch {
            guard let fallback = try? AppDatabase.inMemory() else {
                fatalError("neither the on-disk nor the in-memory database could be opened")
            }
            return AppModel(database: fallback)
        }
    }
}
