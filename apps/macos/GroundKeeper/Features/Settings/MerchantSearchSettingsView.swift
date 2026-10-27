import SwiftUI

struct MerchantSearchSettingsView: View {
    @Environment(CaptureWorkspace.self) private var captureState
    @Environment(WorkspaceSession.self) private var session
    @Environment(MerchantWorkspace.self) private var merchantState
    var body: some View {
        Toggle("Use DuckDuckGo merchant search", isOn: Binding(get: { merchantState.merchantSearchEnabled }, set: merchantState.setMerchantSearch))
            .disabled(!session.ready || session.saving)
        Text("On by default. Search runs from this Mac using DDGS and sends a cleaned merchant name or transaction description, plus optional city/region, to DuckDuckGo. No API key or GroundKeeper search server is used. With an Apple Intelligence Shortcut, retrieved context may also be processed in Apple's cloud.")
            .font(.caption).foregroundStyle(AppStyle.muted)
        Text("Experimental. Accuracy improvements are not established; every suggestion requires review.")
            .font(.caption).foregroundStyle(AppStyle.muted)
        if merchantState.merchantSearchEnabled {
            TextField("Search city/region (optional)", text: Binding(get: { merchantState.merchantSearchLocality }, set: { merchantState.merchantSearchLocality = $0 }))
                .onSubmit(merchantState.saveMerchantSearchLocality)
                .disabled(captureState.processing || session.saving)
            Button("Save search locality", action: merchantState.saveMerchantSearchLocality)
                .disabled(captureState.processing || session.saving)
            Text("Uncached searches are paced approximately 11 seconds apart; model inference adds processing time. Cached merchants skip the search wait. DuckDuckGo may temporarily block searches.")
                .font(.caption).foregroundStyle(AppStyle.muted)
            if !merchantState.merchantSearchStatus.isEmpty { Text(merchantState.merchantSearchStatus).font(.caption).accessibilityLabel("Merchant search: \(merchantState.merchantSearchStatus)") }
            Button("Clear search cache", action: merchantState.clearMerchantSearchCache)
                .disabled(captureState.processing || session.saving)
        }
    }
}
