//
//  CategoriesView.swift
//  Budgeter
//
//  Adding, renaming and retiring categories.
//
//  Onboarding tells the user "add, rename or remove them whenever you like", and
//  until this screen existed that was a promise the app did not keep. The starter
//  list is deliberately short (see `CategoryStore.starters`) precisely because it
//  expects to be edited.
//
//  Deleting is a tombstone, not a DELETE (invariant 3), and the copy says so: the
//  money stays in the ledger and in every total, the category simply stops being
//  offered. `CategoryStore.delete` also retires the category's open limit and its
//  merchant rules, because leaving either would keep the category half-alive —
//  silently snapshotting limits into future periods for something the budget screen
//  no longer shows.
//

import GRDB
import SwiftUI

struct CategoriesView: View {
    let database: AppDatabase

    @State private var categories: [CategoryRecord] = []
    @State private var renaming: CategoryRecord?
    @State private var isAdding = false
    @State private var nameField = ""
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(categories, id: \.id) { category in
                    Button {
                        nameField = category.name
                        renaming = category
                    } label: {
                        HStack {
                            Text(category.name).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "pencil").foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: delete)
            } footer: {
                Text("Removing a category leaves your history alone — transactions "
                    + "already in it keep their amounts, and no total changes. It just "
                    + "stops being offered on new entries.")
            }

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Categories")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    nameField = ""
                    isAdding = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add category")
            }
        }
        .alert("New category", isPresented: $isAdding) {
            TextField("Name", text: $nameField)
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                let name = nameField
                write { try CategoryStore().create(name: name, in: $0) }
            }
        }
        .alert("Rename category", isPresented: .init(
            get: { renaming != nil },
<<<<<<< HEAD
            set: { isPresented in
                if !isPresented {
=======
            set: {
                if !$0 {
>>>>>>> 867a6b04bb491937be4316de55c6d9871f9e8c2d
                    renaming = nil
                }
            }
        )) {
            TextField("Name", text: $nameField)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                guard let id = renaming?.id.asUUID else { return }
                let name = nameField
                write { try CategoryStore().rename(id: id, to: name, in: $0) }
            }
        }
        .task { await observe() }
    }

    // MARK: - Actions

    private func observe() async {
        let observation = ValueObservation.tracking { db in try CategoryStore().all(in: db) }
        do {
            for try await rows in observation.values(in: database.writer) {
                categories = rows
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func delete(at offsets: IndexSet) {
        let ids = offsets.compactMap { categories[$0].id.asUUID }
        write { db in
            for id in ids {
                try CategoryStore().delete(id: id, in: db)
            }
        }
    }

    /// One place for "do the write, and put the failure somewhere the user can see
    /// it". Every action on this screen is a single short transaction, so there is
    /// nothing to be gained from each of them growing its own error handling.
    private func write(_ work: @escaping @Sendable (Database) throws -> Void) {
        Task {
            do {
                try await database.writer.write(work)
                errorMessage = nil
            } catch let error as DirectoryError {
                errorMessage = message(for: error)
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }

    private func message(for error: DirectoryError) -> String {
        switch error {
        case .emptyName: "A category needs a name."
        case let .duplicateName(name): "You already have a category called \(name)."
        }
    }
}
