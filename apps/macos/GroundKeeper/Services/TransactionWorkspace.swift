import Foundation
import GroundKeeperCore
import Observation

/// Ledger reads, filters, paging, and edits share one query generation counter.
@MainActor @Observable final class TransactionWorkspace: WorkspaceComponent {
    let session: WorkspaceSession
    var transactions: [Transaction] = []
    var recentTransactions: [Transaction] = []
    var matchingTransactions = 0
    var transactionQuery = LedgerTransactionQuery()
    var transactionReviewCount = 0
    @ObservationIgnored private var refreshRequest = 0
    var accounts: [Account] = []
    var totalTransactions = 0
    var reportingRevision: Int64 = 0
    var page = 0
    var reviewOnly = false
    var focusTransactionSearch = false
    var editor: Transaction?
    var showingImportPreview = false

    init(session: WorkspaceSession) { self.session = session }

    func clearLockedState() {
        refreshRequest += 1
        transactions = []; recentTransactions = []; accounts = []
        matchingTransactions = 0; totalTransactions = 0; transactionReviewCount = 0
        reportingRevision = 0; editor = nil; showingImportPreview = false
    }

    func refreshSnapshot() async throws -> LedgerWorkspaceSnapshot? {
        guard let store else { return nil }
        refreshRequest += 1
        let request = refreshRequest
        let query = transactionQuery, offset = page * 500
        let result = try await store.workspaceSnapshot(query, offset: offset)
        guard self.store === store, request == refreshRequest, transactionQuery == query, page * 500 == offset else { return nil }
        let snapshot = result.ledger
        transactions = result.page.transactions.map(Transaction.init)
        matchingTransactions = result.page.totalMatches; page = result.page.offset / 500
        recentTransactions = snapshot.transactions.map(Transaction.init)
        transactionReviewCount = result.reviewCount
        accounts = snapshot.accounts
        totalTransactions = snapshot.totalTransactions
        reportingRevision = result.reportingRevision
        return result
    }

    func spendingContext(timezone: String) async throws -> SpendingContext {
        guard let store else { throw LedgerError.unavailable("Unlock your vault to view spending.") }
        let result = try await store.spendingContext(timezone: timezone)
        guard self.store === store else { throw CancellationError() }
        return result
    }

    func spendingReport(_ filter: SpendingFilter) async throws -> SpendingReport {
        guard let store else { throw LedgerError.unavailable("Unlock your vault to view spending.") }
        let result = try await store.spendingReport(filter)
        guard self.store === store else { throw CancellationError() }
        return result
    }

    func spendingEntries(_ filter: SpendingFilter, offset: Int) async throws -> [SpendingEntry] {
        guard let store else { throw LedgerError.unavailable("Unlock your vault to view spending.") }
        let result = try await store.spendingEntries(filter, offset: offset, limit: 101)
        guard self.store === store else { throw CancellationError() }
        return result
    }

    func hideFinding(_ id: String, snooze: Bool) async throws {
        guard let store else { return }
        try await store.setFindingPreference(id: id, dismissed: !snooze, snoozedUntil: snooze ? Date().addingTimeInterval(7 * 86400) : nil)
    }

    func restoreFindings() async throws { try await store?.restoreSpendingFindings() }

    func transaction(id: String) async throws -> Transaction? {
        guard let store else { throw LedgerError.unavailable("Unlock your vault to view this transaction.") }
        let record = try await store.transaction(id: id)
        guard self.store === store else { throw CancellationError() }
        return record.map(Transaction.init)
    }

    func saveTransaction(_ transaction: Transaction) async throws {
        guard let store else { throw LedgerError.unavailable("Unlock your vault to save this transaction.") }
        guard !saving else { throw LedgerError.unavailable("Wait for the current change to finish, then save again.") }
        saving = true
        defer { finishSaving() }
        let edit = try await self.prepareTransactionEdit(transaction)
        guard self.store === store else { throw CancellationError() }
        try await store.save(edit)
        guard self.store === store else { throw CancellationError() }
        try await refresh()
        feedback = WorkspaceFeedback(message: "Transaction saved")
    }

    func save(_ transaction: Transaction) {
        perform {
            guard let store = self.store else { return }
            let edit = try await self.prepareTransactionEdit(transaction)
            guard self.store === store else { throw CancellationError() }
            try await store.save(edit)
            self.editor = nil
            try await self.refresh()
            self.feedback = WorkspaceFeedback(message: "Transaction saved")
        }
    }

    private func prepareTransactionEdit(_ transaction: Transaction) async throws -> TransactionEdit {
        var edit = try transaction.edit
        edit.receiptAdditions = []
        for receipt in transaction.newReceiptImages {
            let data = receipt.data
            // The import flow already produced the bounded JPEG; OCR never blocks
            // saving a readable receipt if recognition is unavailable.
            let ocr = try? await ReceiptOCR.recognizeText(data)
            edit.receiptAdditions.append(ReceiptAddition(image: data, text: ocr?.text ?? "", producer: ocr?.producer ?? "apple_vision_documents"))
        }
        return edit
    }

    func delete(_ transaction: Transaction) {
        perform { try await self.store?.delete(id: transaction.id.uuidString, revision: transaction.revision); try await self.refresh() }
    }

    func accountLabel(id: String?, fallback: String) -> String {
        accounts.first { $0.id == id }?.displayName(in: accounts) ?? fallback
    }

    func accountNameExists(name: String, currency: String, excludingID: String? = nil) -> Bool {
        accounts.contains { $0.id != excludingID && $0.currency == currency && Account.normalizedName($0.name) == Account.normalizedName(name) }
    }

    func renameAccount(id: String, name: String) async throws {
        guard let store else { throw LedgerError.unavailable("Unlock your vault to rename an account.") }
        guard !saving else { throw LedgerError.unavailable("Wait for the current change to finish, then try again.") }
        saving = true
        defer { finishSaving() }
        try await store.renameAccount(id: id, name: name)
        guard self.store === store else { throw CancellationError() }
        try await refresh()
        feedback = WorkspaceFeedback(message: "Account renamed")
    }

    func addAccount(name: String, currency: String, kind: String) {
        perform {
            try await self.store?.addAccount(name: name, currency: currency, kind: kind)
            try await self.refresh()
            self.feedback = WorkspaceFeedback(message: "Account added")
        }
    }

    func importCSV(_ document: CSVDocument, mapping: CSVMapping, skipped: Set<Int>, updateExisting: Bool = false) async throws -> Int {
        guard let store else { throw LedgerError.unavailable("Open the vault first.") }
        let count = try await store.importCSV(document, mapping: mapping, skipped: skipped, updateExisting: updateExisting)
        page = 0; try await refresh(); Task { await session.processAutomatically() }; return count
    }

    func queryTransactions(_ query: LedgerTransactionQuery) {
        guard query != transactionQuery else { return }
        transactionQuery = query; page = 0
        refreshTransactionQuery()
    }

    func changePage(_ value: Int) { page = max(0, value); refreshTransactionQuery() }

    private func refreshTransactionQuery() {
        // Invalidate older results before scheduling the read. Reads must not take
        // the write lock: rapid filter changes must each request their final state.
        refreshRequest += 1
        Task { do { try await refresh() } catch { if ready { errorMessage = error.localizedDescription } } }
    }
}
