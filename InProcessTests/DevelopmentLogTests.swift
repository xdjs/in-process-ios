import XCTest
@testable import InProcess

final class DevelopmentLogFileTests: XCTestCase {
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func rows(_ data: Data) throws -> [[String: Any]] {
        try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }
    func testIndependentConcurrentWritersProduceCompleteSharedExport() throws {
        let root = try directory(), file = DiagnosticFile(directory: root.appendingPathComponent("journal"))
        // Separate instances and fds, no in-memory writer lock. Same boundary
        // used by independently launched host and extension processes.
        let writers = (0..<4).map { DevelopmentLog(file: file, role: $0 % 2 == 0 ? .host : .uploadExtension) }
        DispatchQueue.concurrentPerform(iterations: 4) { writer in
            for sequence in 0..<50 { writers[writer].emit(.lifecycle, .app, [.count: .number(writer * 50 + sequence)]) }
        }
        XCTAssertTrue(writers.allSatisfy { $0.fileFailures == 0 })
        let output = try writers[0].export(to: root.appendingPathComponent("export"))
        let records = try rows(Data(contentsOf: output)).filter { $0["event"] as? String == "lifecycle" }
        XCTAssertEqual(records.count, 200)
        XCTAssertEqual(Set(records.compactMap { ($0["fields"] as? [String: Any])?["count"] as? Int }).count, 200)
        XCTAssertEqual(Set(records.compactMap { $0["role"] as? String }), ["host", "uploadExtension"])
        let times = records.compactMap { $0["timestamp"] as? String }
        XCTAssertEqual(times, times.sorted()); XCTAssertTrue(times.allSatisfy { $0.hasSuffix("Z") })
        #if !targetEnvironment(simulator)
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
        #endif // Simulator does not expose iOS Data Protection attributes.
    }
    func testRotationBoundsHistoryAndKeepsNewestRecordsInOrder() throws {
        let root = try directory(), file = DiagnosticFile(directory: root, maximumBytes: 2200, generations: 3)
        let log = DevelopmentLog(file: file, role: .host)
        for i in 0..<80 { log.emit(.queueEnqueue, .queue, [.count: .number(i)]) }
        let data = try file.snapshot(), records = try rows(data)
        let counts = records.compactMap { ($0["fields"] as? [String: Any])?["count"] as? Int }
        XCTAssertEqual(log.fileFailures, 0); XCTAssertLessThanOrEqual(data.count, 6600)
        XCTAssertLessThan(records.count, 80); XCTAssertEqual(counts.last, 79)
        XCTAssertEqual(counts, Array((counts.first ?? 0)...79))
        XCTAssertLessThanOrEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 4)
    }
    func testErrorsAndMaliciousValuesCannotLeakSecretsInEitherSerializedSink() throws {
        let root = try directory(), file = DiagnosticFile(directory: root)
        let log = DevelopmentLog(file: file, role: .host)
        let secrets = ["eyJ-secret-jwt", "123456-otp", "private@example.invalid", "Bearer credential", "apikey=private", "Cookie=session", "https://private.invalid/photo.heic?signature=secret", "GPS latitude private", "private-file-name.heic"]
        for secret in secrets {
            let error = NSError(domain: secret, code: 403, userInfo: [NSLocalizedDescriptionKey: secret, NSURLErrorFailingURLErrorKey: secret])
            log.emit(.network, .network, DevelopmentLog.safeError(error).merging([.job: .hash(secret), .asset: .correlated(secret)]) { _, new in new }, level: .error)
        }
        let export = try log.export(to: root.appendingPathComponent("export"))
        let text = try String(contentsOf: export, encoding: .utf8)
        for secret in secrets { XCTAssertFalse(text.contains(secret)) }
        XCTAssertTrue(text.contains("redacted")); XCTAssertTrue(text.contains("otherError"))
        XCTAssertEqual(try rows(Data(contentsOf: export)).filter { $0["event"] as? String == "network" }.count, secrets.count)
    }
    func testFileFailureNeverThrowsFromEventAndExportReportsFailure() throws {
        let root = try directory(), obstruction = root.appendingPathComponent("not-a-folder")
        try Data([1]).write(to: obstruction)
        let log = DevelopmentLog(file: DiagnosticFile(directory: obstruction), role: .host)
        log.emit(.scan); XCTAssertEqual(log.fileFailures, 1)
        XCTAssertThrowsError(try log.export(to: root.appendingPathComponent("export")))
        XCTAssertGreaterThan(log.fileFailures, 1)
    }
    func testExportDoesNotModifyJournalHistoryOrReadQueue() throws {
        let root = try directory(), file = DiagnosticFile(directory: root.appendingPathComponent("journal"))
        let log = DevelopmentLog(file: file, role: .host)
        let queue = root.appendingPathComponent("queue.json"), secret = Data("PRIVATE QUEUE TOKEN".utf8)
        try secret.write(to: queue); log.emit(.lifecycle)
        let export = try log.export(to: root.appendingPathComponent("export"))
        XCTAssertEqual(try Data(contentsOf: queue), secret)
        XCTAssertFalse(try String(contentsOf: export, encoding: .utf8).contains("PRIVATE QUEUE TOKEN"))
        XCTAssertEqual(try rows(file.snapshot()).first?["event"] as? String, "lifecycle")
    }
}

