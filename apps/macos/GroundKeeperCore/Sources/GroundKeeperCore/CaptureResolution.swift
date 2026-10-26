import Foundation

/// The committed result of continuing a capture after a user's decision.
/// Category suggestions are separate work on an already saved transaction.
public enum CaptureResolution: Equatable, Sendable {
    case created(transactionID: String)
    case linked(transactionID: String)
    case needsReview(reason: String)
}
