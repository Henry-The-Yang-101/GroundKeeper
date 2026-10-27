import SwiftUI

struct CouncilSetupView: View {
    @Environment(AppWorkspace.self) private var workspace
    @Environment(CaptureWorkspace.self) private var captureState
    @Environment(ClassifierWorkspace.self) private var classifier
    var installed: [String: URL] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Model council", systemImage: "person.3").font(VaultTypography.section)
            Text("Qwen, Laya and Apple Intelligence each get one vote. Two matching decisions produce a suggestion. Every result needs your review.")
                .foregroundStyle(AppStyle.muted).fixedSize(horizontal: false, vertical: true)
            packageRow("Qwen", backend: "qwen_mlx", selected: classifier.councilQwenURL, installed: installed["qwen"])
            packageRow("Laya", backend: "laya_mps", selected: classifier.councilLayaURL, installed: installed["laya"])
            TextField("Council Apple Intelligence Shortcut", text: Binding(get: { classifier.shortcutName }, set: { classifier.shortcutName = $0 }))
                .textFieldStyle(.roundedBorder)
            Text("Enabling Council includes Apple Intelligence processing. Transaction descriptions and permitted context go to the selected Shortcut and may be processed in Apple’s cloud. Check its Use Model action before enabling. Usage limits can apply.")
                .font(.callout).foregroundStyle(AppStyle.muted).fixedSize(horizontal: false, vertical: true)
            Text("DuckDuckGo search and sharing receipt text with Apple keep their separate settings. Council reuses one saved search result across its members.")
                .font(.caption).foregroundStyle(AppStyle.muted).fixedSize(horizontal: false, vertical: true)
            Button(classifier.classifierProvider == "council" ? "Apply council setup" : "Enable Council with Apple Intelligence", action: classifier.useCouncil)
                .disabled(!workspace.ready || !classifier.councilReadyToConfigure || captureState.processing || workspace.saving)
            if !classifier.councilReadyToConfigure {
                Text("Select both local packages and enter a Shortcut name to enable Council. Packages are verified when you apply setup.")
                    .font(.caption).foregroundStyle(AppStyle.muted)
            }
            if classifier.classifierProvider == "council" {
                Text("Council selected · equal votes. Apply setup to use changed packages or a different Shortcut.")
                    .font(.caption).foregroundStyle(AppStyle.muted)
            }
            DisclosureGroup("Selected package locations") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Qwen: \(classifier.councilQwenURL?.path ?? "Choose a package")")
                    Text("Laya: \(classifier.councilLayaURL?.path ?? "Choose a package")")
                }.font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }.disabled(captureState.processing || workspace.saving)
    }
    private func packageRow(_ title: String, backend: String, selected: URL?, installed: URL?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(title) · \(selected == nil ? "Package needed" : "Package selected")").font(.headline)
            HStack {
                Button("Choose \(title) package…") { classifier.chooseCouncilPackage(backend) }
                if let installed {
                    Button("Use installed \(title)") { classifier.setCouncilPackage(installed, backend: backend) }
                }
            }
        }
    }
}
