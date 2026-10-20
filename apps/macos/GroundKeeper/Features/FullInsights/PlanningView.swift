import SwiftUI

struct PlanningView: View {
    @State private var selection = PlanningSection.budgets

    var body: some View {
        PageContent {
            PageHeading(title: "Planning", subtitle: "Budgets, goals, and balances in one place.")
            Picker("Planning view", selection: $selection) {
                ForEach(PlanningSection.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).tint(AppStyle.controlAccent).labelsHidden().frame(maxWidth: 420)
            switch selection {
            case .budgets:
                Surface {
                    SectionHeading(title: "October budget", detail: "Example · CAD")
                    HStack(alignment: .firstTextBaseline) {
                        Text("$742.50").font(.largeTitle.weight(.semibold)).monospacedDigit()
                        Text("of $1,200").foregroundStyle(AppStyle.muted)
                        Spacer()
                    }
                    ProgressView(value: 742.5, total: 1200).tint(AppStyle.accent)
                        .accessibilityLabel("Example October budget")
                        .accessibilityValue("742 dollars and 50 cents of 1,200 dollars")
                    Text("$457.50 remaining in this example").foregroundStyle(AppStyle.muted)
                }
                availability("Budget limits", description: "Set overall or category limits and follow your spending through the month. Budget creation will be available when transaction storage is connected.")
            case .goals:
                Surface {
                    SectionHeading(title: "Emergency fund", detail: "Example · CAD")
                    HStack(alignment: .firstTextBaseline) {
                        Text("$1,500").font(.largeTitle.weight(.semibold)).monospacedDigit()
                        Text("of $5,000").foregroundStyle(AppStyle.muted)
                        Spacer()
                    }
                    ProgressView(value: 1500, total: 5000).tint(AppStyle.accent)
                        .accessibilityLabel("Example emergency fund")
                        .accessibilityValue("1,500 dollars of 5,000 dollars")
                    Text("Based on explicitly recorded contributions.").foregroundStyle(AppStyle.muted)
                }
                availability("Savings goals", description: "Give a goal a target and record contributions. Goal creation and funding will be available when storage is connected.")
            case .balances:
                Surface {
                    UnavailableFeature(title: "Your balances complete the picture", symbol: "building.columns", description: "Net worth needs dated asset and debt balances. Spending alone cannot tell you what you own or owe.")
                        .frame(minHeight: 220)
                }
                availability("Balance history", description: "Account balance entry, cash flow, and debt tracking are planned. No account balances are connected yet.")
            }
        }
    }

    private func availability(_ title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "info.circle").font(.headline)
            Text(description).foregroundStyle(AppStyle.muted).fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 4)
    }
}

private enum PlanningSection: String, CaseIterable, Identifiable {
    case budgets = "Budgets"
    case goals = "Goals"
    case balances = "Balances"
    var id: Self { self }
}
