import SwiftUI

struct SettingsView: View {
    @Environment(PreviewWorkspace.self) private var workspace
    @AppStorage("appearance") private var appearance = AppAppearance.system
    @State private var sampleAction: SampleAction?

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
            } header: {
                Text("Appearance")
            } footer: {
                Text("System follows your Mac’s light or dark appearance. Accessibility settings are inherited from macOS.")
            }
            Section {
                LabeledContent("Workspace", value: "Sample data")
                LabeledContent("Transaction storage", value: "This session only")
                HStack {
                    Button("Restore sample transactions…") { sampleAction = .restore }
                    Button("Clear sample transactions…") { sampleAction = .clear }
                }
            } header: {
                Text("Preview workspace")
            } footer: {
                Text("Transaction edits are discarded when you quit. Appearance is the only saved preference. Report and planning figures remain fixed examples.")
            }
            Section {
                DisclosureGroup("Classification options") {
                    provider("Fine-tuned Laya", detail: "Local decision model")
                    provider("Fine-tuned Qwen", detail: "Local language model")
                    provider("Apple Intelligence Cloud", detail: "Cloud processing through an Apple Shortcut")
                    provider("Council", detail: "Combines local providers and Apple cloud processing")
                }
                LabeledContent("Provider status", value: "Not connected")
            } header: {
                Text("Categorization")
            } footer: {
                Text("Automatic transaction categorization is not connected. The local diagnostics below can load a model and classify explicitly entered sample text.")
            }
            ClassifierDiagnosticsView()
            Section("Accounts & rules") {
                DisclosureGroup("Sample accounts") {
                    LabeledContent("Everyday card", value: "CAD · Credit card")
                    LabeledContent("Chequing", value: "CAD · Bank account")
                    LabeledContent("Cash", value: "CAD · Cash")
                }
                LabeledContent("Merchant rules", value: "Not configured")
                Text("Editing a category changes only that sample transaction. Card mappings and reusable merchant rules will be configured here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Encrypted storage", value: "Not connected")
                LabeledContent("Touch ID & auto-lock", value: "Not connected")
                LabeledContent("Recovery & backups", value: "Not connected")
            } header: {
                Text("Security")
            } footer: {
                Text("Security controls will become available with encrypted storage. This preview is intended for fictional data only.")
            }
            Section {
                LabeledContent("GroundKeeper", value: "macOS interface preview")
                Text("A quieter way to keep track of spending.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 850)
        .frame(maxWidth: .infinity)
        .background(AppStyle.pageBackground)
        .confirmationDialog(sampleAction?.title ?? "Update sample workspace?", isPresented: Binding(
            get: { sampleAction != nil }, set: { if !$0 { sampleAction = nil } }
        ), titleVisibility: .visible) {
            Button(sampleAction?.button ?? "Continue", role: .destructive) {
                if sampleAction == .restore { workspace.reset() } else { workspace.transactions = [] }
                sampleAction = nil
            }
            Button("Cancel", role: .cancel) { sampleAction = nil }
        } message: {
            Text("This replaces your current sample transaction edits. Fixed report examples will stay the same.")
        }
    }

    private func provider(_ name: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }
}

private enum SampleAction {
    case restore, clear
    var title: String { self == .restore ? "Restore the sample transactions?" : "Clear all sample transactions?" }
    var button: String { self == .restore ? "Restore samples" : "Clear samples" }
}
