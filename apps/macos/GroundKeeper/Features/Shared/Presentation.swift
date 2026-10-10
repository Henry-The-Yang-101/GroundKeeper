import SwiftUI

enum AppStyle {
    static let accent = Color.accentColor
    static let pageBackground = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
}

struct PageHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.largeTitle.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text(subtitle).foregroundStyle(.secondary)
        }
    }
}

struct PageContent<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) { content }
                .frame(maxWidth: 1080, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity)
        }
        .background(AppStyle.pageBackground)
    }
}

struct Surface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 18) { content }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
            }
    }
}

struct SectionHeading: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            Spacer()
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct ReviewBadge: View {
    var body: some View {
        Label("Needs review", systemImage: "circle.dashed")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
    }
}

struct CategoryIcon: View {
    let category: SpendingCategory
    var body: some View {
        Image(systemName: category.symbol)
            .font(.system(size: 16))
            .foregroundStyle(AppStyle.accent)
            .frame(width: 36, height: 36)
            .background(AppStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityHidden(true)
    }
}

struct UnavailableFeature: View {
    let title: String
    let symbol: String
    let description: String
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(description).frame(maxWidth: 380)
        }
    }
}
