import SwiftUI

struct VaultFormSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Section { content } header: {
            Text(title).font(VaultTypography.section).foregroundStyle(AppStyle.text)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

struct PageHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(VaultTypography.page).foregroundStyle(AppStyle.text)
                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            Text(subtitle).foregroundStyle(AppStyle.muted).fixedSize(horizontal: false, vertical: true)
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
            .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(AppStyle.separator, lineWidth: 1)
            }
    }
}

struct SectionHeading: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                heading.fixedSize()
                Spacer(minLength: 0)
                if let detail { Text(detail).font(.caption).foregroundStyle(AppStyle.muted).fixedSize() }
            }
            VStack(alignment: .leading, spacing: 6) {
                heading
                if let detail { Text(detail).font(.caption).foregroundStyle(AppStyle.muted) }
            }
        }
    }

    private var heading: some View {
        Text(title).font(VaultTypography.section).foregroundStyle(AppStyle.text).accessibilityAddTraits(.isHeader)
    }
}

struct ReviewBadge: View {
    var body: some View {
        Label("Needs review", systemImage: "circle.dashed")
            .font(.caption)
            .foregroundStyle(AppStyle.accent)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(AppStyle.selection, in: .rect(cornerRadius: 5))
    }
}

struct CategoryIcon: View {
    let category: SpendingCategory
    var body: some View {
        Image(systemName: category.symbol)
            .font(.system(size: 16))
            .foregroundStyle(AppStyle.muted)
            .frame(width: 36, height: 36)
            .background(AppStyle.pageBackground, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}

struct UnavailableFeature: View {
    let title: String
    let symbol: String
    let description: String
    var body: some View {
        ContentUnavailableView {
            Label {
                Text(title).font(VaultTypography.section)
            } icon: {
                Image(systemName: symbol).foregroundStyle(AppStyle.accent)
            }
        } description: {
            Text(description).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct Metric: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.medium)).monospacedDigit()
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : VaultMotion.feedback, value: value)
        }
        .accessibilityElement(children: .combine)
    }
}
