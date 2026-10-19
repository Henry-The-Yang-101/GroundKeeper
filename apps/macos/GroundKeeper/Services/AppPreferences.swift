import Foundation

/// Preview runs use a disposable vault and separate preferences; they never reconfigure the real ledger.
enum AppPreferences {
    static let isSetupPreview = CommandLine.arguments.contains("--setup-preview")
    // Foundation documents UserDefaults as thread-safe. The reference is immutable.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard isSetupPreview else { return .standard }
        let preferences = UserDefaults(suiteName: "com.groundkeeper.setup-preview.\(ProcessInfo.processInfo.processIdentifier)")!
        preferences.set(false, forKey: "setupCompleted")
        preferences.set(false, forKey: "vaultProtectionChosen")
        preferences.set("manual", forKey: "classifierProvider")
        if let index = CommandLine.arguments.firstIndex(of: "--setup-preview-step"), CommandLine.arguments.indices.contains(index + 1), let step = Int(CommandLine.arguments[index + 1]) {
            preferences.set(step, forKey: "setupStep")
        }
        return preferences
    }()
}
