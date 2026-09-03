//
//  TransactionFormView.swift
//  Budgeter
//
//  One form for adding and editing, and one form for expenses and income (DEC-035):
//  income is the same shape minus a category, so recording a payday is possible from
//  the first usable build even though the DEC-036 reminder that prompts for it is not.
//
//  Transfers are Sprint 5 and are deliberately absent — the schema supports them
//  (DEC-028), the form does not yet.
//
//  Sprint 4 adds DEC-030's merchant memory on both sides of this form: it proposes
//  a category for a merchant it has seen before, and it learns from whatever the
//  user actually saves. The proposal only ever fills an *empty* category field —
//  a guess that overwrote a choice the user had already made would be the app
//  arguing with them, and DEC-030's justification rests on one-tap confirmation
//  being cheap, not on the guess being right.
//

import GRDB
import SwiftUI

struct TransactionFormView: View {
    let database: AppDatabase
    /// Nil when adding. Set when editing an existing row.
    let editing: UUID?

    @Environment(\.dismiss) private var dismiss

    @State private var kind: TransactionKind
    @State private var amountText = ""
    @State private var merchant = ""
    @State private var bookedOn = Date()
    @State private var accountID: UUID?
    @State private var categoryID: UUID?
    @State private var accounts: [AccountRecord] = []
    @State private var categories: [CategoryRecord] = []
    @State private var errorMessage: String?
    /// The category DEC-030's memory proposed, kept so the form can say where the
    /// filled-in category came from rather than appearing to have guessed at random.
    @State private var suggestedCategoryID: UUID?

    /// `kind` is a parameter rather than always starting at `.expense` so DEC-036's
    /// "Log now" can open an income form directly from the payday reminder.
    init(database: AppDatabase, editing: UUID? = nil, kind: TransactionKind = .expense) {
        self.database = database
        self.editing = editing
        _kind = State(initialValue: kind)
    }

    private var currency: Currency {
        accounts
            .first { $0.id == accountID?.uuidString }
            .flatMap { Currency(rawValue: $0.currency) } ?? .aud
    }

    private var parsedAmount: Money? {
        try? MoneyText.money(from: amountText, currency: currency)
    }

    /// True while the category on screen is the one the memory proposed.
    ///
    /// Comparing against the proposal is also what decides whether a later merchant
    /// edit may overwrite the field, which is why there is no separate "did the user
    /// touch this" flag: a category that still equals the proposal is one nobody has
    /// overridden, and a category that does not is the user's own choice. One piece
    /// of state, and the two questions cannot disagree.
    private var isShowingSuggestion: Bool {
        kind != .income && categoryID != nil && categoryID == suggestedCategoryID
    }

    private var canSave: Bool {
        guard let amount = parsedAmount, accountID != nil else { return false }
        return amount.isPositive
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        Text("Expense").tag(TransactionKind.expense)
                        Text("Income").tag(TransactionKind.income)
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Text(currency.rawValue)
                            .foregroundStyle(.secondary)
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.title2.monospacedDigit())
                    }
                }

                Section {
                    Picker("Account", selection: $accountID) {
                        ForEach(accounts, id: \.id) { account in
                            Text(account.name).tag(UUID(uuidString: account.id))
                        }
                    }

                    // Rule 9: income never carries a category, so the field is not
                    // shown rather than shown and quietly ignored.
                    if kind != .income {
                        Picker("Category", selection: $categoryID) {
                            Text("None").tag(UUID?.none)
                            ForEach(categories, id: \.id) { category in
                                Text(category.name).tag(UUID(uuidString: category.id))
                            }
                        }
                    }

                    TextField(kind == .income ? "Source (optional)" : "Merchant (optional)", text: $merchant)
                        .textInputAutocapitalization(.words)
                        .onChange(of: merchant) { _, _ in Task { await suggestCategory() } }

                    DatePicker("Date", selection: $bookedOn, displayedComponents: .date)
                } footer: {
                    if isShowingSuggestion {
                        Label("Category remembered from last time", systemImage: "wand.and.stars")
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }

                if editing != nil {
                    Section {
                        Button("Delete", role: .destructive, action: delete)
                    }
                }
            }
            .navigationTitle(editing == nil ? "New transaction" : "Edit transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!canSave)
                }
            }
            .task { await load() }
        }
    }

    // MARK: - Actions

    private func load() async {
        do {
            let loaded = try await database.writer.read { db in
                (try AccountStore().all(in: db), try CategoryStore().all(in: db))
            }
            accounts = loaded.0
            categories = loaded.1
            accountID = accountID ?? accounts.first.flatMap { UUID(uuidString: $0.id) }

            if let editing {
                let draft = try await database.writer.read { db in
                    try TransactionStore().draft(id: editing, in: db)
                }
                if let draft {
                    apply(draft)
                }
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// DEC-030's guess. Fills the category only when the field is empty or still
    /// holds the previous guess, so a choice the user made themselves is never
    /// overwritten by typing one more letter of the merchant's name.
    private func suggestCategory() async {
        guard kind != .income else { return }
        let typed = merchant
        let suggestion = try? await database.writer.read { db in
            try MerchantRules().suggestion(forMerchant: typed, in: db)
        }
        guard let suggestion else { return }
        if categoryID == nil || categoryID == suggestedCategoryID {
            categoryID = suggestion
        }
        suggestedCategoryID = suggestion
    }

    private func apply(_ draft: TransactionDraft) {
        kind = draft.kind
        amountText = MoneyText.editableString(from: draft.amount)
        merchant = draft.merchant ?? ""
        bookedOn = draft.bookedOn.middayDate()
        accountID = draft.accountID
        categoryID = draft.categoryID
    }

    private func save() {
        guard let amount = parsedAmount, let accountID else { return }
        let draft = TransactionDraft(
            kind: kind,
            amount: amount,
            accountID: accountID,
            categoryID: categoryID,
            merchant: merchant,
            bookedOn: CivilDate(localDayOf: bookedOn)
        )
        let editing = editing
        Task {
            do {
                try await database.writer.write { db in
                    let store = TransactionStore()
                    if let editing {
                        try store.update(id: editing, with: draft, in: db)
                    } else {
                        try store.create(draft, in: db)
                    }
                    // DEC-030: "written every time the user confirms or corrects a
                    // category." Both cases are this one line — the form does not
                    // know or care which of the two just happened, and a correction
                    // is simply the most recent thing the user said about this shop.
                    if let categoryID = draft.effectiveCategoryID {
                        try MerchantRules().remember(
                            merchant: draft.merchant, categoryID: categoryID, in: db
                        )
                    }
                }
                dismiss()
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }

    private func delete() {
        guard let editing else { return }
        Task {
            do {
                try await database.writer.write { db in
                    try TransactionStore().delete(id: editing, in: db)
                }
                dismiss()
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }
}
