import SwiftUI

/// Only this small subtree animates when a successful operation completes.
struct WorkspaceFeedbackView: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let feedback = session.feedback {
                Label(feedback.message, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(AppStyle.text)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(AppStyle.surface, in: .rect(cornerRadius: 9))
                    .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(AppStyle.separator) }
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                    .padding(.bottom, 20)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : VaultMotion.settle, value: session.feedback?.id)
        .task(id: session.feedback?.id) {
            guard session.feedback != nil else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            session.feedback = nil
        }
    }
}
