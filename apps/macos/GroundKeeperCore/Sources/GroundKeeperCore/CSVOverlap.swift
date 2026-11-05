import Foundation

/// Exact statement facts, without merchant normalization or date/amount tolerances.
private struct CSVTransactionKey: Hashable {
    let account: String?, currency: String?, amount: Int64?, day: String, description: String, externalID: String?

    init(_ observation: Observation) {
        account = observation.accountID; currency = observation.currency; amount = observation.amount
        day = observation.day; description = observation.description; externalID = observation.externalID
    }

    init(_ row: Row) {
        account = row["account_id"]?.string; currency = row["currency"]?.string; amount = row["amount_minor"]?.int
        day = row.text("occurred_on"); description = row.text("description"); externalID = row["external_record_id"]?.string
    }
}

/// A suffix automaton finds a longest contiguous match in linear time, including
/// exports with many identical purchases. Negative tokens separate skipped rows.
struct CSVSequenceIndex {
    private struct State {
        var length: Int, suffix: Int, end: Int
        var next: [Int: Int] = [:]
    }
    private var states = [State(length: 0, suffix: -1, end: -1)]

    init(_ tokens: [Int]) {
        var last = 0
        for (position, token) in tokens.enumerated() {
            let current = states.count
            states.append(State(length: states[last].length + 1, suffix: 0, end: position))
            var parent = last
            while parent >= 0 && states[parent].next[token] == nil {
                states[parent].next[token] = current
                parent = states[parent].suffix
            }
            if parent >= 0, let target = states[parent].next[token] {
                if states[parent].length + 1 == states[target].length {
                    states[current].suffix = target
                } else {
                    let clone = states.count
                    var copy = states[target]; copy.length = states[parent].length + 1
                    states.append(copy)
                    while parent >= 0 && states[parent].next[token] == target {
                        states[parent].next[token] = clone
                        parent = states[parent].suffix
                    }
                    states[target].suffix = clone; states[current].suffix = clone
                }
            }
            last = current
        }
    }

    func longestMatch(_ tokens: [Int?], rowNumbers: [Int]) -> (incoming: Range<Int>, previous: Range<Int>)? {
        var state = 0, length = 0, bestLength = 0, incomingEnd = 0, previousEnd = 0
        for (position, token) in tokens.enumerated() {
            if position > 0 && rowNumbers[position] != rowNumbers[position - 1] + 1 { state = 0; length = 0 }
            guard let token else { state = 0; length = 0; continue }
            while state != 0 && states[state].next[token] == nil {
                state = states[state].suffix; length = states[state].length
            }
            if let next = states[state].next[token] { state = next; length += 1 }
            else { state = 0; length = 0 }
            if length > bestLength {
                bestLength = length; incomingEnd = states[state].end + 1; previousEnd = position + 1
            }
        }
        guard bestLength > 0 else { return nil }
        return ((incomingEnd - bestLength)..<incomingEnd, (previousEnd - bestLength)..<previousEnd)
    }
}

extension LedgerStore {
    /// Use one longest same-order block per earlier file, never an unordered set
    /// of equal rows. Each saved purchase can cover only one row in this import.
    func csvOverlapTargets(_ document: CSVDocument, mapping: CSVMapping, skipped: Set<Int>, batchID: String) throws -> [Int: String] {
        let previous = try db.query("""
            SELECT i.row_number,b.id AS batch_id,t.id AS target_id,o.* FROM import_batches b
            JOIN import_rows i ON i.batch_id=b.id
            JOIN transaction_event_links l ON l.event_id=i.event_id AND l.unlinked_at_ms IS NULL
            JOIN transactions t ON t.id=l.transaction_id AND t.state='active' AND t.account_id=? AND t.currency=?
            JOIN event_observations o ON o.id=l.observation_id AND o.status='parsed'
            WHERE b.source_id=? AND b.account_scope_id=? AND b.status='committed' AND b.id<>?
              AND i.status IN ('accepted','duplicate')
              AND NOT EXISTS(SELECT 1 FROM review_items r WHERE r.event_id=i.event_id AND r.status='open')
            ORDER BY b.created_at_ms,b.rowid,i.row_number
            """, [.text(mapping.accountID), .text(mapping.currency), .text("csv:" + mapping.accountID), .text(mapping.accountID), .text(batchID)])
        guard !previous.isEmpty else { return [:] }

        var tokenIDs: [CSVTransactionKey: Int] = [:]
        let tokens = document.rows.enumerated().map { position, cells -> Int in
            guard !skipped.contains(position + 2),
                  let observation = try? CSVParser.observation(cells, mapping: mapping, width: document.headers.count) else { return -position - 1 }
            let key = CSVTransactionKey(observation)
            if let token = tokenIDs[key] { return token }
            let token = tokenIDs.count; tokenIDs[key] = token
            return token
        }
        let index = CSVSequenceIndex(tokens)
        var blocks: [[(row: Int, target: String)]] = []
        var start = 0
        while start < previous.count {
            var end = start + 1
            while end < previous.count && previous[end].text("batch_id") == previous[start].text("batch_id") { end += 1 }
            let rows = Array(previous[start..<end])
            if let match = index.longestMatch(rows.map { tokenIDs[CSVTransactionKey($0)] }, rowNumbers: rows.map { Int($0.number("row_number")) }) {
                blocks.append(zip(match.incoming, match.previous).map { (row: $0 + 2, target: rows[$1].text("target_id")) })
            }
            start = end
        }

        // Accepted rows anchor a resumed import, including when the user now
        // skips them. Do not reuse their target for another identical purchase.
        let accepted = try db.query("""
            SELECT i.row_number,l.transaction_id FROM import_rows i JOIN transaction_event_links l
            ON l.event_id=i.event_id AND l.unlinked_at_ms IS NULL WHERE i.batch_id=?
            """, [.text(batchID)])
        var targets = Dictionary(uniqueKeysWithValues: accepted.map { (Int($0.number("row_number")), $0.text("transaction_id")) })
        var usedTargets = Dictionary(accepted.map { ($0.text("transaction_id"), Int($0.number("row_number"))) }, uniquingKeysWith: min)
        for block in blocks.enumerated().sorted(by: { $0.element.count == $1.element.count ? $0.offset < $1.offset : $0.element.count > $1.element.count }).map(\.element) {
            // Never split a conflicting block into scattered individual matches.
            guard Set(block.map(\.target)).count == block.count,
                  block.allSatisfy({ (targets[$0.row] == nil || targets[$0.row] == $0.target)
                    && (usedTargets[$0.target] == nil || usedTargets[$0.target] == $0.row) }) else { continue }
            for (row, target) in block { targets[row] = target; usedTargets[target] = row }
        }
        return targets
    }
}
