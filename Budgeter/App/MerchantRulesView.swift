//
//  MerchantRulesView.swift
//  Budgeter
//
//  DEC-030 requires that "the user can view and edit the rules", and that is not a
//  nicety — it is half of why the merchant memory was chosen over a Core ML
//  classifier. A rule that guesses wrong is one the user can find, read and change.
//  An embedding that guesses wrong is a shrug.
//
//  Nothing here is a guess about the guess: each row shows the merchant string the
//  rule was learned from and the category it currently points at. Repointing a rule
//  resets its hit count, because "how often was the standing guess right" stops
//  being a meaningful number the moment the guess changes.
//

import GRDB
import SwiftUI

struct MerchantRulesView: View {
    let database: AppDatabase

    @State private var rules: [MerchantRuleListing] = []
    @State private var categories: [CategoryRecord] = []
    @State private var errorMessage: String?

    var body: some View {
        List {
            if rules.isEmpty {
                Section {
                    ContentUnavailableView(
                        "Nothing remembered yet",
                        systemImage: "wand.and.stars",
                        description: Text("When you categorise a purchase, Budgeter remembers "
                            + "the shop and suggests the same category next time.")
                    )
                }
            }

            ForEach(rules) { rule in
                Picker(selection: binding(for: rule)) {
                    ForEach(categories, id: \.id) { category in
                        Text(category.name).tag(category.id)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.displayName)
                        if rule.hitCount > 0 {
                            Text(rule.hitCount == 1 ? "1 confirmation" : "\(rule.hitCount) confirmations")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .onDelete(perform: delete)

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Merchants")
        .task { await observe() }
    }

    // MARK: - Actions

    /// The picker writes straight through to the database, which is why there is no
    /// local copy of the selection to fall out of step with it. The observation
    /// below then redraws the row from what was actually stored.
    private func binding(for rule: MerchantRuleListing) -> Binding<String> {
        Binding(
            get: { rule.categoryId },
            set: { newValue in
                guard let id = rule.id.asUUID, let category = newValue.asUUID else { return }
                write { try MerchantRules().update(id: id, categoryID: category, in: $0) }
            }
        )
    }

    private func observe() async {
        let observation = ValueObservation.tracking { db in
            (try MerchantRules().all(in: db), try CategoryStore().all(in: db))
        }
        do {
            for try await (loadedRules, loadedCategories) in observation.values(in: database.writer) {
                rules = loadedRules
                categories = loadedCategories
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func delete(at offsets: IndexSet) {
        let ids = offsets.compactMap { rules[$0].id.asUUID }
        write { db in
            for id in ids {
                try MerchantRules().delete(id: id, in: db)
            }
        }
    }

    private func write(_ work: @escaping @Sendable (Database) throws -> Void) {
        Task {
            do {
                try await database.writer.write(work)
                errorMessage = nil
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }
}
