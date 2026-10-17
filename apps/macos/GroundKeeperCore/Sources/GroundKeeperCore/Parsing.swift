import Foundation

public enum ExactMoney {
    public static let currencies = ["CAD", "USD", "EUR", "GBP"]
    public static func parse(_ input: String, currency: String, decimalComma: Bool = false) throws -> Int64 {
        guard currencies.contains(currency) else { throw LedgerError.invalid("Unsupported currency.") }
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        for code in currencies where value.contains(code) {
            guard code == currency else { throw LedgerError.invalid("Amount currency conflicts with the selected account.") }
            value = value.replacingOccurrences(of: code, with: "")
        }
        for (symbol, allowed) in [("$", ["CAD", "USD"]), ("€", ["EUR"]), ("£", ["GBP"])] where value.contains(symbol) {
            guard allowed.contains(currency) else { throw LedgerError.invalid("Currency symbol conflicts with the selected currency.") }
            value = value.replacingOccurrences(of: symbol, with: "")
        }
        value = value.trimmingCharacters(in: .whitespaces)
        let negative = value.hasPrefix("-") || (value.hasPrefix("(") && value.hasSuffix(")"))
        if value.hasPrefix("(") && value.hasSuffix(")") { value = String(value.dropFirst().dropLast()) }
        else if value.hasPrefix("-") || value.hasPrefix("+") { value.removeFirst() }
        let separator = decimalComma ? "," : ".", grouping = decimalComma ? "." : ","
        let pattern = "^(?:[0-9]+|[0-9]{1,3}(?:" + NSRegularExpression.escapedPattern(for: grouping) + "[0-9]{3})+)(?:" + NSRegularExpression.escapedPattern(for: separator) + "[0-9]{1,2})?$"
        guard value.range(of: pattern, options: .regularExpression) != nil else { throw LedgerError.invalid("Invalid amount or more than two decimal places.") }
        let pieces = value.replacingOccurrences(of: grouping, with: "").components(separatedBy: separator)
        guard let whole = Int64(pieces[0]) else { throw LedgerError.invalid("Amount is too large.") }
        let cents = pieces.count == 2 ? Int64(pieces[1].padding(toLength: 2, withPad: "0", startingAt: 0))! : 0
        let (scaled, overflow) = whole.multipliedReportingOverflow(by: 100)
        let (total, addedOverflow) = scaled.addingReportingOverflow(cents)
        guard !overflow && !addedOverflow else { throw LedgerError.invalid("Amount is too large.") }
        return negative ? -total : total
    }
}
public enum CivilDate {
    public static func parse(_ text: String, format: String = "yyyy-MM-dd") throws -> String {
        guard ["yyyy-MM-dd", "MM/dd/yyyy", "dd/MM/yyyy"].contains(format) else { throw LedgerError.invalid("Unsupported date format.") }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false; formatter.dateFormat = format
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { throw LedgerError.invalid("Invalid date for the selected format.") }
        formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: date)
    }
}
enum CaptureParser {
    static func decode(_ data: Data) throws -> CaptureEnvelope {
        guard data.count <= 65_536 else { throw LedgerError.invalid("capture_too_large") }
        let value = try JSONDecoder().decode(CaptureEnvelope.self, from: data)
        guard [1, 2].contains(value.schemaVersion), !value.eventID.isEmpty, value.eventID.count <= 128,
              ["wallet_transaction", "bank_notification", "test_notification"].contains(value.source),
              value.source != "test_notification" || value.isTest == true else { throw LedgerError.invalid("unsupported_capture") }
        return value
    }
    static func timestamp(_ value: String) throws -> (Int64, Int) {
        guard value.range(of: "(?:Z|[+-][0-9]{2}:[0-9]{2})$", options: .regularExpression) != nil else { throw LedgerError.invalid("timestamp_requires_offset") }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: value)
        if date == nil { formatter.formatOptions = [.withInternetDateTime]; date = formatter.date(from: value) }
        guard let date else { throw LedgerError.invalid("invalid_timestamp") }
        var offset = 0
        if !value.hasSuffix("Z") {
            let suffix = String(value.suffix(6)); let parts = suffix.dropFirst().split(separator: ":")
            guard let hour = Int(parts[0]), let minute = Int(parts[1]), hour <= 14, minute < 60, hour != 14 || minute == 0 else { throw LedgerError.invalid("invalid_offset") }
            offset = (hour * 60 + minute) * (suffix.hasPrefix("-") ? -1 : 1)
        }
        return (Int64(date.timeIntervalSince1970 * 1000), offset)
    }
    static func parse(_ value: CaptureEnvelope, account: Account?) throws -> Observation {
        let (timestamp, offset) = try timestamp(value.capturedAt)
        let day = try CivilDate.parse(String(value.capturedAt.prefix(10)))
        let wallet = value.source == "wallet_transaction"
        let description = (wallet ? value.merchant : value.subtitle)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let amountText = (wallet ? value.amount : value.body) ?? ""
        let explicit = ExactMoney.currencies.filter { amountText.uppercased().contains($0) }
        let currency = explicit.count == 1 ? explicit[0] : account?.currency
        var error: String? = nil
        if account == nil { error = "account_mapping_required" }
        if description.isEmpty || description.count > 2048 { error = "merchant_required" }
        var amount: Int64?
        if let currency {
            // Only the observed separate-field purchase format is accepted.
            // Narrative/refund/decline notifications remain reviewable raw evidence.
            if let parsed = try? ExactMoney.parse(amountText, currency: currency), parsed > 0 {
                amount = -parsed
            } else { error = "unrecognized_purchase_amount" }
            if let account, account.currency != currency { error = "currency_mismatch" }
        } else { error = "currency_required" }
        let shapes = wallet ? ["wallet_transaction_fields"] : ["notification_fields", "separate_fields"]
        if !shapes.contains(value.inputShape ?? "") { error = "unsupported_input_shape" }
        return Observation(description: description, amount: amount, currency: currency, day: day, captured: timestamp,
                           offset: offset, accountID: account?.id, label: value.label, lifecycle: "pending", error: error)
    }
}
public enum CSVParser {
    public static func parse(_ input: String, delimiter: Character = ",") throws -> [[String]] {
        guard [",", ";", "\t"].contains(delimiter) else { throw LedgerError.invalid("Unsupported delimiter.") }
        let text = input.hasPrefix("\u{feff}") ? String(input.dropFirst()) : input
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false, closed = false
        var iterator = text.makeIterator(), pending: Character? = iterator.next()
        while let char = pending {
            pending = iterator.next()
            if quoted {
                if char == "\"" {
                    if pending == "\"" { field.append("\""); pending = iterator.next() }
                    else { quoted = false; closed = true }
                } else { field.append(char) }
            } else if char == delimiter {
                row.append(field); field = ""; closed = false
            } else if char == "\n" || char == "\r" || char == "\r\n" {
                if char == "\r" && pending == "\n" { pending = iterator.next() }
                row.append(field)
                if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                row = []; field = ""; closed = false
            } else if char == "\"" && field.isEmpty && !closed { quoted = true }
            else {
                guard !closed && char != "\"" else { throw LedgerError.invalid("Malformed CSV quoting.") }
                field.append(char)
            }
            guard field.utf8.count <= 65_536, rows.count <= 50_000, row.count <= 128 else { throw LedgerError.invalid("CSV exceeds row, column or field limits.") }
        }
        guard !quoted else { throw LedgerError.invalid("Unclosed CSV quote.") }
        row.append(field); if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }
    static func observation(_ row: [String], mapping m: CSVMapping, width: Int) throws -> Observation {
        let columns = [m.dateColumn, m.descriptionColumn, m.amountColumn] + [m.creditColumn, m.externalIDColumn].compactMap { $0 }
        guard row.count == width, Set(columns).count == columns.count, columns.allSatisfy(row.indices.contains) else { throw LedgerError.invalid("Column mapping or row width is invalid.") }
        let description = row[m.descriptionColumn].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty, description.count <= 2048 else { throw LedgerError.invalid("Description is empty or too long.") }
        let day = try CivilDate.parse(row[m.dateColumn].trimmingCharacters(in: .whitespaces), format: m.dateFormat)
        var amount: Int64
        if let credit = m.creditColumn {
            let debitText = row[m.amountColumn].trimmingCharacters(in: .whitespaces)
            let creditText = row[credit].trimmingCharacters(in: .whitespaces)
            let debit = debitText.isEmpty ? 0 : try ExactMoney.parse(debitText, currency: m.currency, decimalComma: m.decimalComma)
            let income = creditText.isEmpty ? 0 : try ExactMoney.parse(creditText, currency: m.currency, decimalComma: m.decimalComma)
            guard debit >= 0, income >= 0, (debit > 0) != (income > 0) else { throw LedgerError.invalid("Exactly one positive debit or credit is required.") }
            amount = income - debit
        } else {
            amount = try ExactMoney.parse(row[m.amountColumn], currency: m.currency, decimalComma: m.decimalComma)
            if m.positiveMeansDebit { amount = -amount }
        }
        guard amount != 0 else { throw LedgerError.invalid("Zero-value rows are not monetary transactions.") }
        let external = m.externalIDColumn.map { row[$0].trimmingCharacters(in: .whitespacesAndNewlines) }
        guard (external?.count ?? 0) <= 128 else { throw LedgerError.invalid("External ID is too long.") }
        return Observation(description: description, amount: amount, currency: m.currency, day: day, captured: nowMS(), offset: 0,
            accountID: m.accountID, label: "", lifecycle: "posted", error: nil, dateOnly: true, externalID: external?.isEmpty == false ? external : nil)
    }
}
