#!/bin/bash
# Exercise the app's actual fixture against the built core and its real report engine.
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
products="$repo_dir/.local/macos/DerivedData/Build/Products/Debug"
[[ -f "$products/GroundKeeperCore.o" ]] || { echo 'Run ./apps/macos/build.sh first.' >&2; exit 1; }
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/groundkeeper-demo-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
ln -s "$products/GroundKeeperCore_GroundKeeperCore.bundle" "$check_dir/GroundKeeperCore_GroundKeeperCore.bundle"
cat > "$check_dir/Check.swift" <<'SWIFT'
import Foundation
import GroundKeeperCore

@main struct DemoCheck {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw LedgerError.invalid(message) }
    }
    static func main() async {
        do { try await check() }
        catch {
            FileHandle.standardError.write(Data("Spending demo check failed: \(error)\n".utf8))
            exit(1)
        }
    }
    static func check() async throws {
        let calendar = try ReportCalendar(timezone: "America/Toronto")
        // Exercise the default walkthrough, a year boundary, DST, and leap day.
        for day in ["2026-10-24", "2027-01-01", "2027-03-15", "2028-02-29"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("GroundKeeper-Demo-Check-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try LedgerStore(url: root.appendingPathComponent("vault.sqlite"))
            let now = calendar.date(day)
            try await SpendingPreview.seed(store, now: now)
            let snapshot = try await store.snapshot(limit: 5000)
            try require(snapshot.totalTransactions > 500, "Demo should exceed one UI page")
            try require(snapshot.reviews.isEmpty && snapshot.transactions.allSatisfy { !$0.needsReview && $0.sources == "csv" }, "Import must be completely reconciled and reviewed")
            let purchases = snapshot.transactions.filter { $0.type == "expense" }
            let refunds = snapshot.transactions.filter { $0.type == "refund" }
            let gross = purchases.reduce(Int64(0)) { $0 + abs($1.amountMinor) }
            let refundTotal = refunds.reduce(Int64(0)) { $0 + abs($1.amountMinor) }
            var kinds: Set<String> = []
            for period in [ReportPeriod.month, .days90, .all] {
                let ranges = try calendar.ranges(period, now: now, firstDay: snapshot.transactions.map(\.occurredOn).min())
                let filter = SpendingFilter(range: ranges.0, baseline: ranges.1, timezone: calendar.timezone)
                let report = try await store.spendingReport(filter, now: now)
                kinds.formUnion(report.findings.map(\.kind))
                if period == .all {
                    try require(report.totals.purchases == purchases.count && report.totals.gross == gross && report.totals.net == gross - refundTotal,
                                "Reports must include the full ledger and exclude income/transfers")
                }
                let repeated = try await store.spendingReport(filter, now: now)
                try require(report.findings == repeated.findings, "Findings must be repeatable")
            }
            let expected: Set<String> = ["weekly_trend", "weekly_shift", "merchant_outlier"]
            try require(kinds.isSuperset(of: expected), "Demo should generate trend, shift, and outlier findings: \(kinds)")
            if day == "2026-10-24" {
                try require(kinds.contains("merchant_change") && kinds.contains("merchant_majority"), "Default walkthrough should include merchant changes and concentration")
            }
            let merchants = try await store.merchants()
            try require(merchants.filter { $0.name.hasPrefix("Neighbourhood Café") }.count == 3, "Café branches must remain separate")
            try require(try await store.integrityCheck(), "Vault integrity failed")
            await store.close()
            print("PASS \(day): \(snapshot.totalTransactions) imported rows; \(kinds.sorted().joined(separator: ", "))")
        }
    }
}
SWIFT
xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macos26.2" \
  -I "$products" -F "$products" -framework SQLCipher \
  -Xlinker -rpath -Xlinker "$products" "$products/GroundKeeperCore.o" \
  "$repo_dir/apps/macos/GroundKeeper/Preview/SpendingPreview.swift" "$check_dir/Check.swift" \
  -o "$check_dir/SpendingDemoCheck"
"$check_dir/SpendingDemoCheck"
