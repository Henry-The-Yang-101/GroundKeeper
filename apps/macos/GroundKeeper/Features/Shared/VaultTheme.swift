import CoreText
import SwiftUI

/// Shared palette; the asset catalog supplies light, dark and increased-contrast variants.
enum AppStyle {
    static let accent = Color.accentColor
    static let ai = Color("VaultAI")
    static let pageBackground = Color("VaultBackground")
    static let surface = Color("VaultSurface")
    static let sidebar = Color("VaultSidebar")
    static let separator = Color("VaultLine")
    static let text = Color("VaultText")
    static let muted = Color("VaultMuted")
    static let selection = Color("VaultSelection")
    static let accentInk = Color("VaultAccentInk")
    // Native selected segments draw white labels in both appearances.
    static let controlAccent = Color("VaultControlAccent")
}

enum VaultTypography {
    // Xcode's synchronized resources are copied into the bundle's resource root.
    // Register for this process only: no font installation or network dependency.
    static func register() {
        guard let url = Bundle.main.url(forResource: "Fraunces", withExtension: "ttf") else {
            assertionFailure("The bundled Fraunces font is missing")
            return
        }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            let code = error.map { CFErrorGetCode($0.takeRetainedValue()) }
            assert(code == CTFontManagerError.alreadyRegistered.rawValue, "Could not register Fraunces")
        }
    }

    static let page = heading(34, relativeTo: .largeTitle)
    static let section = heading(21, relativeTo: .title2)
    static let sheet = heading(28, relativeTo: .title)
    static let wordmark = heading(22, relativeTo: .title2)
    static let welcome = heading(40, relativeTo: .largeTitle)

    private static func heading(_ size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        .custom("Fraunces-Regular", size: size, relativeTo: style).weight(.medium)
    }
}

enum VaultMotion {
    static let feedback = Animation.easeInOut(duration: 0.16)
    static let settle = Animation.spring(response: 0.28, dampingFraction: 0.88)
}

/// Native Button semantics and keyboard activation, with restrained press feedback.
struct BrassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .padding(.horizontal, controlSize == .large ? 18 : 12)
            .padding(.vertical, controlSize == .large ? 10 : 7)
            .foregroundStyle(isEnabled ? AppStyle.accentInk : AppStyle.muted)
            .background(isEnabled ? AppStyle.accent : AppStyle.separator, in: .rect(cornerRadius: 7))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : VaultMotion.feedback, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == BrassButtonStyle {
    static var brass: BrassButtonStyle { .init() }
}

struct VaultRowButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .background(hovered || configuration.isPressed ? AppStyle.selection : .clear, in: .rect(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(reduceMotion ? nil : VaultMotion.feedback, value: hovered)
            .animation(reduceMotion ? nil : VaultMotion.feedback, value: configuration.isPressed)
            .onHover { hovered = $0 }
    }
}

/// Reusable styling for sheets, including inherited native controls and form content.
struct VaultSheetStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(AppStyle.text)
            .tint(AppStyle.accent)
            .background(AppStyle.pageBackground)
            .presentationBackground(AppStyle.pageBackground)
    }
}

extension View {
    func vaultSheet() -> some View { modifier(VaultSheetStyle()) }
}
