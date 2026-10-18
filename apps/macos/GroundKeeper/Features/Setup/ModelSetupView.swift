import SwiftUI
import AppKit

struct ModelSetupView: View {
    @Environment(AppWorkspace.self) private var workspace
    @Bindable var installer: ModelInstaller
    private var models: [ModelCatalog.Model] { (try? ModelCatalog.bundled().models) ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(models) { model in
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: model.id == "laya" ? "leaf" : "cpu").font(.title).foregroundStyle(.tint)
                        Text(model.title).font(.title2.bold())
                        Text(model.id == "laya" ? "A focused local classifier, running on your Mac." : "Local language-model suggestions, running on your Mac.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        Text(ByteCountFormatter.string(fromByteCount: model.downloadBytes, countStyle: .file) + " download").font(.caption)
                        if let url = installer.installed[model.id] {
                            Button("Use \(model.title)") { workspace.useInstalledModel(url) }.disabled(workspace.saving || !workspace.ready)
                        } else {
                            Button("Install \(model.title)") { installer.install([model]) }.disabled(installer.busy)
                        }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
                }
            }
            HStack {
                Button("Install both models") { installer.install(models.filter { installer.installed[$0.id] == nil }) }
                    .disabled(installer.busy || models.allSatisfy { installer.installed[$0.id] != nil })
                Button("Choose existing package…", action: workspace.selectModel).disabled(workspace.saving || !workspace.ready || installer.busy)
            }
            if installer.busy { HStack { ProgressView().controlSize(.small); Text(installer.status); Button("Cancel", action: installer.cancel) } }
            else { Text(installer.status).font(.callout).foregroundStyle(.secondary) }
            if let error = installer.error { Text(error).foregroundStyle(.red) }
            Divider()
            Label("Apple Intelligence Cloud", systemImage: "apple.intelligence").font(.title3.bold())
            Text("No local model download needed. The included Shortcut uses Cloud with Broad World Knowledge. Description, direction, and currency go to the Shortcut and may be processed by Apple’s cloud service. Internet access, a compatible Mac, and Apple Intelligence are required; usage limits can apply.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Install Cloud Shortcut") { SetupResources.openShortcut("GK Categorize Cloud") }
                Button("Use Apple Intelligence Cloud", action: workspace.useShortcut).disabled(workspace.saving || !workspace.ready)
            }
            TextField("Installed Shortcut name", text: Binding(get: { workspace.shortcutName }, set: { workspace.shortcutName = $0 }))
                .textFieldStyle(.roundedBorder).disabled(workspace.saving)
            Text("In Shortcuts, check Use Model → Cloud, Broad World Knowledge on, Text output, and Follow Up off. Your installed Shortcut controls where inference runs.")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            HStack { Button("Use manual categorization", action: workspace.useManualCategorization).disabled(workspace.saving || workspace.processing)
                Spacer(); Text(workspace.classifierStatus).font(.caption).foregroundStyle(.secondary) }
            Text("Every model suggestion needs your review. You can change providers in Settings; GroundKeeper never switches to cloud automatically.")
                .font(.callout).foregroundStyle(.secondary)
        }.onAppear { installer.discover() }
    }
}

enum SetupResources {
    static func shortcut(_ name: String) -> URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Setup/\(name).shortcut"), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    @MainActor static func openShortcut(_ name: String) { if let url = shortcut(name) { NSWorkspace.shared.open(url) } }
}
