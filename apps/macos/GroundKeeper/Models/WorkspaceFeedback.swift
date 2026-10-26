import Foundation

struct WorkspaceFeedback: Identifiable {
    let id = UUID()
    let message: String
    var transactionID: String? = nil
    var needsAttention = false
}
