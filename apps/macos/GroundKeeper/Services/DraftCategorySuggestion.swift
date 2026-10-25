import Foundation
import GroundKeeperCore

struct DraftCategorySuggestion {
    let decision: ClassificationDecision
    let provider: String
    var kind: TransactionKind { TransactionKind.allCases.first { $0.code == decision.type } ?? .unknown }
    var category: SpendingCategory { SpendingCategory.allCases.first { $0.code == decision.category } ?? .none }
}

extension AppWorkspace {
    /// A draft is never inserted into the ledger just to obtain a suggestion.
    func suggestCategory(for draft: Transaction) async throws -> DraftCategorySuggestion {
        guard !processing, !saving, !classifying else { throw LedgerError.unavailable("Wait for the current processing to finish.") }
        let description = draft.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { throw LedgerError.invalid("Enter a transaction description first.") }
        guard classifierProvider != "manual" else { throw LedgerError.unavailable("Choose a classifier in Settings → Categorization to get suggestions.") }
        processing = true
        defer { processing = false }
        let suggestionClient = client
        model = nil
        do {
            let input = ClassifierInput(description: description, direction: draft.isDebit ? "debit" : "credit", currency: draft.currency,
                                        transactionNotes: draft.notes.isEmpty ? nil : draft.notes)
            let suggestion: DraftCategorySuggestion
            if classifierProvider == "ollama" {
                guard let data = AppPreferences.defaults.data(forKey: "ollamaSelectedModel"),
                      let selected = try? JSONDecoder().decode(OllamaModel.self, from: data) else {
                    throw LedgerError.unavailable("Choose an installed Ollama model in Settings.")
                }
                let decision = try await ollama.classify(inputJSON: JSONEncoder().encode(input), model: selected)
                suggestion = DraftCategorySuggestion(decision: decision, provider: "Ollama · \(selected.name)")
            } else if classifierProvider == "council" {
                guard let configuration = try await store?.selectedCouncil() else { throw LedgerError.unavailable("Set up Council in Settings.") }
                var votes: [CouncilVote] = []
                for member in configuration.members {
                    try Task.checkCancellation()
                    do {
                        let loaded: ClassifierModel
                        if member.backend == "apple_shortcut" {
                            loaded = try await suggestionClient.prepareShortcut(name: AppPreferences.defaults.string(forKey: "activeCouncilShortcut") ?? "GK Categorize Cloud")
                        } else {
                            loaded = try await prepareDraftModel(client: suggestionClient, bookmarkKey: "activeCouncilPackage.\(member.backend)")
                        }
                        guard loaded.manifestSHA256 == member.id else { throw ClassifierBridgeError.invalidResponse }
                        let decision = try await draftDecision(client: suggestionClient, input: input, model: loaded, draft: draft)
                        votes.append(CouncilVote(member: member, disposition: "valid", decision: decision))
                    } catch {
                        try Task.checkCancellation()
                        let failure = CouncilClassifierEngine.safeFailure(error)
                        votes.append(CouncilVote(member: member, disposition: failure.disposition, errorCode: failure.code))
                    }
                }
                let result = try CouncilResult.resolve(votes)
                guard let decision = result.decision else { throw LedgerError.unavailable("The Council did not agree on a category. Add more detail or choose one yourself.") }
                suggestion = DraftCategorySuggestion(decision: decision, provider: "AI Council · \(result.title)")
            } else {
                let loaded: ClassifierModel
                if classifierProvider == "shortcut" {
                    loaded = try await suggestionClient.prepareShortcut(name: AppPreferences.defaults.string(forKey: "classifierShortcutName") ?? "GK Categorize Cloud")
                } else {
                    loaded = try await prepareDraftModel(client: suggestionClient, bookmarkKey: "classifierModelBookmark")
                }
                suggestion = DraftCategorySuggestion(decision: try await draftDecision(client: suggestionClient, input: input, model: loaded, draft: draft), provider: loaded.modelID)
            }
            try suggestion.decision.validateSuggestion()
            try Task.checkCancellation()
            await releaseClassifierResources()
            return suggestion
        } catch {
            await releaseClassifierResources()
            throw error
        }
    }

    private func prepareDraftModel(client: ClassifierClient, bookmarkKey: String) async throws -> ClassifierModel {
        guard let bookmark = AppPreferences.defaults.data(forKey: bookmarkKey) else { throw LedgerError.unavailable("Choose a model package in Settings.") }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
        guard !stale else { throw LedgerError.unavailable("Select the model package again in Settings.") }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return try await client.prepareModel(at: url)
    }

    private func draftDecision(client: ClassifierClient, input: ClassifierInput, model: ClassifierModel, draft: Transaction) async throws -> ClassificationDecision {
        // Unsaved drafts use a positive request revision; persisted edits retain
        // their revision. This is request identity only and never writes the ledger.
        let result = try await client.classify(input, model: model, partID: draft.id.uuidString, revision: max(1, draft.revision))
        guard let decision = result.decision else { throw ClassifierBridgeError.invalidResponse }
        return ClassificationDecision(type: decision.type, category: decision.category, review: decision.review)
    }
}
