#if DEBUG && targetEnvironment(simulator)
import Foundation
import UIKit
import CoreFoundation

@MainActor final class FixtureAlbum: AlbumAccess {
    var granted = true
    var accessRequests = 0
    var didRequestAccess: (() -> Void)?
    var createdAlbums = 0
    var accessResult: PhotosAccessStatus?
    var availableAlbums: [AlbumChoice]?
    var failAlbumRead = false
    var holdAccessRequest = false
    var pendingAccess: CheckedContinuation<Void, Never>?

    var missing = false
    var name = "In Process"
    var accessOverride: PhotosAccessStatus?
    var authorizationStatus: PhotosAccessStatus { accessOverride ?? (granted ? .full : .denied) }
    func albumName(for id: String) throws -> String {
        guard authorizationStatus == .full else { throw LibraryProblem.permission }
        guard !missing else { throw LibraryProblem.missingAlbum }
        return name
    }
    var items = [LibraryPhoto(id: "fixture-current-edited-photo", revision: "edited-v1", mime: "image/heic", fileExtension: "heic")]
    func requestAccess() async -> Bool {
        accessRequests += 1; didRequestAccess?()
        if holdAccessRequest { await withCheckedContinuation { pendingAccess = $0 } }
        if let accessResult { accessOverride = accessResult; granted = accessResult == .full }
        return authorizationStatus == .full
    }
    func albums() throws -> [AlbumChoice] {
        guard authorizationStatus == .full else { throw LibraryProblem.permission }
        if failAlbumRead { throw AppError.message("Injected album read interruption.") }
        return availableAlbums ?? [AlbumChoice(id: "fixture-album", name: "In Process", count: items.count)]
    }
    func createAlbum() async throws -> String { createdAlbums += 1; return "fixture-created-album" }
    var added = 0
    func add(_ assetIDs: [String], to album: String) async throws {
        if !granted { throw LibraryProblem.permission }
        for id in assetIDs where !items.contains(where: { $0.id == id }) {
            items.append(LibraryPhoto(id: id, revision: "v1", mime: "image/jpeg", fileExtension: "jpg"))
        }
    }
    func remove(_ assetIDs: [String], from album: String) async throws {
        if !granted { throw LibraryProblem.permission }
        items.removeAll { assetIDs.contains($0.id) }
    }
    var failData = false
    var didReadData: (() -> Void)?
    /// Holds the transfer open so a test can observe the uploading state.
    var dataDelay: Duration?
    func data(for assetID: String) async throws -> Data {
        didReadData?()
        if let dataDelay { try await Task.sleep(for: dataDelay) }
        if failData { throw AppError.message("Injected photo read failure.") }
        return Data("fixture-bytes-\(assetID)".utf8)
    }
    /// Stands in for a two-photo picker selection.
    var fixtureSelection: (() -> [String])? {
        { [self] in added += 2; return ["fixture-added-\(added - 1)", "fixture-added-\(added)"] }
    }
    /// A flat generated tile per photo; no real library is read.
    func thumbnail(for assetID: String, side: CGFloat) async -> UIImage? {
        let seed = Double(assetID.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 9973 })
        let hue = CGFloat((seed * 0.618034).truncatingRemainder(dividingBy: 1)) // Golden-ratio steps keep neighbouring tiles distinct.
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            UIColor(hue: hue, saturation: 0.45, brightness: 0.8, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }
    func photos(in album: String) async throws -> [LibraryPhoto] {
        if !granted { throw LibraryProblem.permission }
        if missing { throw LibraryProblem.missingAlbum }
        return items
    }
}
@MainActor final class FixtureNotifications: UploadNotifying {
    var permission: NotificationAccessStatus = .notRequested
    func authorizationStatus() async -> NotificationAccessStatus { permission }
    var requested = false
    var messages: [String] = []
    var didNotify: (() -> Void)?
    func requestPermission() async { requested = true; permission = .allowed }
    func notify(id: String, message: String) async { messages.append(id); didNotify?() }
}
@MainActor final class FixtureTransfers: ResourceTransferring {
    var compatible = true
    var enabled = false
    var isEnabled: Bool { enabled }
    var cellular = true
    var submitted: [UUID] = []
    var completed: [TransferEvent] = []
    var acknowledged: [String] = []
    var failAcknowledgment = false
    var didAcknowledge: (() throws -> Void)?
    func validateEndpoint() async throws {
        if !compatible { throw AppError.message("The upload endpoint has not passed the Photos background-transfer check.") }
    }
    func enable(cellular: Bool) throws { enabled = true; self.cellular = cellular }
    func disable() throws { enabled = false }
    func events() async throws -> [TransferEvent] { completed }
    func submit(_ record: UploadRecord, cellular: Bool) async throws -> Bool {
        if submitted.contains(record.id) { return false }
        submitted.append(record.id); return true
    }
    func acknowledge(_ event: TransferEvent) async throws {
        try didAcknowledge?()
        if failAcknowledgment { throw AppError.message("Injected acknowledgment interruption") }
        acknowledged.append(event.jobID); completed.removeAll { $0.jobID == event.jobID }
    }
    func cancel(operation: UUID) async throws { submitted.removeAll { $0 == operation } }
    func publicURI(for draft: Draft) -> String { "https://fixture.example.invalid/\(draft.mediaObject)" }
}
final class FixtureSessions: SessionStoring {
    var failNextSave = false
    var session: SavedSession?
    func load() throws -> SavedSession? { session }
    func save(_ session: SavedSession) throws {
        if failNextSave { failNextSave = false; throw KeychainFailure(operation: "save", status: -34018) }
        self.session = session
    }
    func clear() throws { session = nil }
}
final class MemoryCredentialVault: CredentialVault {
    var value = CredentialVaultState()
    var failRead = false
    var failUpdate: ((CredentialVaultState) -> Bool)?
    func snapshot() throws -> CredentialVaultState {
        if failRead { throw KeychainFailure(operation: "read", status: -25308) }
        return value
    }
    func update(expected: UUID, _ body: (inout CredentialVaultState) throws -> Void) throws -> CredentialVaultState {
        guard value.revision == expected else { throw CredentialSetupError.changed }
        var next = value; try body(&next)
        if failUpdate?(next) == true { throw KeychainFailure(operation: "save", status: -34018) }
        next.revision = UUID(); value = next; return next
    }
}
@MainActor @Observable final class AutomaticUITestAPI: InProcessServing {
    var creates = 0
    var keyCreates = 0
    var keys: [ArtistKeyRecord] = []
    var rejectOldKey = false
    var failRevocation = false
    func createArtistKey(name: String, bootstrap: APICredential) async throws -> String {
        keyCreates += 1; keys.append(ArtistKeyRecord(id: UUID().uuidString, name: name))
        return "art_sk_fixture_only_\(keyCreates)"
    }
    func artistKeys(token: APICredential) async throws -> [ArtistKeyRecord] { keys }
    func revokeArtistKey(id: String, token: APICredential) async throws {
        if failRevocation { throw URLError(.notConnectedToInternet) }
        keys.removeAll { $0.id == id }
    }
    var failAccountOnce = false
    var eventsHandled = 0
    @ObservationIgnored private weak var model: AppModel?
    func observeEvents(runID: UUID, model: AppModel) {
        self.model = model
        for event in ["status", "expire"] {
            let name = "com.xdjs.InProcess.ui-test.automatic.\(runID.uuidString).\(event)"
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(), { _, observer, name, _, _ in
                    guard let observer, let name else { return }
                    let service = Unmanaged<AutomaticUITestAPI>.fromOpaque(observer).takeUnretainedValue()
                    let event = name.rawValue as String
                    Task { @MainActor in service.receive(event) }
                }, name as CFString, nil, .deliverImmediately)
        }
    }
    private func receive(_ event: String) {
        defer { eventsHandled += 1 }
        if event.hasSuffix(".status") {
            // Same in-app entry point as a notification tap; no real notification.
            NotificationCenter.default.post(name: .openUploadStatus, object: nil)
        } else if event.hasSuffix(".expire"), let model, let session = model.session {
            let expiring = SavedSession(token: session.token, email: session.email, expiresAt: Date().addingTimeInterval(0.2))
            try? model.sessions.save(expiring)
            model.session = expiring // Exercise the real expiry task in RootView.
        }
    }
    deinit {
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
    }
    func sendCode(email: String) async throws { }
    func login(email: String, code: String) async throws -> LoginResponse {
        let payload = try JSONSerialization.data(withJSONObject: ["exp": Date().addingTimeInterval(3600).timeIntervalSince1970]).base64EncodedString()
        return LoginResponse(token: "fixture.\(payload).fixture", social_wallet: PublishUITestService.person.artistAddress)
    }
    func identity(token: APICredential) async throws -> Identity {
        if rejectOldKey && token.kind == .artistKey && token.secret == "art_sk_fixture_revoked" { throw AppError.sessionExpired }
        if failAccountOnce { failAccountOnce = false; throw AppError.message("Fixture account loading interrupted. Try again.") }
        return PublishUITestService.person
    }
    func destination(token: APICredential) async throws -> Destination { PublishUITestService.collection }
    func upload(data: Data, object: String, contentType: String) async throws -> String { "https://fixture.example.invalid/\(object)" }
    func simulate(_ request: CreateMomentRequest, token: APICredential) async throws {}
    func create(_ request: CreateMomentRequest, token: APICredential) async throws -> Publication {
        creates += 1
        return Publication(contractAddress: PublishUITestService.collection.address, tokenId: String(creates), hash: "0xfixture", chainId: 8453)
    }
    func reconcile(_ draft: Draft, token: APICredential) async throws -> Publication? { nil }
}
@MainActor enum AutomaticUIFixture {
    static func makeModel() throws -> AppModel {
        guard let run = ProcessInfo.processInfo.environment["INPROCESS_UI_TEST_RUN_ID"].flatMap(UUID.init(uuidString:)) else { throw AppError.message("Missing automatic UI fixture ID. Live services remain disabled.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AutomaticUITests/\(run.uuidString)")
        let sessions = FixtureSessions(), library = FixtureAlbum(), transfers = FixtureTransfers(), notifications = FixtureNotifications()
        let api = AutomaticUITestAPI()
        let scenario = ProcessInfo.processInfo.environment["INPROCESS_UI_TEST_SCENARIO"] ?? "setup"
        if ["keySignIn", "keyRevoked", "keySignOutOffline"].contains(scenario) {
            let vault = MemoryCredentialVault()
            let vaultSessions = VaultSessions(vault: vault)
            let setup = ArtistCredentialSetup(vault: vault, api: api)
            let store = try UploadStore(directory: directory.appendingPathComponent("queue"))
            if scenario != "keySignIn" {
                let label = "In Process iPhone fixture-old", id = UUID().uuidString
                vault.value.active = SavedSession(token: "art_sk_fixture_revoked", email: "fixture@example.invalid", expiresAt: .distantPast, kind: .artistKey, owner: PublishUITestService.person.artistAddress, keyID: id, keyLabel: label)
                api.keys = [ArtistKeyRecord(id: id, name: label)]
                api.rejectOldKey = scenario == "keyRevoked"; api.failRevocation = scenario == "keySignOutOffline"
                try store.update { $0.configuration = AutomaticConfiguration(owner: PublishUITestService.person.artistAddress, destination: PublishUITestService.collection, albumID: "fixture-album") }
            }
            let coordinator = try UploadCoordinator(store: store, library: library, transfer: transfers, notifications: notifications, api: api, sessions: vaultSessions)
            coordinator.foregroundUploads = false
            let model = AppModel(api: api, sessions: vaultSessions, drafts: try DraftStore(directory: directory.appendingPathComponent("drafts")), automatic: coordinator, credentialSetup: setup)
            api.observeEvents(runID: run, model: model)
            return model
        }
        api.failAccountOnce = scenario == "accountRecovery"
        library.granted = scenario != "denied"
        // Setup creates the album itself, so most scenarios start with none. `albumWithPhotos` keeps the filled default.
        if scenario != "albumWithPhotos" { library.availableAlbums = [] }
        if scenario == "emptyAlbum" { library.availableAlbums = [AlbumChoice(id: "fixture-album", name: "In Process", count: 0)]; library.items = [] }
        if scenario == "firstGrant" { library.accessOverride = .notRequested; library.accessResult = .full }
        if scenario == "limited" || scenario == "settingsGrant" { library.accessOverride = .limited }
        if scenario == "settingsGrant" {
            _ = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { library.accessOverride = .full }
            }
        }
        if scenario == "albumReadFailure" { library.failAlbumRead = true }
        transfers.compatible = scenario != "incompatible"
        let saved = SavedSession(token: "fixture-only", email: "fixture@example.invalid", expiresAt: scenario == "expired" ? .distantPast : Date().addingTimeInterval(3600))
        if scenario != "signedOut" { try sessions.save(saved) }
        let store = try UploadStore(directory: directory.appendingPathComponent("queue"))
        if scenario == "albumGrid" {
            // One of each visible state: three published, one failed, the rest left for the scan to queue.
            library.items = (1...7).map { LibraryPhoto(id: "fixture-grid-\($0)", revision: "v1", mime: "image/jpeg", fileExtension: "jpg") }
            transfers.enabled = true
            try store.update { state in
                for (index, photo) in library.items.prefix(4).enumerated() {
                    var draft = Draft(owner: PublishUITestService.person.artistAddress, destination: PublishUITestService.collection)
                    draft.sourceAssetID = photo.id; draft.mediaMIME = photo.mime; draft.mediaExtension = photo.fileExtension
                    var record = UploadRecord(draft: draft, automatic: true, revision: photo.revision)
                    if index < 3 {
                        record.draft.stage = .published; record.status = .published
                        record.draft.result = Publication(contractAddress: PublishUITestService.collection.address, tokenId: String(index + 1), hash: "0xfixture", chainId: 8453)
                    } else { record.status = .failed; record.attempts = 3; record.reason = "Fixture transfer failed." }
                    state.records.append(record)
                }
            }
        }
        if ["expired", "configuration", "restoredConfigured", "albumGrid", "foregroundUpload"].contains(scenario) {
            try store.update {
                $0.configuration = AutomaticConfiguration(owner: PublishUITestService.person.artistAddress, destination: PublishUITestService.collection, albumID: "fixture-album")
            }
        }
        if scenario == "foregroundUpload" {
            // Automatic off with two photos waiting, and a slow transfer so the uploading state is visible.
            library.items = (1...2).map { LibraryPhoto(id: "fixture-foreground-\($0)", revision: "v1", mime: "image/jpeg", fileExtension: "jpg") }
            library.dataDelay = .seconds(2)
            transfers.enabled = true
            try store.update { $0.configuration?.autoUpload = false }
        }
        if scenario == "configuration" {
            library.name = "Studio process"
            transfers.enabled = true
            notifications.permission = .quiet
            // Model a Settings change while the fixture app is backgrounded.
            // No real Photos or notification adapters are instantiated here.
            _ = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    library.accessOverride = .limited
                    notifications.permission = .denied
                    transfers.enabled = false
                }
            }
        }
        let coordinator = try UploadCoordinator(store: store, library: library, transfer: transfers, notifications: notifications, api: api, sessions: sessions)
        // Most scenarios need the queue to stand still; `foregroundUpload` exercises the app's own uploading.
        coordinator.foregroundUploads = scenario == "foregroundUpload"
        let model = AppModel(api: api, sessions: sessions, drafts: try DraftStore(directory: directory.appendingPathComponent("drafts")), automatic: coordinator)
        if !["expired", "signedOut", "restored", "restoredConfigured", "accountRecovery"].contains(scenario) {
            model.didRestore = true; model.session = saved; model.identity = PublishUITestService.person; model.destination = PublishUITestService.collection
            model.draft = Draft(owner: PublishUITestService.person.artistAddress, destination: PublishUITestService.collection)
        }
        if let route = ProcessInfo.processInfo.environment["INPROCESS_UI_TEST_ROUTE"] {
            switch route {
            case "manual": model.route = .manual
            case "setup": model.route = .setup
            default: model.route = .home
            }
        }
        sessions.failNextSave = scenario == "secureSaveFailure"
        api.observeEvents(runID: run, model: model)
        return model
    }
}
#endif