@MainActor final class DevelopmentLogFlowTests: XCTestCase {
    let owner = "0x1111111111111111111111111111111111111111"
    let destination = Destination(address: "0x2222222222222222222222222222222222222222", name: "Secret collection", chain_id: 8453)
    func make() throws -> (UploadCoordinator, FixtureAlbum, FixtureTransfers, MemorySessions, DevelopmentLog, URL, StubAPI) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try UploadStore(directory: root.appendingPathComponent("queue"))
        let log = DevelopmentLog(file: DiagnosticFile(directory: root.appendingPathComponent("logs")), role: .host)
        let album = FixtureAlbum(), transfer = FixtureTransfers(), sessions = MemorySessions(), api = StubAPI(owner: owner, collection: destination)
        sessions.value = SavedSession(token: "synthetic-private-token", email: "private@example.invalid", expiresAt: Date().addingTimeInterval(3600))
        let worker = try UploadCoordinator(store: store, library: album, transfer: transfer, notifications: FixtureNotifications(), api: api, sessions: sessions, log: log)
        return (worker, album, transfer, sessions, log, root, api)
    }
    func text(_ log: DevelopmentLog) throws -> String { String(decoding: try XCTUnwrap(log.file).snapshot(), as: UTF8.self) }
    func testSetupCreatePendingAndExportAreSeparateFromSystemRegistration() async throws {
        let (worker, album, transfer, sessions, log, root, _) = try make()
        _ = await worker.prepareSetup()
        await worker.configure(owner: owner, destination: destination, albumID: nil, session: try XCTUnwrap(sessions.value))
        XCTAssertEqual(album.createdAlbums, 1); XCTAssertTrue(transfer.enabled)
        XCTAssertTrue(transfer.submitted.isEmpty); XCTAssertEqual(worker.state.records.first?.status, .pending)
        let before = try Data(contentsOf: worker.store.directory.appendingPathComponent("queue.json"))
        _ = try log.export(to: root.appendingPathComponent("export"))
        XCTAssertEqual(try Data(contentsOf: worker.store.directory.appendingPathComponent("queue.json")), before)
        let events = try text(log)
        for event in ["setup", "albumList", "endpointCheck", "secureSave", "albumCreate", "albumConnect", "extensionEnable", "queueEnqueue", "waitingForExtension"] { XCTAssertTrue(events.contains(event), event) }
        XCTAssertFalse(events.contains("\"event\":\"registration\""))
        XCTAssertFalse(events.contains("synthetic-private-token")); XCTAssertFalse(events.contains("Secret collection"))
    }
    func testWorkerTransferMetadataCreateAndAcknowledgmentStages() async throws {
        let (worker, _, transfer, sessions, log, _, api) = try make()
        await worker.configure(owner: owner, destination: destination, albumID: "private-album", session: try XCTUnwrap(sessions.value))
        _ = await worker.process()
        let id = try XCTUnwrap(worker.state.records.first?.id)
        XCTAssertEqual(transfer.submitted, [id])
        transfer.completed = [TransferEvent(jobID: "private-system-job", operation: id, succeeded: true, message: nil)]
        _ = await worker.process()
        XCTAssertEqual(api.creates, 1); XCTAssertEqual(worker.state.records.first?.status, .published)
        let events = try text(log)
        for stage in ["registration", "acknowledgment", "metadataUpload", "momentSimulate", "momentCreate", "durationMS", "parent"] { XCTAssertTrue(events.contains(stage), stage) }
        XCTAssertFalse(events.contains("private-system-job")); XCTAssertFalse(events.contains("private-album"))
    }
    func testNoWorkExpiredAuthAndSetupFailureHaveDistinctEvidence() async throws {
        let (worker, album, transfer, sessions, log, _, _) = try make()
        album.items = []
        await worker.configure(owner: owner, destination: destination, albumID: "album", session: try XCTUnwrap(sessions.value))
        _ = await worker.process()
        sessions.value = nil
        _ = await worker.process()
        XCTAssertTrue(transfer.submitted.isEmpty)
        let events = try text(log)
        XCTAssertTrue(events.contains("noEligibleWork")); XCTAssertTrue(events.contains("authUnavailable"))
        XCTAssertTrue(events.contains("sessionExpired"))
        sessions.saveFailure = KeychainFailure(operation: "save", status: -34018)
        await worker.configure(owner: owner, destination: destination, albumID: nil, session: SavedSession(token: "secret", email: "secret", expiresAt: Date().addingTimeInterval(3600)))
        XCTAssertEqual(album.createdAlbums, 0)
        XCTAssertTrue(try text(log).contains("-34018"))
    }
    func testCorrectedEmailGetsACodeWithoutWaitingOutTheResendDelay() async throws {
        let (_, _, _, sessions, log, root, _) = try make()
        let api = DiagnosticAuthAPI(owner: owner, destination: destination)
        let model = AppModel(api: api, sessions: sessions, drafts: try DraftStore(directory: root.appendingPathComponent("drafts")), log: log)
        model.email = "wrong@example.invalid"; await model.sendCode()
        XCTAssertTrue(model.codeSent)
        // "Use a different email", then the right address: a code goes out at once.
        model.codeSent = false; model.email = "right@example.invalid"; await model.sendCode()
        XCTAssertEqual(api.codesSentTo, ["wrong@example.invalid", "right@example.invalid"])
        XCTAssertTrue(model.codeSent)
        // Asking again for the same address inside the delay sends nothing more and returns to code entry.
        model.codeSent = false; await model.sendCode()
        XCTAssertEqual(api.codesSentTo.count, 2)
        XCTAssertTrue(model.codeSent)
    }
    func testAuthRequestVerifyRecoveryAndSignOutWithSyntheticSecrets() async throws {
        let (_, _, _, sessions, log, root, _) = try make()
        let api = DiagnosticAuthAPI(owner: owner, destination: destination)
        let model = AppModel(api: api, sessions: sessions, drafts: try DraftStore(directory: root.appendingPathComponent("drafts")), log: log)
        model.email = "private@example.invalid"; await model.sendCode()
        model.code = "654321"; await model.signIn()
        XCTAssertTrue(model.isAuthenticated)
        await model.retryAccount(); model.signOut(); XCTAssertFalse(model.isAuthenticated)
        let events = try text(log)
        for event in ["authCode", "authVerify", "accountLoad", "accountRecovery", "signOut"] { XCTAssertTrue(events.contains(event), event) }
        for secret in [model.email, "654321", api.token, owner, destination.address] { XCTAssertFalse(events.contains(secret)) }
    }
}
private final class DiagnosticAuthAPI: InProcessServing, @unchecked Sendable {
    let owner: String
    let destination: Destination
    init(owner: String, destination: Destination) { self.owner = owner; self.destination = destination }
    var token: String { "synthetic." + Data("{\"exp\":4102444800}".utf8).base64EncodedString() + ".signature" }
    var codesSentTo: [String] = []
    func sendCode(email: String) async throws { codesSentTo.append(email) }
    func login(email: String, code: String) async throws -> LoginResponse { LoginResponse(token: token, social_wallet: owner) }
    func identity(token: APICredential) async throws -> Identity { Identity(artistAddress: owner, profile: .init(username: "Private")) }
    func destination(token: APICredential) async throws -> Destination { destination }
    func upload(data: Data, object: String, contentType: String) async throws -> String { throw AppError.message("Forbidden") }
    func simulate(_ request: CreateMomentRequest, token: APICredential) async throws { throw AppError.message("Forbidden") }
    func create(_ request: CreateMomentRequest, token: APICredential) async throws -> Publication { throw AppError.message("Forbidden") }
    func reconcile(_ draft: Draft, token: APICredential) async throws -> Publication? { nil }
}
