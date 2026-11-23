import Foundation

/// This entire envelope is a single device-only Keychain item, never a file.
struct CredentialVaultState: Codable, Equatable {
    var revision = UUID()
    var installation = UUID()
    var active: SavedSession?
    var pending: KeyBootstrapAttempt?
    var signedOut = false
    var revocations: [KeyRevocation] = []
    mutating func retireCredentials() {
        if let active, active.kind == .artistKey, let owner = active.owner, let label = active.keyLabel {
            queueRevocation(owner: owner, label: label, keyID: active.keyID)
        }
        if let pending, pending.stage != .ready {
            queueRevocation(owner: pending.owner, label: pending.label(installation), keyID: pending.candidate?.keyID)
        }
        signedOut = true; active = nil; pending = nil
    }
    mutating func queueRevocation(owner: String, label: String, keyID: String?) {
        guard !revocations.contains(where: { $0.label == label && $0.owner == owner }) else { return }
        revocations.append(KeyRevocation(owner: owner, label: label, keyID: keyID))
    }
}
struct KeyRevocation: Codable, Equatable {
    var id = UUID()
    let owner: String
    let label: String
    let keyID: String?
}
struct KeyBootstrapAttempt: Codable, Equatable {
    enum Stage: String, Codable { case ready, creating, validating }
    var id = UUID()
    var owner: String
    var destination: Destination
    var bootstrap: SavedSession
    var stage: Stage = .ready
    var candidate: SavedSession?
    func label(_ installation: UUID) -> String { "In Process iPhone \(installation.uuidString) \(id.uuidString)" }
}
enum CredentialSetupError: LocalizedError {
    case changed, ambiguous, rejected, retry, signIn, mismatch
    var errorDescription: String? {
        switch self {
        case .changed: "Sign-in changed while this request was running. Retry loading your account."
        case .ambiguous: "A sign-in key may have been created, but its secure save could not be confirmed. Retry loading first. If this persists, create a replacement; the earlier key may remain on the API Keys page at inprocess.world."
        case .rejected: "The new sign-in key was rejected. Your previous sign-in and pending uploads are kept. Sign in again to create a replacement."
        case .retry: "Could not finish saving your sign-in. Retry loading your account when you’re online; your previous sign-in and pending uploads are kept."
        case .signIn: "Sign in again to finish setting up your secure sign-in. Your pending uploads are saved."
        case .mismatch: "The new sign-in does not match the account and collection being connected. Your existing sign-in and uploads are kept."
        }
    }
}

protocol CredentialVault {
    func snapshot() throws -> CredentialVaultState
    @discardableResult func update(expected: UUID, _ body: (inout CredentialVaultState) throws -> Void) throws -> CredentialVaultState
}

struct KeychainCredentialVault: CredentialVault {
    let item: KeychainSessionStore
    let lockDirectory: URL
    let legacy: [any SessionStoring]
    var uploadStore: UploadStore?

    private func locked<T>(_ body: () throws -> T) throws -> T {
        // Short, cross-process transaction. No network call is made under this lock.
        guard let lock = try UploadLease(url: lockDirectory.appendingPathComponent("credentials.lock"), blocking: true) else {
            throw CredentialSetupError.retry
        }
        defer { withExtendedLifetime(lock) {} }
        return try body()
    }
    private func read() throws -> CredentialVaultState {
        if let data = try item.loadData() { return try JSONDecoder().decode(CredentialVaultState.self, from: data) }
        var state = CredentialVaultState()
        state.signedOut = try uploadStore?.read().configuration?.signedOut == true
        if !state.signedOut {
            for store in legacy {
                if let saved = try store.load() { state.active = saved; break }
            }
        }
        try write(state)
        return state
    }
    private func write(_ state: CredentialVaultState) throws {
        try item.saveData(JSONEncoder().encode(state))
        guard let data = try item.loadData(), try JSONDecoder().decode(CredentialVaultState.self, from: data) == state else {
            throw CredentialSetupError.retry
        }
    }
    func snapshot() throws -> CredentialVaultState { try locked { try read() } }
    func update(expected: UUID, _ body: (inout CredentialVaultState) throws -> Void) throws -> CredentialVaultState {
        try locked {
            var state = try read()
            guard state.revision == expected else { throw CredentialSetupError.changed }
            try body(&state); state.revision = UUID()
            try write(state)
            return state
        }
    }
}

