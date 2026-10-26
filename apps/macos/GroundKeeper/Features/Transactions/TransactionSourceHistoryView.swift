import SwiftUI
import GroundKeeperCore

struct TransactionSourceHistoryView: View {
    let evidence: TransactionEvidence

    var body: some View {
        DisclosureGroup("Source & history") {
            VStack(alignment: .leading, spacing: 18) {
                if evidence.sources.isEmpty {
                    Text("Manually entered. No capture or statement source is attached.").foregroundStyle(AppStyle.muted)
                }
                ForEach(evidence.sources) { source in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(source.kind == "csv" ? "Bank CSV" : source.source).font(.headline)
                        Text(source.description).textSelection(.enabled)
                        if let amount = source.amountMinor, let currency = source.currency {
                            LabeledContent("Source amount", value: ReportFormat.money(amount, currency) + " " + currency)
                        }
                        LabeledContent("Source date", value: source.day)
                        LabeledContent(source.kind == "csv" ? "Imported" : "Captured", value: recordedTime(source))
                        if let card = source.card, !card.isEmpty { LabeledContent("Card", value: card) }
                        DisclosureGroup("Original source") {
                            Text(prettyJSON(source.payload)).font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Divider()
                }
                if !evidence.history.isEmpty {
                    Text("Changes").font(.headline)
                    ForEach(evidence.history) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(historyTitle(entry.reason)).fontWeight(.medium)
                            Text(Date(timeIntervalSince1970: Double(entry.changedAtMS) / 1000), format: .dateTime.year().month().day().hour().minute())
                                .font(.caption).foregroundStyle(AppStyle.muted)
                            ForEach(historyDetails(entry), id: \.self) { detail in
                                Text(detail).font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                }
            }.padding(.top, 12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func recordedTime(_ source: TransactionSourceEvidence) -> String {
        var format = Date.FormatStyle(date: .abbreviated, time: .standard)
        format.timeZone = TimeZone(secondsFromGMT: source.offsetMinutes * 60) ?? .gmt
        return Date(timeIntervalSince1970: Double(source.capturedAtMS) / 1000).formatted(format)
            + " · " + (format.timeZone.abbreviation() ?? "UTC")
    }

    private func prettyJSON(_ payload: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return payload }
        return String(decoding: data, as: UTF8.self)
    }

    private func historyTitle(_ reason: String) -> String {
        switch reason {
        case "edit": "Transaction saved"
        case "edit_note": "Notes edited"
        case "merge_statement": "Statement and capture combined"
        case "resolve_csv_review": "Statement correction reviewed"
        case "correct_csv_mapping": "CSV column mapping corrected"
        case "merchant_identity": "Merchant grouping changed"
        case "delete": "Transaction hidden"
        default: reason.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func historyDetails(_ entry: TransactionHistoryEntry) -> [String] {
        guard let after = entry.after, let values = try? JSONSerialization.jsonObject(with: Data(after.utf8)) as? [String: String] else { return [] }
        return [("description", "Description"), ("notes", "Notes"), ("occurred_on", "Date")].compactMap { key, label in
            values[key].map { label + ": " + $0 }
        }
    }
}
