import XCTest
import Security
@testable import InProcess

@MainActor final class KeychainIntegrationTests: XCTestCase {
    func testCredentialVaultReadbackSharedReadersAndStaleWriterProtection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let item = KeychainSessionStore(shared: true, service: "com.xdjs.InProcess.keychain-probe.\(UUID().uuidString)", accountOverride: "disposable-vault")
        defer { try? item.clear(); try? FileManager.default.removeItem(at: root) }
        let host = KeychainCredentialVault(item: item, lockDirectory: root, legacy: [])
        let otherProcess = KeychainCredentialVault(item: item, lockDirectory: root, legacy: [])
        let original = try host.snapshot()
        let key = SavedSession(token: "art_sk_synthetic_disposable", email: "fixture@example.invalid", expiresAt: .distantPast, kind: .artistKey, owner: "0x1111111111111111111111111111111111111111")
        try host.update(expected: original.revision) { $0.active = key }
        XCTAssertEqual(try VaultSessions(vault: otherProcess).load(), key)
        XCTAssertThrowsError(try otherProcess.update(expected: original.revision) { $0.active = nil })
        try VaultSessions(vault: host).clear()
        XCTAssertNil(try VaultSessions(vault: otherProcess).load())
        XCTAssertTrue(try otherProcess.snapshot().signedOut)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: item.service,
            kSecAttrAccount as String: "disposable-vault", kSecAttrAccessGroup as String: try XCTUnwrap(item.sharedGroup), kSecReturnAttributes as String: true]
        var attributes: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &attributes), errSecSuccess)
        XCTAssertEqual((attributes as? [String: Any])?[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.contains("json") })
    }
    func testCredentialVaultMigratesDisposableLegacyWithoutResurrectionAfterSignOut() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = "com.xdjs.InProcess.keychain-probe.\(UUID().uuidString)"
        let old = KeychainSessionStore(service: service, accountOverride: "legacy")
        let item = KeychainSessionStore(shared: true, service: service, accountOverride: "vault")
        defer { try? old.clear(); try? item.clear(); try? FileManager.default.removeItem(at: root) }
        let session = SavedSession(token: "synthetic-only", email: "fixture@example.invalid", expiresAt: .distantFuture)
        try old.save(session)
        let vault = KeychainCredentialVault(item: item, lockDirectory: root, legacy: [old])
        XCTAssertEqual(try VaultSessions(vault: vault).load(), session)
        try VaultSessions(vault: vault).clear()
        XCTAssertEqual(try old.load(), session)
        XCTAssertNil(try VaultSessions(vault: KeychainCredentialVault(item: item, lockDirectory: root, legacy: [old])).load())
    }
    func testBuiltHostAndExtensionResolveSameSharedGroup() throws {
        let host = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "SharedKeychainGroup") as? String)
        XCTAssertTrue(host.hasSuffix(".com.xdjs.InProcess.shared"))
        XCTAssertFalse(host.contains("$("))
        let url = Bundle.main.bundleURL.appendingPathComponent("Extensions/InProcessUploadExtension.appex/Info.plist")
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(info["SharedKeychainGroup"] as? String, host)
    }
    func testActualSharedSecItemAddReadUpdateProtectionAndDelete() throws {
        let report = KeychainProbe.run(id: UUID())
        XCTAssertNil(report.failure, report.failure ?? "")
        XCTAssertTrue(report.addRead)
        XCTAssertTrue(report.updateRead)
        XCTAssertTrue(report.accessibilityMatches)
        XCTAssertTrue(report.deleted)
    }
    func testActualManualStoreRetainsWhenUnlockedProtection() throws {
        let service = "com.xdjs.InProcess.keychain-probe.\(UUID().uuidString)"
        let store = KeychainSessionStore(service: service, accountOverride: "manual-disposable")
        defer { try? store.clear() }
        try store.save(SavedSession(token: "synthetic-only", email: "probe@example.invalid", expiresAt: .distantFuture))
        XCTAssertEqual(try store.load()?.token, "synthetic-only")
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "manual-disposable", kSecReturnAttributes as String: true]
        var attributes: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &attributes), errSecSuccess)
        XCTAssertEqual((attributes as? [String: Any])?[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        try store.clear(); XCTAssertNil(try store.load())
    }
    func testMissingSharedConfigurationFailsWithoutFallback() {
        let store = KeychainSessionStore(shared: true, service: "com.xdjs.InProcess.keychain-probe.\(UUID().uuidString)", accountOverride: "disposable", sharedGroup: nil)
        XCTAssertThrowsError(try store.save(SavedSession(token: "synthetic-only", email: "probe@example.invalid", expiresAt: .distantFuture)))
        XCTAssertThrowsError(try store.load())
    }
}
