#if DEBUG
import SwiftUI
import Security
import Photos

/// Explicit diagnostic only. Every item uses a disposable service and account.
/// No production session, API, upload coordinator, or PhotoKit job is touched.
struct KeychainProbeReport: Codable {
    var group: String?
    var legacyPlaceholderStatus: Int32?
    var addRead = false
    var updateRead = false
    var accessibilityMatches = false
    var deleted = false
    var failureStatus: Int32?
    var failure: String?
    var fullPhotosAccess: Bool?
    var existingInProcessAlbums: [String]?
    var automaticConfigured: Bool?
    var configuredAlbumID: String?
}
@MainActor enum KeychainProbe {
    static func run(id: UUID) -> KeychainProbeReport {
        let service = "com.xdjs.InProcess.keychain-probe.\(id.uuidString)"
        let store = KeychainSessionStore(shared: true, service: service, accountOverride: "disposable")
        var report = KeychainProbeReport(group: store.sharedGroup)
        var legacy: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "legacy-placeholder",
            kSecAttrAccessGroup as String: "missing-shared-keychain-group"]
        legacy[kSecValueData as String] = Data("synthetic-no-authority".utf8)
        report.legacyPlaceholderStatus = SecItemAdd(legacy as CFDictionary, nil)
        legacy.removeValue(forKey: kSecValueData as String)
        if report.legacyPlaceholderStatus == errSecSuccess { SecItemDelete(legacy as CFDictionary) }
        defer { try? store.clear() }
        do {
            let initial = SavedSession(token: "synthetic-no-authority-1", email: "probe@example.invalid", expiresAt: Date().addingTimeInterval(60))
            try store.save(initial)
            report.addRead = try store.load()?.token == initial.token
            let updated = SavedSession(token: "synthetic-no-authority-2", email: "probe@example.invalid", expiresAt: Date().addingTimeInterval(120))
            try store.save(updated)
            report.updateRead = try store.load()?.token == updated.token
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: "disposable",
                kSecAttrAccessGroup as String: store.sharedGroup ?? "",
                kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var attributes: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &attributes)
            report.accessibilityMatches = status == errSecSuccess &&
                (attributes as? [String: Any])?[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
            try store.clear()
            report.deleted = try store.load() == nil
        } catch {
            report.failureStatus = (error as? KeychainFailure)?.status
            report.failure = error.localizedDescription
        }
        return report
    }
}

struct KeychainProbeView: View {
    @State private var result = "Checking secure storage…"
    var body: some View {
        Text(result).padding().task {
            #if !targetEnvironment(simulator)
            var report = KeychainProbe.run(id: UUID())
            // Read-only inventory of setup state. No permission request, creation,
            // selection, credential refresh, enablement, or upload is performed.
            report.fullPhotosAccess = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
            if report.fullPhotosAccess == true {
                report.existingInProcessAlbums = try? PhotosAlbumAccess().albums().map(\.id)
            }
            if let state = try? UploadStore.shared().read() {
                report.automaticConfigured = state.configuration != nil
                report.configuredAlbumID = state.configuration?.albumID
            }
            do {
                let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(report).write(to: folder.appendingPathComponent("KeychainProbe.json"), options: [.atomic, .completeFileProtection])
                result = report.deleted && report.updateRead && report.addRead && report.accessibilityMatches ? "Secure storage check passed. Reopen In Process normally." : "Secure storage check did not pass."
            } catch { result = "Could not export the secure storage check." }
            #else
            result = "Use isolated Keychain integration tests in Simulator."
            #endif
        }
    }
}
#endif