/// Host and extension read one authoritative credential. A stale setup/resume
/// cannot replace it; only the bootstrap transaction can promote a new key.
struct VaultSessions: SessionStoring {
    let vault: any CredentialVault
    var legacyToClear: [any SessionStoring] = []
    func load() throws -> SavedSession? {
        let state = try vault.snapshot()
        return state.signedOut ? nil : state.active
    }
    func save(_ session: SavedSession) throws {
        let state = try vault.snapshot()
        guard !state.signedOut else { throw AppError.sessionExpired }
        if state.active == session { return }
        guard state.active == nil else { throw CredentialSetupError.changed }
        try vault.update(expected: state.revision) { $0.active = session }
    }
    func clear() throws {
        let state = try vault.snapshot()
        // Persist the tombstone before deleting legacy items. A partial cleanup
        // cannot resurrect an old credential or an in-flight bootstrap response.
        try vault.update(expected: state.revision) { $0.retireCredentials() }
        for store in legacyToClear { try store.clear() }
    }
    func invalidate(_ credential: APICredential) throws {
        let state = try vault.snapshot()
        guard state.active?.credential == credential else { return }
        try vault.update(expected: state.revision) { $0.active?.rejected = true }
    }
}

@MainActor final class ArtistCredentialSetup {
    let vault: any CredentialVault
    let api: any InProcessServing
    // Preserve a returned secret across a transient Keychain write failure in
    // this process. A crash here leaves the durable 'creating' marker instead.
    private var unsavedCandidate: (UUID, SavedSession)?
    private var busy = false
    init(vault: any CredentialVault, api: any InProcessServing) { self.vault = vault; self.api = api }
    func discardMemory() { unsavedCandidate = nil }

