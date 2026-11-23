import XCTest
import Security
@testable import InProcess

@MainActor final class ArtistCredentialTests: XCTestCase {
    let owner = "0x1111111111111111111111111111111111111111"
    let collection = Destination(address: "0x2222222222222222222222222222222222222222", name: "Fixture", chain_id: 8453)
    func jwt() -> SavedSession {
        SavedSession(token: "fixture." + Data("{\"exp\":4102444800}".utf8).base64EncodedString() + ".fixture", email: "private@example.invalid", expiresAt: Date().addingTimeInterval(3600))
    }
    func make() -> (MemoryCredentialVault, CredentialTestAPI, ArtistCredentialSetup) {
        let vault = MemoryCredentialVault(), api = CredentialTestAPI(owner: owner, collection: collection)
        return (vault, api, ArtistCredentialSetup(vault: vault, api: api))
    }
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testLegacyDecodeAndArtistKeyDoesNotExpireAfterAnHour() throws {
        let data = try JSONSerialization.data(withJSONObject: ["token": "legacy", "email": "fixture@example.invalid", "expiresAt": 1000])
        let legacy = try JSONDecoder().decode(SavedSession.self, from: data)
        XCTAssertEqual(legacy.kind, .bearer); XCTAssertTrue(legacy.isExpired)
        let key = SavedSession(token: "synthetic-key", email: "", expiresAt: .distantPast, kind: .artistKey, owner: owner)
        XCTAssertTrue(key.isValid(at: Date().addingTimeInterval(86400)))
        XCTAssertEqual(try JSONDecoder().decode(SavedSession.self, from: JSONEncoder().encode(key)), key)
    }
    func testBootstrapValidatesThenCommitsOnceAndRestoresWithoutIssuing() async throws {
        let (vault, api, setup) = make()
        let key = try await setup.begin(jwt())
        XCTAssertEqual(key.kind, .artistKey); XCTAssertNotNil(key.keyID)
        XCTAssertEqual(vault.value.active, key); XCTAssertNil(vault.value.pending)
        let restored = try await ArtistCredentialSetup(vault: vault, api: api).resume()
        XCTAssertEqual(restored, key); XCTAssertEqual(api.keyCreates, 1)
        XCTAssertEqual(api.creationCredentials.map(\.kind), [.bearer])
        XCTAssertTrue(api.keyNames.allSatisfy { $0.count <= 100 && !$0.contains("@") })
    }
    func testValidLegacyMigratesAndExpiredLegacyDoesNotCreate() async throws {
        let (vault, api, setup) = make(); vault.value.active = jwt()
        _ = try await setup.resume(); XCTAssertEqual(api.keyCreates, 1)
        let (expired, expiredAPI, expiredSetup) = make()
        expired.value.active = SavedSession(token: "expired", email: "", expiresAt: .distantPast)
        do { _ = try await expiredSetup.resume(); XCTFail("Must require OTP") } catch {}
        XCTAssertEqual(expiredAPI.keyCreates, 0)
    }
    func testCandidateNetworkFailureResumesAcrossRestartWithoutAnotherCreate() async throws {
        let (vault, api, setup) = make(); let old = jwt(); vault.value.active = old
        api.candidateError = URLError(.notConnectedToInternet)
        do { _ = try await setup.begin(old); XCTFail() } catch {}
        XCTAssertEqual(vault.value.active, old); XCTAssertNotNil(vault.value.pending?.candidate)
        api.candidateError = nil
        _ = try await ArtistCredentialSetup(vault: vault, api: api).resume()
        XCTAssertEqual(api.keyCreates, 1)
    }
    func testOutageBeforeBootstrapIdentityOffersRetryWithoutAnotherOTP() async throws {
        let (vault, api, setup) = make()
        let model = AppModel(api: api, sessions: VaultSessions(vault: vault), drafts: try DraftStore(directory: directory()), credentialSetup: setup)
        model.email = "fixture@example.invalid"; model.code = "123456"; model.codeSent = true
        api.bootstrapError = URLError(.notConnectedToInternet)
        await model.signIn()
        XCTAssertTrue(model.needsCredentialRetry); XCTAssertEqual(api.keyCreates, 0)
        api.bootstrapError = nil; await model.retryAccount()
        XCTAssertTrue(model.isAuthenticated); XCTAssertEqual(api.keyCreates, 1)
    }
    func testTimeoutAndCrashMarkerNeverAutomaticallyCreateAgain() async throws {
        let (vault, api, setup) = make(); api.createError = URLError(.timedOut)
        do { _ = try await setup.begin(jwt()); XCTFail() } catch {}
        XCTAssertEqual(vault.value.pending?.stage, .creating)
        api.createError = nil
        for _ in 0..<3 { do { _ = try await ArtistCredentialSetup(vault: vault, api: api).resume(); XCTFail() } catch {} }
        XCTAssertEqual(api.keyCreates, 1)
        try setup.allowReplacement(); _ = try await setup.resume()
        XCTAssertEqual(api.keyCreates, 2); XCTAssertEqual(vault.value.revocations.count, 1)
        XCTAssertNotEqual(vault.value.revocations.first?.label, vault.value.active?.keyLabel)
    }
    func testDefinitiveRateLimitCanRetryWithoutInvalidatingOldSession() async throws {
        let (vault, api, setup) = make(); let old = jwt(); vault.value.active = old
        api.createError = KeyIssuanceError.notCreated(429)
        do { _ = try await setup.begin(old); XCTFail() } catch {}
        XCTAssertEqual(vault.value.active, old); XCTAssertEqual(vault.value.pending?.stage, .ready)
        api.createError = nil; _ = try await setup.resume(); XCTAssertEqual(api.keyCreates, 2)
    }
    func testSecureCandidateSaveFailureKeepsReturnedKeyForExplicitRetry() async throws {
        let (vault, api, setup) = make(); let old = jwt(); vault.value.active = old
        vault.failUpdate = { $0.pending?.stage == .validating }
        do { _ = try await setup.begin(old); XCTFail() } catch {}
        XCTAssertEqual(vault.value.active, old); XCTAssertEqual(vault.value.pending?.stage, .creating)
        vault.failUpdate = nil; _ = try await setup.resume(); XCTAssertEqual(api.keyCreates, 1)
    }
    func testCrashAfterCandidateSaveFailureRequiresExplicitReplacement() async throws {
        let (vault, api, setup) = make(); vault.failUpdate = { $0.pending?.stage == .validating }
        do { _ = try await setup.begin(jwt()); XCTFail() } catch {}
        vault.failUpdate = nil
        do { _ = try await ArtistCredentialSetup(vault: vault, api: api).resume(); XCTFail() } catch {}
        XCTAssertEqual(api.keyCreates, 1); XCTAssertNil(vault.value.active)
    }
    func testCommitFailureRetainsCandidateAndOldWorkingSession() async throws {
        let (vault, api, setup) = make(); let old = jwt(); vault.value.active = old
        vault.failUpdate = { $0.active?.kind == .artistKey }
        do { _ = try await setup.begin(old); XCTFail() } catch {}
        XCTAssertEqual(vault.value.active, old); XCTAssertNotNil(vault.value.pending?.candidate)
        vault.failUpdate = nil; _ = try await ArtistCredentialSetup(vault: vault, api: api).resume()
        XCTAssertEqual(api.keyCreates, 1)
    }
    func testIdentityOrCollectionMismatchNeverPromotesCandidate() async throws {
        for mismatch in ["owner", "collection"] {
            let (vault, api, setup) = make(); let old = jwt(); vault.value.active = old; api.mismatch = mismatch
            do { _ = try await setup.begin(old); XCTFail() } catch {}
            XCTAssertEqual(vault.value.active, old); XCTAssertEqual(api.keyCreates, 1)
        }
    }
    func testSignOutDuringCreateCannotResurrectCredential() async throws {
        let (vault, api, setup) = make()
        api.duringCreate = { try VaultSessions(vault: vault).clear() }
        do { _ = try await setup.begin(jwt()); XCTFail() } catch {}
        XCTAssertTrue(vault.value.signedOut); XCTAssertNil(vault.value.active); XCTAssertNil(vault.value.pending)
        XCTAssertEqual(vault.value.revocations.count, 1)
    }
    func testSignOutDuringValidationCannotPromoteCandidate() async throws {
        let (vault, api, setup) = make()
        api.duringCandidateValidation = { try VaultSessions(vault: vault).clear(); setup.discardMemory() }
        do { _ = try await setup.begin(jwt()); XCTFail() } catch {}
        XCTAssertTrue(vault.value.signedOut); XCTAssertNil(vault.value.active); XCTAssertNil(vault.value.pending)
        XCTAssertEqual(vault.value.revocations.count, 1)
    }
    func testPendingRemoteRemovalSurvivesAppRestoreWithoutRetainingSecret() async throws {
        let (vault, api, setup) = make(); let key = try await setup.begin(jwt())
        try VaultSessions(vault: vault).clear()
        let model = AppModel(api: api, sessions: VaultSessions(vault: vault), drafts: try DraftStore(directory: directory()), credentialSetup: setup)
        await model.restore()
        XCTAssertFalse(model.isAuthenticated); XCTAssertTrue(model.signOutStatus?.contains("pending") == true)
        XCTAssertNil(vault.value.active); XCTAssertFalse(String(decoding: try JSONEncoder().encode(vault.value), as: UTF8.self).contains(key.token))
    }
    func testUnreadableVaultDoesNotConfirmRemoteRemoval() {
        let (vault, _, setup) = make(); vault.failRead = true
        XCTAssertNil(setup.pendingRevocationCount)
        XCTAssertNotEqual(setup.pendingRevocationCount, 0)
    }
    func testLateForegroundRejectionCannotInvalidateReplacement() async throws {
        let (vault, api, setup) = make(); let old = try await setup.begin(jwt())
        let model = AppModel(api: api, sessions: VaultSessions(vault: vault), drafts: try DraftStore(directory: directory()), credentialSetup: setup)
        model.session = old; model.identity = Identity(artistAddress: owner, profile: .init(username: "Fixture")); model.didRestore = true
        let replacement = SavedSession(token: "synthetic-replacement", email: "", expiresAt: .distantFuture, kind: .artistKey, owner: owner)
        api.duringCandidateValidation = {
            try vault.update(expected: vault.snapshot().revision) { $0.active = replacement }
            model.session = replacement
        }
        api.candidateError = AppError.sessionExpired
        await model.foreground()
        XCTAssertEqual(model.session, replacement); XCTAssertEqual(vault.value.active, replacement); XCTAssertNil(model.error)
    }
    func testExplicitCredentialValidationRequiresPauseAndOnlySimulatesPublishedMetadata() async throws {
        let (vault, api, setup) = make(); let key = try await setup.begin(jwt())
        let store = try UploadStore(directory: directory())
        try store.update { $0.configuration = AutomaticConfiguration(owner: owner, destination: collection, albumID: "fixture") }
        let model = AppModel(api: api, sessions: VaultSessions(vault: vault), drafts: try DraftStore(directory: directory()), uploadStore: store, credentialSetup: setup)
        model.session = key; model.identity = Identity(artistAddress: owner, profile: .init(username: "Fixture"))
        var draft = Draft(owner: owner, destination: collection); draft.hasPhoto = true; draft.metadataURI = "https://fixture.invalid/existing.json"
        model.draft = draft; model.credentialValidationMode = true
        XCTAssertFalse(model.canPublish)
        do { try await model.validateCredentialWithoutPublishing(); XCTFail() } catch {}
        XCTAssertEqual(api.simulations, 0)
        try store.update { $0.configuration?.paused = true }
        try await model.validateCredentialWithoutPublishing(); XCTAssertEqual(api.simulations, 0)
        draft.stage = .published; model.draft = draft
        try await model.validateCredentialWithoutPublishing()
        XCTAssertEqual(api.simulations, 1); XCTAssertEqual(api.creates, 0); XCTAssertEqual(api.uploads, 0)
        XCTAssertTrue(model.credentialValidationStatus?.contains("simulation passed") == true)
    }
    func testInvalidationCannotOverwriteNewerCredentialAndStaleResumeCannotSave() async throws {
        let (vault, _, setup) = make(); let key = try await setup.begin(jwt())
        let sessions = VaultSessions(vault: vault)
        try sessions.invalidate(jwt().credential); XCTAssertFalse(try XCTUnwrap(sessions.load()).rejected)
        XCTAssertThrowsError(try sessions.save(jwt()))
        try sessions.invalidate(key.credential); XCTAssertTrue(try XCTUnwrap(sessions.load()).isExpired)
    }
    func testRevocationOnlyDeletesExactRetiredOwnedKeyAndKeepsReplacement() async throws {
        let (vault, api, setup) = make(); let first = try await setup.begin(jwt())
        try VaultSessions(vault: vault).clear()
        let other = ArtistKeyRecord(id: UUID().uuidString, name: "Other installation")
        api.keys.append(other)
        let second = try await setup.begin(jwt())
        await setup.revokePending(using: second.credential, owner: owner)
        XCTAssertEqual(api.revoked, [first.keyID!]); XCTAssertTrue(api.keys.contains(other))
        XCTAssertTrue(api.keys.contains { $0.id == second.keyID }); XCTAssertTrue(vault.value.revocations.isEmpty)
    }
    func testOfflineSignOutRetainsOnlyMetadataThenSameAccountCleansUp() async throws {
        let (vault, api, setup) = make(); let key = try await setup.begin(jwt())
        try VaultSessions(vault: vault).clear(); api.revokeError = URLError(.notConnectedToInternet)
        await setup.revokePending(using: key.credential, owner: owner)
        XCTAssertNil(try VaultSessions(vault: vault).load()); XCTAssertEqual(vault.value.revocations.count, 1)
        let encoded = String(decoding: try JSONEncoder().encode(vault.value), as: UTF8.self)
        XCTAssertFalse(encoded.contains(key.token)); XCTAssertFalse(encoded.contains(jwt().token))
        api.revokeError = nil
        await ArtistCredentialSetup(vault: vault, api: api).revokePending(using: jwt().credential, owner: owner)
        XCTAssertTrue(vault.value.revocations.isEmpty)
    }
    func testRevocationCrashAfterDeleteAndMissingKeyResolveThroughListing() async throws {
        let (vault, api, setup) = make(); let key = try await setup.begin(jwt())
        try VaultSessions(vault: vault).clear()
        vault.failUpdate = { $0.revocations.isEmpty }
        await setup.revokePending(using: jwt().credential, owner: owner)
        XCTAssertEqual(api.revoked, [key.keyID!]); XCTAssertEqual(vault.value.revocations.count, 1)
        vault.failUpdate = nil
        await setup.revokePending(using: jwt().credential, owner: owner)
        XCTAssertTrue(vault.value.revocations.isEmpty); XCTAssertEqual(api.revoked.count, 1)
    }
    func testRevocationRefusesDifferentOwnerDuplicateLabelAndConflictingID() async throws {
        for scenario in ["owner", "duplicate", "id"] {
            let (vault, api, setup) = make(); let key = try await setup.begin(jwt())
            try VaultSessions(vault: vault).clear()
            if scenario == "owner" { api.owner = "0x3333333333333333333333333333333333333333" }
            if scenario == "duplicate" { api.keys.append(ArtistKeyRecord(id: UUID().uuidString, name: key.keyLabel!)) }
            if scenario == "id" { api.keys = [ArtistKeyRecord(id: UUID().uuidString, name: key.keyLabel!)] }
            await setup.revokePending(using: jwt().credential, owner: owner)
            XCTAssertTrue(api.revoked.isEmpty); XCTAssertEqual(vault.value.revocations.count, 1)
        }
    }
    func testRevokedKeyPreservesQueueNotifiesOnceAndReplacementResumes() async throws {
        let (vault, api, setup) = make(); let key = try await setup.begin(jwt())
        let store = try UploadStore(directory: directory()), library = FixtureAlbum(), transfer = FixtureTransfers(), notices = FixtureNotifications()
        let sessions = VaultSessions(vault: vault)
        let worker = try UploadCoordinator(store: store, library: library, transfer: transfer, notifications: notices, api: api, sessions: sessions)
        await worker.configure(owner: owner, destination: collection, albumID: "fixture", session: key)
        let ids = worker.state.records.map(\.id); api.candidateError = AppError.sessionExpired
        _ = await worker.process(); _ = await worker.process()
        XCTAssertTrue(try XCTUnwrap(sessions.load()).rejected)
        XCTAssertEqual(worker.state.records.map(\.id), ids); XCTAssertEqual(notices.messages.count, 1)
        XCTAssertTrue(transfer.submitted.isEmpty)
        api.candidateError = nil; let replacement = try await setup.begin(jwt())
        await worker.resumeSession(replacement, owner: owner); _ = await worker.process()
        XCTAssertEqual(transfer.submitted, ids); XCTAssertEqual(api.creates, 0)
    }
    func testOfflineIdentityDoesNotRejectKeyOrClearPendingQueue() async throws {
        let (vault, api, setup) = make(); let key = try await setup.begin(jwt())
        let store = try UploadStore(directory: directory()), library = FixtureAlbum(), transfer = FixtureTransfers()
        let worker = try UploadCoordinator(store: store, library: library, transfer: transfer, notifications: FixtureNotifications(), api: api, sessions: VaultSessions(vault: vault))
        await worker.configure(owner: owner, destination: collection, albumID: "fixture", session: key)
        api.candidateError = URLError(.notConnectedToInternet); _ = await worker.process()
        XCTAssertEqual(vault.value.active, key); XCTAssertEqual(worker.state.records.count, 1); XCTAssertTrue(transfer.submitted.isEmpty)
    }
    func testBootstrapAndRevocationLogsNeverContainSecretsOrLabels() async throws {
        let (vault, api, _) = make(), root = try directory()
        let log = DevelopmentLog(file: DiagnosticFile(directory: root), role: .host)
        let setup = ArtistCredentialSetup(vault: vault, api: ObservedService(base: api, log: log))
        let key = try await setup.begin(jwt()); try VaultSessions(vault: vault).clear()
        await setup.revokePending(using: key.credential, owner: owner)
        let text = String(decoding: try XCTUnwrap(log.file).snapshot(), as: UTF8.self)
        for secret in [key.token, jwt().token, key.email, key.keyLabel!, owner] { XCTAssertFalse(text.contains(secret)) }
        XCTAssertTrue(text.contains("artistKeyCreate")); XCTAssertTrue(text.contains("artistKeyRevoke"))
    }
}

