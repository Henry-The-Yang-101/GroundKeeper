import SwiftUI

enum PageLayout {
    static let inset: CGFloat = 28
    static let contentWidth: CGFloat = 1080
}

struct AlignedFormField<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 96, alignment: .leading)
            content.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SheetHeading: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(VaultTypography.sheet).accessibilityAddTraits(.isHeader)
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(AppStyle.muted) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading).padding(24)
    }
}

struct SheetFooter<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) { content }
                .padding(.horizontal, 24).padding(.vertical, 16)
        }.fixedSize(horizontal: false, vertical: true)
    }
}

struct SheetDoneButton: View {
    @Environment(\.dismiss) private var dismiss
    var disabled = false

    var body: some View {
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(disabled)
    }
}

/// Sparse evidence stays compact; expanded receipts scroll within the sheet.
struct ContentSizedScrollView<Content: View>: View {
    var maximumHeight: CGFloat = 420
    @ViewBuilder var content: Content
    @State private var contentHeight: CGFloat = 48

    var body: some View {
        ScrollView {
            content.frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }.frame(height: min(max(contentHeight, 48), maximumHeight))
    }
}

struct TransactionAmountField: View {
    @Binding var text: String

    var body: some View {
        TextField("Amount", text: $text)
            .accessibilityHint("Enter a positive amount without thousands separators. Choose Money out or Money in for its direction.")
    }
}

struct TransactionDirectionPicker: View {
    @Binding var isDebit: Bool

    var body: some View {
        Picker("Direction", selection: $isDebit) { Text("Money out").tag(true); Text("Money in").tag(false) }
    }
}

struct TransactionDatePicker: View {
    @Binding var date: Date

    var body: some View {
        DatePicker("Date", selection: $date, displayedComponents: .date)
            .environment(\.calendar, Calendar(identifier: .gregorian))
    }
}

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
                .frame(maxWidth: PageLayout.contentWidth, alignment: .leading)
                .padding(PageLayout.inset)
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
            Text(label).font(.caption).foregroundStyle(AppStyle.muted)
            Text(value).font(.title3.weight(.medium)).monospacedDigit()
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : VaultMotion.feedback, value: value)
        }
        .accessibilityElement(children: .combine)
    }
}
