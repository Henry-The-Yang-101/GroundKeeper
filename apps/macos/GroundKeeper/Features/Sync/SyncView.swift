import SwiftUI

struct SyncView: View {
    @Environment(PreviewWorkspace.self) private var workspace

    var body: some View {
        PageContent {
            PageHeading(title: "Sync", subtitle: "Capture on your iPhone. Review on your Mac.")
            Surface {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: "icloud").font(.system(size: 32)).foregroundStyle(AppStyle.accent)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connect your capture folder").font(.title3.weight(.semibold))
                        Text("GroundKeeper will use your iCloud Drive capture folder to receive transactions from Apple Shortcuts.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Label("Not connected", systemImage: "minus.circle").font(.callout)
                    }
                    Spacer(minLength: 0)
                }
                Divider()
                Text("Folder access and syncing are not available in this interface preview.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Surface {
                SectionHeading(title: "How capture will work")
                CaptureStep(number: "1", title: "Capture a transaction", detail: "An iPhone Shortcut saves the transaction to your capture folder.", symbol: "iphone")
                Divider()
                CaptureStep(number: "2", title: "Receive it on your Mac", detail: "New files arrive through iCloud Drive.", symbol: "icloud")
                Divider()
                CaptureStep(number: "3", title: "Review the details", detail: "Confirm anything that needs your input before it joins your spending history.", symbol: "checklist")
            }
            Surface {
                HStack(alignment: .center, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Bring your own history").font(.headline)
                        Text("Preview a CSV mapping and review screen with sample rows.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Preview CSV import…") { workspace.showingImportPreview = true }
                }
            }
            Surface {
                SectionHeading(title: "Activity")
                UnavailableFeature(title: "No sync activity yet", symbol: "clock", description: "Once connected, capture status, import history, and any files needing attention will appear here.")
                    .frame(minHeight: 170)
            }
        }
    }
}

private struct CaptureStep: View {
    let number: String
    let title: String
    let detail: String
    let symbol: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(.callout.weight(.semibold))
                .frame(width: 26, height: 26).background(.quaternary, in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(title).fontWeight(.medium)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 24)
        }
    }
}