@MainActor final class CredentialTestAPI: InProcessServing {
    var owner: String; let collection: Destination
    var keys: [ArtistKeyRecord] = [], keyNames: [String] = [], creationCredentials: [APICredential] = [], revoked: [String] = []
    var keyCreates = 0, creates = 0, simulations = 0, uploads = 0
    var createError: Error?, candidateError: Error?, revokeError: Error?, bootstrapError: Error?
    var mismatch: String?
    var duringCreate: (() throws -> Void)?
    var duringCandidateValidation: (() throws -> Void)?
    init(owner: String, collection: Destination) { self.owner = owner; self.collection = collection }
    func sendCode(email: String) async throws {}
    func login(email: String, code: String) async throws -> LoginResponse {
        LoginResponse(token: "fixture." + Data("{\"exp\":4102444800}".utf8).base64EncodedString() + ".fixture", social_wallet: owner)
    }
    func createArtistKey(name: String, bootstrap: APICredential) async throws -> String {
        keyCreates += 1; keyNames.append(name); creationCredentials.append(bootstrap)
        try duringCreate?(); if let createError { throw createError }
        keys.append(ArtistKeyRecord(id: UUID().uuidString, name: name))
        return "art_sk_synthetic_no_authority_\(keyCreates)"
    }
    func artistKeys(token: APICredential) async throws -> [ArtistKeyRecord] { keys }
    func revokeArtistKey(id: String, token: APICredential) async throws {
        if let revokeError { throw revokeError }; revoked.append(id); keys.removeAll { $0.id == id }
    }
    func identity(token: APICredential) async throws -> Identity {
        if token.kind == .bearer, let bootstrapError { throw bootstrapError }
        if token.kind == .artistKey { try duringCandidateValidation?() }
        if token.kind == .artistKey, let candidateError { throw candidateError }
        return Identity(artistAddress: token.kind == .artistKey && mismatch == "owner" ? "0x3333333333333333333333333333333333333333" : owner, profile: .init(username: "Fixture"))
    }
    func destination(token: APICredential) async throws -> Destination {
        if token.kind == .artistKey && mismatch == "collection" { return Destination(address: owner, name: "Other", chain_id: 8453) }
        return collection
    }
    func upload(data: Data, object: String, contentType: String) async throws -> String { uploads += 1; return "https://fixture.invalid/\(object)" }
    func simulate(_ request: CreateMomentRequest, token: APICredential) async throws { simulations += 1 }
    func create(_ request: CreateMomentRequest, token: APICredential) async throws -> Publication {
        creates += 1; return Publication(contractAddress: collection.address, tokenId: "1", hash: "0xfixture", chainId: 8453)
    }
    func reconcile(_ draft: Draft, token: APICredential) async throws -> Publication? { nil }
}
