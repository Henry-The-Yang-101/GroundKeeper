import Foundation

/// Preview runs use a disposable vault and separate preferences; they never reconfigure the real ledger.
enum AppPreferences {
    /// Stored names are stable across app updates and isolated preview suites.
    enum Key {
        static let activeCouncilShortcut = "activeCouncilShortcut"
        static let appearance = "appearance"
        static let captureFolderBookmark = "captureFolderBookmark"
        static let captureFolderIsExact = "captureFolderIsExact"
        static let captureFolderPath = "captureFolderPath"
        static let captureFolderWritable = "captureFolderWritable"
        static let classifierModelBookmark = "classifierModelBookmark"
        static let classifierProvider = "classifierProvider"
        static let classifierShortcutName = "classifierShortcutName"
        static let insightSensitivity = "insightSensitivity"
        static let ollamaModelName = "ollamaModelName"
        static let ollamaSelectedModel = "ollamaSelectedModel"
        static let phoneSetupConfirmed = "phoneSetupConfirmed"
        static let reportCurrency = "reportCurrency"
        static let reportTimezone = "reportTimezone"
        static let reportWeekStart = "reportWeekStart"
        static let setupCompleted = "setupCompleted"
        static let setupStep = "setupStep"
        static let vaultConvenienceUnlock = "vaultConvenienceUnlock"
        static let vaultProtectionChosen = "vaultProtectionChosen"
        static func councilPackage(_ backend: String) -> String { "councilPackage.\(backend)" }
        static func activeCouncilPackage(_ backend: String) -> String { "activeCouncilPackage.\(backend)" }
    }

    static let previewSessionID = UUID().uuidString
    static let isReceiptSmoke = CommandLine.arguments.contains("--receipt-smoke") || Bundle.main.object(forInfoDictionaryKey: "GKReceiptSmoke") as? Bool == true
    static let isSetupPreview = CommandLine.arguments.contains("--setup-preview") || isReceiptSmoke
    // Foundation documents UserDefaults as thread-safe. The reference is immutable.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard isSetupPreview else { return .standard }
        let preferences = UserDefaults(suiteName: "com.groundkeeper.setup-preview.\(previewSessionID)")!
        preferences.set(false, forKey: AppPreferences.Key.setupCompleted)
        preferences.set(false, forKey: AppPreferences.Key.vaultProtectionChosen)
        preferences.set("manual", forKey: AppPreferences.Key.classifierProvider)
        if let index = CommandLine.arguments.firstIndex(of: "--setup-preview-step"), CommandLine.arguments.indices.contains(index + 1), let step = Int(CommandLine.arguments[index + 1]) {
            preferences.set(step, forKey: AppPreferences.Key.setupStep)
        }
        return preferences
    }()
}
