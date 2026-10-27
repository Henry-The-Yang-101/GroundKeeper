import SwiftUI
import GroundKeeperCore

struct MerchantManagementSheet: View {
    @Environment(AppWorkspace.self) private var workspace
    @Environment(TransactionWorkspace.self) private var transactionState
    @Environment(\.dismiss) private var dismiss
    @State private var merchants: [Merchant] = []
    @State private var names: [MerchantName] = []
    @State private var search = ""
    @State private var selection: String?
    @State private var error: String?
    @State private var refresh = 0
    @State private var page = 0
    private var matches: [MerchantName] { names.filter { search.isEmpty || $0.label.localizedStandardContains(search) } }
    private var visibleNames: [MerchantName] { Array(matches.dropFirst(page * 100).prefix(100)) }
    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: "Merchant names & groups")
            VStack(alignment: .leading, spacing: 16) {
                Text("Case and spacing match automatically. Branch numbers, punctuation and payment prefixes stay separate until you confirm a grouping.")
                    .foregroundStyle(AppStyle.muted).fixedSize(horizontal: false, vertical: true)
                TextField("Search statement names", text: $search).textFieldStyle(.roundedBorder).onChange(of: search) { page = 0 }
                if let error { Text(error).foregroundStyle(.red) }
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading) {
                        List(selection: $selection) {
                            ForEach(visibleNames) { name in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(name.label).lineLimit(2)
                                    Text("\(name.transactionCount) \(name.transactionCount == 1 ? "entry" : "entries") · \(name.confirmed ? "Confirmed grouping" : "Exact name")")
                                        .font(.caption).foregroundStyle(AppStyle.muted)
                                }.tag(name.key)
                            }
                        }.frame(minWidth: 220)
                        HStack {
                            Button("Previous") { page -= 1 }.disabled(page == 0)
                            Text("\(matches.count) \(matches.count == 1 ? "name" : "names")").font(.caption)
                            Button("Next") { page += 1 }.disabled((page + 1) * 100 >= matches.count)
                        }
                    }
                    if let name = visibleNames.first(where: { $0.key == selection }) {
                        ScrollView {
                            MerchantGroupingEditor(name: name, merchants: merchants) { refresh += 1 }.id(name.key + name.merchantID + String(name.confirmed))
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }.frame(minWidth: 270, maxWidth: .infinity)
                    } else {
                        Text("Select a statement name to review its merchant grouping.").foregroundStyle(AppStyle.muted)
                            .frame(minWidth: 270, maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.padding(.horizontal, 24).padding(.bottom, 20)
            SheetFooter { Spacer(); SheetDoneButton() }
        }
        .frame(minWidth: 660, idealWidth: 800, minHeight: 540, idealHeight: 660)
        .task(id: "\(refresh)|\(transactionState.reportingRevision)") {
            do {
                let directory = try await workspace.merchantDirectory(); try Task.checkCancellation()
                merchants = directory.merchants; names = directory.names; error = nil
            } catch is CancellationError { return }
            catch { self.error = error.localizedDescription }
        }
        .onChange(of: visibleNames.map(\.key)) {
            if !visibleNames.contains(where: { $0.key == selection }) { selection = nil }
        }
        .onChange(of: workspace.ready) { if !workspace.ready { names = []; merchants = []; dismiss() } }
    }
}

private struct MerchantGroupingEditor: View {
    @Environment(AppWorkspace.self) private var workspace
    @Environment(TransactionWorkspace.self) private var transactionState
    let name: MerchantName
    let merchants: [Merchant]
    let changed: () -> Void
    @State private var target = ""
    @State private var newName = ""
    @State private var created: Merchant?
    @State private var busy = false
    @State private var error: String?
    private var choices: [Merchant] { merchants + (created.map { [$0] } ?? []) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(name.label).font(.headline).textSelection(.enabled)
            Text("Currently: \(merchants.first { $0.id == name.merchantID }?.name ?? "Unassigned")").foregroundStyle(AppStyle.muted)
            Picker("Report as", selection: $target) {
                Text("Choose merchant").tag("")
                ForEach(choices) { Text($0.name).tag($0.id) }
            }
            DisclosureGroup("Create a group name") {
                VStack(alignment: .leading) {
                    TextField("Business name", text: $newName).textFieldStyle(.roundedBorder)
                    Button("Create name") {
                        busy = true
                        Task {
                            do {
                                let id = try await workspace.createMerchant(name: newName)
                                created = Merchant(id: id, name: newName.trimmingCharacters(in: .whitespacesAndNewlines)); target = id
                            } catch { self.error = error.localizedDescription }
                            busy = false
                        }
                    }.disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(.top, 8)
            }
            if !target.isEmpty, target != name.merchantID {
                Text("Confirming moves \(name.transactionCount) recorded \(name.transactionCount == 1 ? "entry" : "entries") with this statement name to \(choices.first { $0.id == target }?.name ?? "this merchant"), and applies to future matching imports. Per-entry corrections stay as you set them.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Button("Confirm grouping") { save(target) }.buttonStyle(.borderedProminent)
            }
            if name.confirmed {
                Button("Undo this name’s grouping") { save(nil) }
                Text("Undo restores the original name for existing automatic matches and future imports.")
                    .font(.caption).foregroundStyle(AppStyle.muted)
            }
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }.disabled(busy)
    }
    private func save(_ id: String?) {
        busy = true
        Task {
            do { try await workspace.groupMerchant(name, into: id); changed() }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

struct TransactionMerchantSheet: View {
    @Environment(AppWorkspace.self) private var workspace
    @Environment(TransactionWorkspace.self) private var transactionState
    @Environment(\.dismiss) private var dismiss
    let entry: SpendingEntry
    @State private var transaction: TransactionMerchant?
    @State private var merchants: [Merchant] = []
    @State private var selection = ""
    @State private var automatic = true
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: "Merchant for this entry")
            VStack(alignment: .leading, spacing: 16) {
                Text(entry.description).font(.headline)
                Text("\(entry.day) · This correction applies only to this entry. Use Merchant names & groups to combine branches and future imports.")
                    .foregroundStyle(AppStyle.muted).fixedSize(horizontal: false, vertical: true)
                Toggle("Use the statement name’s automatic grouping", isOn: $automatic)
                if !automatic {
                    Picker("Merchant", selection: $selection) {
                        Text("Unassigned merchant").tag("")
                        ForEach(merchants) { Text($0.name).tag($0.id) }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.padding(24)
            SheetFooter {
                Spacer(); Button("Cancel") { dismiss() }
                Button("Save") {
                    guard let transaction else { return }; busy = true
                    Task {
                        do { try await workspace.setMerchant(transaction, merchantID: selection.isEmpty ? nil : selection, automatic: automatic); dismiss() }
                        catch { self.error = error.localizedDescription; busy = false }
                    }
                }.disabled(transaction == nil || busy).keyboardShortcut(.defaultAction)
            }
        }.frame(width: 520).disabled(busy)
        .task {
            do {
                let directory = try await workspace.merchantDirectory(), result = try await workspace.transactionMerchant(id: entry.id)
                try Task.checkCancellation()
                merchants = directory.merchants; transaction = result; selection = result.merchantID ?? ""; automatic = !result.overridden
            } catch { self.error = error.localizedDescription }
        }
        .onChange(of: workspace.ready) { if !workspace.ready { dismiss() } }
    }
}
