import SwiftUI
import GroundKeeperCore

struct CouncilEvidenceView: View {
    @Environment(AppWorkspace.self) private var workspace
    let transactionID: String
    @State private var report: CouncilReport?
    @State private var error: String?
    @State private var loading = true
    @State private var expanded = false
    var body: some View {
        Group {
            if loading {
                Section { ProgressView("Loading council details…").controlSize(.small) }
            } else if let report {
                Section {
                    Text(report.result.title).font(.headline)
                    if !report.isCurrentRevision {
                        Text("Saved council result from an earlier transaction revision. Your current categorization is shown above.").font(.caption).foregroundStyle(AppStyle.muted)
                    } else if report.result.decision == nil {
                        Text("Council kept the current categorization. Compare the individual suggestions below, or use Retry failed in Sync for another attempt.")
                            .font(.caption).foregroundStyle(AppStyle.muted)
                    } else { Text("Council suggestion · needs your review").font(.caption).foregroundStyle(AppStyle.muted) }
                    Button {
                        expanded.toggle()
                    } label: {
                        Label("Member decisions and sources", systemImage: expanded ? "chevron.down" : "chevron.right")
                    }.buttonStyle(.plain).accessibilityValue(expanded ? "Expanded" : "Collapsed")
                    if expanded {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(report.result.votes, id: \.member.id) { vote in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(vote.member.title) · one vote").font(.headline)
                                    if let decision = vote.decision { Text(Self.decisionText(decision)) }
                                    else { Text(Self.failureText(vote)).foregroundStyle(AppStyle.muted) }
                                    Text(vote.member.name).font(.caption).foregroundStyle(AppStyle.muted).textSelection(.enabled)
                                }.accessibilityElement(children: .combine)
                            }
                            if let context = report.search?.context {
                                Text("Shared DuckDuckGo evidence").font(.headline)
                                ForEach(context.results, id: \.url) { source in
                                    VStack(alignment: .leading, spacing: 4) {
                                        if let url = URL(string: source.url) { Link(source.title, destination: url) }
                                        Text(source.body).font(.caption).textSelection(.enabled)
                                    }
                                }
                            } else { Text("No web evidence was used.").font(.caption).foregroundStyle(AppStyle.muted) }
                            Text(report.receiptSharedWithApple ? "Apple input includes receipt text." : "Apple input excludes receipt text.")
                                .font(.caption).foregroundStyle(AppStyle.muted)
                            Text("Equal votes · \(CouncilConfiguration.algorithm)").font(.caption).foregroundStyle(AppStyle.muted)
                            Text("Run: \(report.runID)").font(.caption2).textSelection(.enabled).foregroundStyle(AppStyle.muted)
                        }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                } header: { Text("Model council").font(VaultTypography.section) }
            } else if let error { Section("Model council") { Text(error).font(.caption).foregroundStyle(.red) } }
        }.task(id: transactionID) {
            defer { loading = false }
            do { report = try await workspace.councilReport(transactionID: transactionID) }
            catch { self.error = "Council details could not be loaded. Reopen this transaction to retry." }
        }
    }
    static func decisionText(_ decision: ClassificationDecision) -> String {
        let type = TransactionKind.allCases.first { $0.code == decision.type }?.rawValue ?? decision.type
        let category = decision.category.map { code in SpendingCategory.allCases.first { $0.code == code }?.rawValue ?? code }
        return category.map { "\(type) · \($0)" } ?? type
    }
    static func failureText(_ vote: CouncilVote) -> String {
        switch vote.errorCode {
        case "shortcut_rate_limited": "Apple usage limit reached"
        case "model_package_unavailable": "Package unavailable; choose it again in Council setup"
        case "model_identity_changed": "Package changed; apply Council setup again"
        default:
            switch vote.disposition {
            case "timeout": "Request timed out"
            case "invalid": "Response could not be validated"
            case "skipped": "Not consulted"
            default: "Provider unavailable"
            }
        }
    }
}
