import SwiftUI

struct MerchantSearchSettingsView: View {
    let workspace: AppWorkspace
    var body: some View {
        Toggle("Use DuckDuckGo merchant search", isOn: Binding(get: { workspace.merchantSearchEnabled }, set: workspace.setMerchantSearch))
            .disabled(!workspace.ready || workspace.saving)
        Text("Off by default. Search runs from this Mac using DDGS and sends a cleaned merchant name or transaction description, plus optional city/region, to DuckDuckGo. No API key or GroundKeeper search server is used. With an Apple Intelligence Shortcut, retrieved context may also be processed in Apple's cloud.")
            .font(.caption).foregroundStyle(AppStyle.muted)
        Text("Experimental. Accuracy improvements are not established; every suggestion requires review.")
            .font(.caption).foregroundStyle(AppStyle.muted)
        if workspace.merchantSearchEnabled {
            TextField("Search city/region (optional)", text: Binding(get: { workspace.merchantSearchLocality }, set: { workspace.merchantSearchLocality = $0 }))
                .onSubmit(workspace.saveMerchantSearchLocality)
                .disabled(workspace.processing || workspace.saving)
            Button("Save search locality", action: workspace.saveMerchantSearchLocality)
                .disabled(workspace.processing || workspace.saving)
            Text("Uncached searches are paced approximately 11 seconds apart; model inference adds processing time. Cached merchants skip the search wait. DuckDuckGo may temporarily block searches.")
                .font(.caption).foregroundStyle(AppStyle.muted)
            if !workspace.merchantSearchStatus.isEmpty { Text(workspace.merchantSearchStatus).font(.caption).accessibilityLabel("Merchant search: \(workspace.merchantSearchStatus)") }
            Button("Clear search cache", action: workspace.clearMerchantSearchCache)
                .disabled(workspace.processing || workspace.saving)
        }
    }
}
