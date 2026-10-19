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
            if let notices = Bundle.main.resourceURL?.appendingPathComponent("Setup/MODEL-NOTICES.txt") {
                Button("Model licenses and notices") { NSWorkspace.shared.open(notices) }.font(.caption)
            }
            if installer.busy { HStack { ProgressView().controlSize(.small); Text(installer.status); Button("Cancel", action: installer.cancel) } }
            else { Text(installer.status).font(.callout).foregroundStyle(.secondary) }
            if let error = installer.error { Text(error).foregroundStyle(.red) }
            Divider()
            AppleCloudProviderControls()
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

/// Reused in onboarding and Settings; refresh quota while visible without issuing inference requests.
struct AppleCloudProviderControls: View {
    @Environment(AppWorkspace.self) private var workspace
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            VStack(alignment: .leading, spacing: 12) {
                Label("Apple Private Cloud Compute", systemImage: "apple.intelligence").font(.title3.bold())
                Text("Categorize with Apple’s server model on macOS 27. Only description, direction, and currency are sent to Private Cloud Compute. No local model download or classifier Shortcut is needed.")
                    .foregroundStyle(.secondary)
                Text("Uses your daily Apple allowance. Availability depends on Apple Intelligence, internet access, and an approved PCC build. The native model does not offer the Shortcut’s Broad World Knowledge option.")
                    .font(.callout).foregroundStyle(.secondary)
                if let reason = AppleCloudClassifier.unavailableReason { Text(reason).font(.callout).foregroundStyle(.secondary) }
                Text(AppleCloudClassifier.quotaStatus).font(.callout)
                HStack {
                    Button("Use Apple Private Cloud Compute", action: workspace.useAppleCloud)
                        .disabled(workspace.saving || workspace.processing || !workspace.ready || AppleCloudClassifier.unavailableReason != nil)
                    if AppleCloudClassifier.hasQuotaOptions { Button("Apple access options", action: AppleCloudClassifier.showQuotaOptions) }
                }
            }.fixedSize(horizontal: false, vertical: true)
        }
    }
}