    func begin(_ bootstrap: SavedSession) async throws -> SavedSession {
        guard !busy else { throw CredentialSetupError.retry }
        guard bootstrap.kind == .bearer, !bootstrap.isExpired else { throw CredentialSetupError.signIn }
        let initial = try vault.snapshot()
        let person = try await api.identity(token: bootstrap.credential)
        let destination = try await api.destination(token: bootstrap.credential)
        try Self.validate(person, destination)
        var state = try vault.snapshot()
        guard state.revision == initial.revision else { throw CredentialSetupError.changed }
        if let active = state.active, !state.signedOut, active.kind == .artistKey, !active.isExpired,
           active.owner?.lowercased() == person.artistAddress.lowercased() { return active }
        if let pending = state.pending {
            guard pending.owner.lowercased() == person.artistAddress.lowercased() else { throw CredentialSetupError.mismatch }
            // A fresh OTP refreshes only the bootstrap authority, not the create marker.
            state = try vault.update(expected: state.revision) { $0.pending?.bootstrap = bootstrap }
        } else {
            state = try vault.update(expected: state.revision) {
                $0.pending = KeyBootstrapAttempt(owner: person.artistAddress, destination: destination, bootstrap: bootstrap)
            }
        }
        return try await finish(state)
    }
    func resume() async throws -> SavedSession {
        guard !busy else { throw CredentialSetupError.retry }
        let state = try vault.snapshot()
        if state.pending != nil { return try await finish(state) }
        guard let active = state.active, !state.signedOut, !active.isExpired else { throw CredentialSetupError.signIn }
        return active.kind == .artistKey ? active : try await begin(active)
    }
    /// Only an explicit recovery action discards an ambiguous creation marker.
    func allowReplacement() throws {
        let state = try vault.snapshot()
        guard var pending = state.pending else { return }
        let old = pending
        pending.id = UUID(); pending.stage = .ready; pending.candidate = nil
        try vault.update(expected: state.revision) {
            if old.stage != .ready { $0.queueRevocation(owner: old.owner, label: old.label(state.installation), keyID: old.candidate?.keyID) }
            $0.pending = pending
        }
        unsavedCandidate = nil
    }
    var needsReplacement: Bool {
        guard let pending = try? vault.snapshot().pending else { return false }
        return pending.stage == .creating || pending.candidate?.rejected == true
    }
    private func finish(_ initial: CredentialVaultState) async throws -> SavedSession {
        busy = true; defer { busy = false }
        var state = initial
        guard var pending = state.pending else { throw CredentialSetupError.retry }
        if let (id, saved) = unsavedCandidate, id == pending.id {
            state = try vault.update(expected: state.revision) { $0.pending?.candidate = saved; $0.pending?.stage = .validating }
            unsavedCandidate = nil; pending = state.pending!
        }
        if pending.stage == .creating { throw CredentialSetupError.ambiguous }
        if pending.stage == .ready {
            guard !pending.bootstrap.isExpired else { throw CredentialSetupError.signIn }
            state = try vault.update(expected: state.revision) { $0.pending?.stage = .creating }
            let key: String
            do {
                key = try await api.createArtistKey(name: pending.label(state.installation), bootstrap: pending.bootstrap.credential)
            } catch KeyIssuanceError.notCreated(let status) {
                _ = try vault.update(expected: state.revision) { $0.pending?.stage = .ready }
                if status == 401 || status == 403 { throw CredentialSetupError.signIn }
                throw CredentialSetupError.retry
            } catch {
                // Timeouts, malformed successes and 5xx may follow a successful create.
                throw CredentialSetupError.ambiguous
            }
            let saved = SavedSession(token: key, email: pending.bootstrap.email, expiresAt: .distantFuture, kind: .artistKey, owner: pending.owner, keyLabel: pending.label(state.installation))
            guard try vault.snapshot().revision == state.revision else { throw CredentialSetupError.changed }
            unsavedCandidate = (pending.id, saved)
            state = try vault.update(expected: state.revision) { $0.pending?.candidate = saved; $0.pending?.stage = .validating }
            unsavedCandidate = nil; pending = state.pending!
        }
        guard var candidate = pending.candidate, !candidate.rejected else { throw CredentialSetupError.rejected }
        do {
            let person = try await api.identity(token: candidate.credential)
            let collection = try await api.destination(token: candidate.credential)
            try Self.validate(person, collection)
            guard person.artistAddress.lowercased() == pending.owner.lowercased(),
                  collection.address.lowercased() == pending.destination.address.lowercased(),
                  collection.chain_id == pending.destination.chain_id else { throw CredentialSetupError.mismatch }
            let matches = try await api.artistKeys(token: candidate.credential).filter { $0.name == candidate.keyLabel }
            guard matches.count == 1, UUID(uuidString: matches[0].id) != nil else { throw CredentialSetupError.retry }
            candidate.keyID = matches[0].id
        } catch AppError.sessionExpired {
            _ = try vault.update(expected: state.revision) { $0.pending?.candidate?.rejected = true }
            throw CredentialSetupError.rejected
        }
        // CAS prevents sign-out or another process's credential update from being
        // undone by a response that arrived late. Verified Keychain readback is
        // part of update(), before the host can adopt this session.
        try vault.update(expected: state.revision) {
            if let old = $0.active, old.kind == .artistKey, let owner = old.owner, let label = old.keyLabel, label != candidate.keyLabel {
                $0.queueRevocation(owner: owner, label: label, keyID: old.keyID)
            }
            $0.active = candidate; $0.pending = nil; $0.signedOut = false
        }
        return candidate
    }
    // An unreadable vault is unknown, never proof that remote removal finished.
    var pendingRevocationCount: Int? { try? vault.snapshot().revocations.count }
    func revokePending(using credential: APICredential, owner: String) async {
        do {
            let tickets = try vault.snapshot().revocations.filter { $0.owner.lowercased() == owner.lowercased() }
            guard !tickets.isEmpty else { return }
            let identity = try await api.identity(token: credential)
            guard identity.artistAddress.lowercased() == owner.lowercased() else { return }
            let keys = try await api.artistKeys(token: credential)
            for ticket in tickets {
                let current = try vault.snapshot()
                guard current.revocations.contains(ticket), current.active?.keyLabel != ticket.label,
                      current.pending.map({ $0.label(current.installation) }) != ticket.label else { continue }
                let matches = keys.filter { $0.name == ticket.label }
                // A listing authenticated as this artist must unambiguously
                // match the installation label AND any previously saved ID.
                if !matches.isEmpty {
                    guard matches.count == 1, UUID(uuidString: matches[0].id) != nil,
                          ticket.keyID == nil || ticket.keyID == matches[0].id else { continue }
                    try await api.revokeArtistKey(id: matches[0].id, token: credential)
                }
                let latest = try vault.snapshot()
                try vault.update(expected: latest.revision) { $0.revocations.removeAll { $0.id == ticket.id } }
            }
        } catch {
            // Only nonsecret tickets persist. Retry after same-account sign-in;
            // never reinterpret an outage as successful remote revocation.
        }
    }
    static func validate(_ identity: Identity, _ destination: Destination) throws {
        guard CreateMomentRequest.isAddress(identity.artistAddress), identity.profile != nil,
              destination.chain_id == 8453, CreateMomentRequest.isAddress(destination.address) else {
            throw AppError.message("An existing In Process profile and default collection on Base are required.")
        }
    }
}
