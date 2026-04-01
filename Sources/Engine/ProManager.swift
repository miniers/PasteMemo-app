import SwiftUI

@MainActor
final class ProManager: ObservableObject {
    static let shared = ProManager()

    @Published private(set) var isPro: Bool = true

    /// Feature flag: set to true when automation is ready for release
    static let AUTOMATION_ENABLED = true

    static let RETENTION_KEY = "retentionDays"

    func canUseContentType(_ type: ClipContentType) -> Bool { true }

    var canUseAppFilter: Bool { true }
    var canUseAutomation: Bool { true }

    /// Single source of truth for retention cutoff. Returns nil when retention is "forever".
    var retentionCutoffDate: Date? {
        let userDays = UserDefaults.standard.integer(forKey: Self.RETENTION_KEY)
        guard userDays > 0 else { return nil }
        return Calendar.current.date(byAdding: .day, value: -userDays, to: Date())
    }

    private init() {}

    func applyRemoteConfig(encryptedBase64: String) {}
}
