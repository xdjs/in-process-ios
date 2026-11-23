import Foundation
import Security

protocol SessionStoring {
    func load() throws -> SavedSession?
    func save(_ session: SavedSession) throws
    func clear() throws
    func invalidate(_ credential: APICredential) throws
}
extension SessionStoring {
    func invalidate(_ credential: APICredential) throws {
        guard var value = try load(), value.credential == credential else { return }
        value.rejected = true; try save(value)
    }
}

struct KeychainFailure: LocalizedError {
    let operation: String
    let status: OSStatus
    var errorDescription: String? {
        if status == errSecInteractionNotAllowed { return "Unlock your iPhone and try again. Your saved sign-in has been kept." }
        return "Could not access secure sign-in storage (code \(status)). Your saved sign-in has been kept."
    }
}

struct KeychainSessionStore: SessionStoring {
    var shared = false
    // Overrides are for isolated integration probes only; production keeps these defaults.
    var service = "com.xdjs.InProcess"
    var accountOverride: String?
    var sharedGroup = Bundle.main.object(forInfoDictionaryKey: "SharedKeychainGroup") as? String
    private func query() throws -> [String: Any] {
        var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountOverride ?? (shared ? "automatic-session" : "session")]
        if shared {
            guard let group = sharedGroup, group.hasSuffix(".com.xdjs.InProcess.shared"),
                  group != ".com.xdjs.InProcess.shared", !group.contains("$(") else {
                throw AppError.message("Secure sign-in sharing is missing from this build. Your existing sign-in has been kept.")
            }
            value[kSecAttrAccessGroup as String] = group
        }
        return value
    }
    private func failure(_ operation: String, _ status: OSStatus) -> KeychainFailure {
        DevelopmentLog.shared.emit(operation == "save" ? .secureSave : operation == "delete" ? .secureClear : .secureLoad, .auth, [.errorDomain: .tag(.keychainError), .errorCode: .number(Int(status)), .shared: .flag(shared)], level: .error)
        return KeychainFailure(operation: operation, status: status)
    }
    func load() throws -> SavedSession? {
        try loadData().map { try JSONDecoder().decode(SavedSession.self, from: $0) }
    }
    func loadData() throws -> Data? {
        return try DevelopmentLog.shared.trace(.secureLoad, .auth, [.shared: .flag(shared)]) {
            var request = try query()
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            DevelopmentLog.shared.emit(.secureLoad, .auth, [.available: .flag(status == errSecSuccess), .shared: .flag(shared), .errorCode: .number(Int(status))])
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data else { throw failure("read", status) }
            return data
        }
    }
    func save(_ session: SavedSession) throws {
        try saveData(JSONEncoder().encode(session))
    }
    func saveData(_ data: Data) throws {
        return try DevelopmentLog.shared.trace(.secureSave, .auth, [.shared: .flag(shared)]) {
            let key = try query()
            let attributes: [String: Any] = [kSecValueData as String: data,
                kSecAttrAccessible as String: shared ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly : kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
            var status = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(key.merging(attributes) { _, new in new } as CFDictionary, nil)
                // Another process may have inserted between update and add. Update
                // that same item; never delete a credential to resolve this race.
                if status == errSecDuplicateItem { status = SecItemUpdate(key as CFDictionary, attributes as CFDictionary) }
            }
            guard status == errSecSuccess else { throw failure("save", status) }
        }
    }
    func clear() throws {
        return try DevelopmentLog.shared.trace(.secureClear, .auth, [.shared: .flag(shared)]) {
            let status = SecItemDelete(try query() as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw failure("delete", status) }
        }
    }
}

struct DraftStore {
    let directory: URL
    init(directory: URL? = nil) throws {
        self.directory = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("InProcess", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        var folder = self.directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }
    private var manifest: URL { directory.appendingPathComponent("draft.json") }
    func load() throws -> Draft? {
        guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }
        var draft = try JSONDecoder().decode(Draft.self, from: Data(contentsOf: manifest))
        if draft.stage == .submitting { draft.stage = .uncertain; try save(draft) }
        return draft
    }
    func save(_ draft: Draft) throws {
        try JSONEncoder().encode(draft).write(to: manifest, options: [.atomic, .completeFileProtection])
    }
    func photoURL(_ draft: Draft) -> URL { directory.appendingPathComponent(draft.photoFilename) }
    func savePhoto(_ data: Data, draft: Draft) throws { try data.write(to: photoURL(draft), options: [.atomic, .completeFileProtection]) }
    func photo(_ draft: Draft) throws -> Data { try Data(contentsOf: photoURL(draft)) }
    func remove(_ draft: Draft) throws {
        // Remove the manifest first. Never erase an uncertain operation.
        guard !draft.stage.mayHavePublished || draft.stage == .published else { throw AppError.message("Check publication status before starting another Moment.") }
        if FileManager.default.fileExists(atPath: manifest.path) { try FileManager.default.removeItem(at: manifest) }
        try? FileManager.default.removeItem(at: photoURL(draft))
    }
}
