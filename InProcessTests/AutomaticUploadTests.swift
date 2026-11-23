import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
import Photos
@testable import InProcess

@MainActor final class AutomaticUploadTests: XCTestCase {
    let owner = "0x1111111111111111111111111111111111111111"
    let destination = Destination(address: "0x2222222222222222222222222222222222222222", name: "Process", chain_id: 8453)
    var time = Date(timeIntervalSince1970: 1_900_000_000)
    func make() throws -> (UploadCoordinator, FixtureAlbum, FixtureTransfers, FixtureNotifications, MemorySessions, StubAPI) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        let store = try UploadStore(directory: path)
        try store.update { $0.configuration = AutomaticConfiguration(owner: owner, destination: destination, albumID: "album") }
        let library = FixtureAlbum(), transfers = FixtureTransfers(), notifications = FixtureNotifications(), sessions = MemorySessions()
        sessions.value = SavedSession(token: "test-only", email: "test@example.invalid", expiresAt: time.addingTimeInterval(3600))
        let api = StubAPI(owner: owner, collection: destination)
        let coordinator = try UploadCoordinator(store: store, library: library, transfer: transfers, notifications: notifications, api: api, sessions: sessions, now: { self.time })
        return (coordinator, library, transfers, notifications, sessions, api)
    }
    func testSecureSaveFailureCreatesNoAlbumAndRetryPreservesQueue() async throws {
        let (worker, library, transfer, notices, sessions, api) = try make()
        _ = await worker.scan()
        let records = try worker.store.read().records.map(\.id)
        try worker.store.update { $0.configuration = nil }
        let saved = try XCTUnwrap(sessions.value)
        sessions.saveFailure = KeychainFailure(operation: "save", status: -34018)
        await worker.configure(owner: owner, destination: destination, albumID: nil, session: saved)
        XCTAssertTrue(worker.error?.contains("-34018") == true)
        XCTAssertEqual(library.createdAlbums, 0)
        XCTAssertNil(try worker.store.read().configuration)
        XCTAssertEqual(try worker.store.read().records.map(\.id), records)
        XCTAssertEqual(sessions.value?.token, saved.token)
        XCTAssertFalse(transfer.enabled); XCTAssertFalse(notices.requested)
        sessions.saveFailure = nil
        await worker.configure(owner: owner, destination: destination, albumID: nil, session: saved)
        XCTAssertNil(worker.error)
        XCTAssertEqual(library.createdAlbums, 1)
        XCTAssertEqual(try worker.store.read().configuration?.albumID, "fixture-created-album")
        XCTAssertEqual(try worker.store.read().records.map(\.id), records)
        XCTAssertEqual(api.creates, 0)
    }
    func testRetryExistingAlbumAfterSecureSaveFailureDoesNotCreateAnother() async throws {
        let (worker, library, transfer, _, sessions, _) = try make()
        try worker.store.update { $0.configuration = nil }
        let saved = try XCTUnwrap(sessions.value)
        sessions.saveFailure = KeychainFailure(operation: "save", status: -34018)
        await worker.configure(owner: owner, destination: destination, albumID: "existing-album", session: saved)
        XCTAssertFalse(transfer.enabled)
        sessions.saveFailure = nil
        await worker.configure(owner: owner, destination: destination, albumID: "existing-album", session: saved)
        XCTAssertEqual(try worker.store.read().configuration?.albumID, "existing-album")
        XCTAssertEqual(library.createdAlbums, 0)
    }

    func testAlbumPreparationWithFullAccessDoesNotRequestOrCreate() async throws {
        let (worker, library, transfer, _, _, api) = try make()
        let prepared = await worker.prepareSetup(); XCTAssertTrue(prepared)
        XCTAssertEqual(worker.choices.map(\.id), ["fixture-album"])
        XCTAssertEqual(library.accessRequests, 0)
        library.availableAlbums = []
        let emptyPrepared = await worker.prepareSetup(); XCTAssertTrue(emptyPrepared, "An empty album list still advances to the create option.")
        XCTAssertTrue(worker.choices.isEmpty)
        XCTAssertEqual(library.createdAlbums, 0)
        XCTAssertFalse(transfer.enabled)
        XCTAssertEqual(api.creates, 0)
    }
    func testInitialPermissionProgressRejectsDuplicateRequestsAndAdvances() async throws {
        let (worker, library, _, _, _, _) = try make()
        library.accessOverride = .notRequested; library.accessResult = .full; library.holdAccessRequest = true
        let requested = expectation(description: "Permission request begins")
        library.didRequestAccess = { requested.fulfill() }
        let preparation = Task { await worker.prepareSetup() }
        await fulfillment(of: [requested], timeout: 2)
        guard let permission = library.pendingAccess else { preparation.cancel(); XCTFail("No permission request to complete"); return }
        XCTAssertTrue(worker.preparingSetup)
        let rejected = await worker.prepareSetup(); XCTAssertFalse(rejected)
        XCTAssertEqual(library.accessRequests, 1)
        permission.resume(); library.pendingAccess = nil
        let finished = await preparation.value; XCTAssertTrue(finished)
        XCTAssertFalse(worker.preparingSetup)
        XCTAssertEqual(worker.photosAccess, .full)
        XCTAssertEqual(worker.choices.count, 1)
    }
    func testAlbumPreparationPermissionAndReadFailuresRecoverWithoutStaleChoices() async throws {
        let (worker, library, _, _, _, _) = try make()
        for status: PhotosAccessStatus in [.limited, .denied, .restricted] {
            library.accessOverride = status
            let rejected = await worker.prepareSetup(); XCTAssertFalse(rejected)
            XCTAssertFalse(worker.preparingSetup)
            XCTAssertNotNil(worker.error)
            XCTAssertTrue(worker.choices.isEmpty)
        }
        XCTAssertEqual(library.accessRequests, 0)
        library.accessOverride = .full
        let prepared = await worker.prepareSetup(); XCTAssertTrue(prepared)
        library.failAlbumRead = true
        let rejected = await worker.prepareSetup(); XCTAssertFalse(rejected)
        XCTAssertTrue(worker.choices.isEmpty)
        XCTAssertTrue(worker.error?.contains("Couldn’t read your Photos albums") == true)
        library.failAlbumRead = false
        let retried = await worker.prepareSetup(); XCTAssertTrue(retried)
        XCTAssertNil(worker.error)
        XCTAssertEqual(library.createdAlbums, 0)
    }

    func testSignOutAndSignInWithoutAnAlbumLeaveNoBlocker() async throws {
        let (worker, _, _, _, sessions, _) = try make()
        try worker.store.update { $0.configuration = nil }
        worker.signOut()
        XCTAssertNil(try worker.store.read().blocker, "Nothing is connected, so there is nothing to resume")
        // A note left behind by an earlier build is cleared at the next sign-in.
        try worker.store.update { $0.blocker = "Sign in to resume uploads." }
        let session = SavedSession(token: "test-only", email: "test@example.invalid", expiresAt: time.addingTimeInterval(3600))
        sessions.value = session
        await worker.resumeSession(session, owner: owner)
        XCTAssertNil(try worker.store.read().blocker)
        XCTAssertNil(worker.state.blocker)
        XCTAssertFalse(worker.configured)
    }
    func testSignOutWithAnAlbumStillAsksToSignInAgain() async throws {
        let (worker, _, _, _, _, _) = try make()
        worker.signOut()
        XCTAssertEqual(try worker.store.read().blocker, "Sign in to resume uploads.")
        XCTAssertEqual(try worker.store.read().configuration?.signedOut, true)
    }
    func testAuthenticationTransitionsPreserveConfigurationQueueAndDraft() async throws {
        let (worker, _, transfers, _, sessions, _) = try make()
        _ = await worker.scan()
        let original = try worker.store.read()
        XCTAssertFalse(original.records.isEmpty)
        let drafts = try DraftStore(directory: worker.store.directory.appendingPathComponent("drafts"))
        let draft = Draft(owner: owner, destination: destination)
        try drafts.save(draft)
        let api = AutomaticUITestAPI()
        let model = AppModel(api: api, sessions: sessions, drafts: drafts, automatic: worker)
        await model.restore()
        XCTAssertTrue(model.isAuthenticated)
        XCTAssertEqual(model.route, .home)
        model.route = .manual
        model.session = SavedSession(token: "expired", email: "test@example.invalid", expiresAt: .distantPast)
        model.expireSessionIfNeeded()
        XCTAssertFalse(model.isAuthenticated)
        XCTAssertNil(model.destination)
        XCTAssertEqual(model.route, .home)
        XCTAssertEqual(try drafts.load()?.id, draft.id)
        XCTAssertEqual(try worker.store.read().records.map(\.id), original.records.map(\.id))
        XCTAssertEqual(try worker.store.read().configuration?.albumID, original.configuration?.albumID)
        model.openUploadStatus()
        XCTAssertFalse(model.isAuthenticated)
        model.code = "123456"
        await model.signIn()
        XCTAssertTrue(model.isAuthenticated)
        XCTAssertEqual(model.route, .home)
        model.signOut()
        XCTAssertFalse(model.isAuthenticated)
        XCTAssertNil(try sessions.load())
        XCTAssertFalse(transfers.enabled)
        XCTAssertEqual(try drafts.load()?.id, draft.id)
        XCTAssertEqual(try worker.store.read().records.map(\.id), original.records.map(\.id))
        XCTAssertEqual(try worker.store.read().configuration?.albumID, original.configuration?.albumID)
        XCTAssertEqual(try worker.store.read().configuration?.signedOut, true)
        XCTAssertEqual(api.creates, 0)
    }

    func testExtensionDiscoversAlbumAdditionAfterEmptyQueueWithoutHostScan() async throws {
        let (initial, library, transfers, notices, sessions, api) = try make()
        let existingPhoto = try XCTUnwrap(library.items.first)
        library.items = []
        transfers.enabled = true
        let idle = await initial.processForExtension()
        XCTAssertEqual(idle, .completed)
        XCTAssertTrue(try initial.store.read().records.isEmpty)

        // An existing asset joins the connected album without changing its revision.
        // No host, Photos observer callback, configure/resume call, or scan runs.
        library.items = [existingPhoto]
        func invocation() throws -> UploadCoordinator {
            try UploadCoordinator(store: UploadStore(directory: initial.store.directory), library: library,
                transfer: transfers, notifications: notices, api: api, sessions: sessions, now: { self.time })
        }
        let discovered = await (try invocation()).processForExtension()
        XCTAssertEqual(discovered, .processing)
        let record = try XCTUnwrap(initial.store.read().records.first)
        XCTAssertEqual(record.draft.sourceAssetID, existingPhoto.id)
        XCTAssertEqual(record.revision, existingPhoto.revision)
        XCTAssertEqual(record.status, .uploading)
        XCTAssertEqual(transfers.submitted, [record.id])
        XCTAssertEqual(api.creates, 0)

        transfers.completed = [TransferEvent(jobID: "independent-discovery-job", operation: record.id, succeeded: true, message: nil)]
        let published = await (try invocation()).processForExtension()
        XCTAssertEqual(published, .processing)
        XCTAssertEqual(try initial.store.read().records.first?.status, .published)
        XCTAssertEqual(transfers.acknowledged, ["independent-discovery-job"])
        let settled = await (try invocation()).processForExtension()
        XCTAssertEqual(settled, .completed)
        XCTAssertEqual(api.creates, 1)
        XCTAssertEqual(try initial.store.read().records.count, 1)
        XCTAssertEqual(library.accessRequests, 0)
        XCTAssertEqual(library.createdAlbums, 0)
    }

    func testExtensionDoesNotReportCompletedWhenDiscoveryIsBlocked() async throws {
        for blocker in ["expired", "expiredPending", "permission", "missingAlbum", "wrongAccount"] {
            let (worker, library, transfers, _, sessions, api) = try make()
            XCTAssertTrue(try worker.store.read().records.isEmpty)
            let validSession = sessions.value
            if blocker == "expiredPending" { _ = await worker.scan() }
            let originalIDs = try worker.store.read().records.map(\.id)
            switch blocker {
            case "expired", "expiredPending": sessions.value = SavedSession(token: "expired-test-only", email: "test@example.invalid", expiresAt: time.addingTimeInterval(-1))
            case "permission": library.granted = false
            case "missingAlbum": library.missing = true
            default: api.owner = "0x3333333333333333333333333333333333333333"
            }
            let outcome = await worker.processForExtension()
            XCTAssertEqual(outcome, .failure, blocker)
            XCTAssertNotNil(try worker.store.read().blocker, blocker)
            XCTAssertTrue(transfers.submitted.isEmpty, blocker)
            XCTAssertEqual(api.creates, 0, blocker)
            if blocker == "expiredPending" { XCTAssertEqual(try worker.store.read().records.map(\.id), originalIDs) }

            // After the external blocker clears, a new extension invocation can
            // discover/resume work without a host scan or queue replacement.
            sessions.value = validSession; library.granted = true; library.missing = false; api.owner = owner
            let restored = try UploadCoordinator(store: UploadStore(directory: worker.store.directory),
                library: library, transfer: transfers, notifications: worker.notifications,
                api: api, sessions: sessions, now: { self.time })
            let resumed = await restored.processForExtension()
            XCTAssertEqual(resumed, .processing, blocker)
            XCTAssertNil(try worker.store.read().blocker, blocker)
            XCTAssertEqual(transfers.submitted.count, 1, blocker)
            XCTAssertEqual(api.creates, 0, blocker)
            if blocker == "expiredPending" { XCTAssertEqual(try worker.store.read().records.map(\.id), originalIDs) }
        }
    }

    func testExtensionKeepsProcessingAnAlreadyRegisteredTransfer() async throws {
        let (worker, library, transfers, notices, sessions, api) = try make()
        let first = await worker.processForExtension()
        XCTAssertEqual(first, .processing)
        let ids = try worker.store.read().records.map(\.id)
        let restored = try UploadCoordinator(store: UploadStore(directory: worker.store.directory), library: library,
            transfer: transfers, notifications: notices, api: api, sessions: sessions, now: { self.time })
        let waiting = await restored.processForExtension()
        XCTAssertEqual(waiting, .processing, "A registered job still awaiting its terminal event is not a completed upload cycle")
        XCTAssertEqual(transfers.submitted, ids)
        XCTAssertEqual(api.creates, 0)
        XCTAssertEqual(try worker.store.read().records.first?.status, .uploading)
    }

    func testWakeProbePausesAndRequiresCardRemovalBeforeRestoring() throws {
        let (worker, _, _, _, _, _) = try make()
        let configuration = try XCTUnwrap(worker.store.read().configuration)
        let storage = AlbumWakeProbeStorage(store: worker.store)
        let record = AlbumWakeProbeRecord(id: UUID(), owner: configuration.owner, albumID: configuration.albumID,
            probeAssetID: "synthetic-only", originalPaused: configuration.paused, originalEnabled: true,
            cellular: configuration.cellular, token: Data("isolated-token".utf8))
        try storage.arm(record)
        XCTAssertEqual(try worker.store.read().configuration?.paused, true)
        var restored = false
        XCTAssertThrowsError(try storage.restore(probeIsOutsideAlbum: false) { restored = true })
        XCTAssertFalse(restored)
        XCTAssertEqual(try storage.read().id, record.id)
        XCTAssertThrowsError(try storage.restore(probeIsOutsideAlbum: true) { throw AppError.message("Injected enable failure") })
        XCTAssertEqual(try worker.store.read().configuration?.paused, true)
        XCTAssertEqual(try storage.read().id, record.id)
        try storage.restore(probeIsOutsideAlbum: true) { restored = true }
        XCTAssertTrue(restored)
        XCTAssertEqual(try worker.store.read().configuration, configuration)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.marker.path))
        XCTAssertTrue(try worker.store.read().records.isEmpty)
    }

    func testWakeProbeRejectsQueuedWorkAndHeldPublicationLease() async throws {
        let (worker, _, _, _, _, _) = try make()
        let configuration = try XCTUnwrap(worker.store.read().configuration)
        let storage = AlbumWakeProbeStorage(store: worker.store)
        let record = AlbumWakeProbeRecord(id: UUID(), owner: configuration.owner, albumID: configuration.albumID,
            probeAssetID: "synthetic-only", originalPaused: false, originalEnabled: true,
            cellular: true, token: Data())
        do {
            let lease = try XCTUnwrap(worker.store.lease())
            XCTAssertThrowsError(try storage.arm(record))
            withExtendedLifetime(lease) {}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.marker.path))
        _ = await worker.scan()
        XCTAssertThrowsError(try storage.arm(record))
        XCTAssertEqual(try worker.store.read().configuration, configuration)
        XCTAssertEqual(try worker.store.read().records.count, 1)
    }

    func testWakeProbeFailsClosedOnSimulator() {
        XCTAssertThrowsError(try AlbumWakeProbe.requirePhysicalDevice())
    }

    func testExtensionDoesNotEnterMonitoringWithoutAnOpportunityToProcess() async throws {
        for reason in ["lease", "offline", "networkPolicy"] {
            let (worker, _, transfers, _, _, api) = try make()
            _ = await worker.scan()
            let ids = try worker.store.read().records.map(\.id)
            let heldLease = reason == "lease" ? try worker.store.lease() : nil
            if reason == "offline" { worker.online = false }
            if reason == "networkPolicy" {
                worker.expensive = true
                try worker.store.update { $0.configuration?.cellular = false }
            }
            let outcome = await worker.processForExtension()
            withExtendedLifetime(heldLease) {}
            XCTAssertEqual(outcome, .failure, reason)
            XCTAssertEqual(try worker.store.read().records.map(\.id), ids)
            XCTAssertTrue(transfers.submitted.isEmpty)
            XCTAssertEqual(api.creates, 0)
        }
    }

    func testDiscoveryRemovalAndRestartDeduplicate() async throws {
        let (worker, library, _, _, _, _) = try make()
        let firstScan = await worker.scan(); let secondScan = await worker.scan()
        XCTAssertTrue(firstScan); XCTAssertTrue(secondScan)
        XCTAssertEqual(try worker.store.read().records.count, 1)
        library.items = []; _ = await worker.scan()
        XCTAssertEqual(try worker.store.read().records.first?.status, .canceled)
        XCTAssertEqual(try UploadStore(directory: worker.store.directory).read().records.first?.status, .canceled)
    }
    func testConfigurationReadbackRefreshesWithoutCreatingWork() async throws {
        let (worker, library, transfers, notifications, _, api) = try make()
        library.name = "Renamed studio album"
        transfers.enabled = true
        notifications.permission = .quiet
        await worker.refreshConfiguration()
        XCTAssertEqual(worker.connectedAlbumName, "Renamed studio album")
        XCTAssertEqual(worker.photosAccess, .full)
        XCTAssertEqual(worker.notificationAccess, .quiet)
        XCTAssertEqual(worker.automaticStatus, "Enabled")
        XCTAssertEqual(worker.sessionStatus, "Valid")

        library.accessOverride = .limited
        notifications.permission = .denied
        transfers.enabled = false
        time = time.addingTimeInterval(3601)
        await worker.refreshConfiguration()
        XCTAssertEqual(worker.connectedAlbumName, "Full Photos access needed")
        XCTAssertEqual(worker.photosAccess, .limited)
        XCTAssertEqual(worker.notificationAccess, .denied)
        XCTAssertEqual(worker.automaticStatus, "Disabled")
        XCTAssertEqual(worker.sessionStatus, "Sign in needed")

        library.accessOverride = .full; library.missing = true
        try worker.store.update { $0.configuration?.paused = true; $0.configuration?.cellular = false }
        await worker.refreshConfiguration()
        XCTAssertEqual(worker.connectedAlbumName, "Album unavailable")
        XCTAssertEqual(worker.automaticStatus, "Paused")
        XCTAssertEqual(worker.state.configuration?.cellular, false)
        XCTAssertFalse(notifications.requested)
        XCTAssertTrue(try worker.store.read().records.isEmpty)
        XCTAssertTrue(transfers.submitted.isEmpty)
        XCTAssertEqual(api.creates, 0)
    }
    func testDiagnosticRegistrationRequiresBothBackgroundAndTimeGate() {
        var record = PhotoDiagnosticRecord(assetID: "synthetic-only")
        record.scenario = "Mirroring disconnected"
        record.notBefore = time.addingTimeInterval(90)
        record.hostIsBackground = false
        XCTAssertFalse(record.registrationAllowed(at: time.addingTimeInterval(100)))
        record.hostIsBackground = true
        XCTAssertFalse(record.registrationAllowed(at: time.addingTimeInterval(89)))
        XCTAssertTrue(record.registrationAllowed(at: time.addingTimeInterval(90)))
        record.notBefore = nil
        XCTAssertFalse(record.registrationAllowed(at: time.addingTimeInterval(100)))
    }
    func testTransferCheckpointPrecedesAcknowledgmentAndPublishesOnce() async throws {
        let (worker, _, transfers, _, _, api) = try make()
        _ = await worker.process()
        let record = try XCTUnwrap(worker.store.read().records.first)
        XCTAssertEqual(record.draft.mime, "image/heic")
        XCTAssertEqual(record.revision, "edited-v1")
        XCTAssertEqual(transfers.submitted.count, 1)
        XCTAssertEqual(api.creates, 0)
        transfers.didAcknowledge = { XCTAssertNotNil(try worker.store.read().records.first?.draft.mediaURI) }
        let event = TransferEvent(jobID: "job", operation: record.id, succeeded: true, message: nil)
        transfers.completed = [event]
        _ = await worker.process()
        XCTAssertEqual(api.creates, 1)
        XCTAssertEqual(try worker.store.read().records.first?.status, .published)
        transfers.completed = [event] // Duplicate delivery after process reconstruction.
        let restored = try UploadCoordinator(store: worker.store, library: worker.library, transfer: transfers, notifications: worker.notifications, api: api, sessions: worker.sessions, now: { self.time })
        _ = await restored.process()
        XCTAssertEqual(api.creates, 1)
    }
    func testLostCreateResponseNeverBroadcastsAgainAfterRestart() async throws {
        let (worker, _, transfers, _, _, api) = try make()
        _ = await worker.process()
        let record = try XCTUnwrap(worker.store.read().records.first)
        transfers.completed = [TransferEvent(jobID: "job", operation: record.id, succeeded: true, message: nil)]
        api.failCreate = true
        _ = await worker.process()
        XCTAssertEqual(try worker.store.read().records.first?.status, .uncertain)
        let restored = try UploadCoordinator(store: worker.store, library: worker.library, transfer: transfers, notifications: worker.notifications, api: api, sessions: worker.sessions, now: { self.time })
        _ = await restored.process(); XCTAssertEqual(api.creates, 1)
        api.reconciled = Publication(contractAddress: destination.address, tokenId: "7", hash: nil, chainId: 8453)
        _ = await restored.process()
        XCTAssertEqual(try worker.store.read().records.first?.status, .published)
        XCTAssertEqual(api.creates, 1)
    }
    func testExpiryNotifiesOnceAcrossRestartsAndResumesAfterReconciliation() async throws {
        let (worker, library, transfers, notifications, sessions, api) = try make()
        _ = await worker.scan()
        time = time.addingTimeInterval(3601)
        _ = await worker.process(); _ = await worker.process()
        let restored = try UploadCoordinator(store: worker.store, library: library, transfer: transfers, notifications: notifications, api: api, sessions: sessions, now: { self.time })
        _ = await restored.process()
        XCTAssertEqual(notifications.messages.count, 1)
        XCTAssertTrue(transfers.submitted.isEmpty)
        library.items = []
        let renewed = SavedSession(token: "renewed-test", email: "test@example.invalid", expiresAt: time.addingTimeInterval(3600))
        await restored.resumeSession(renewed, owner: owner)
        _ = await restored.process()
        XCTAssertEqual(try worker.store.read().records.first?.status, .canceled)
        XCTAssertEqual(api.creates, 0)
    }
    func testPermissionAndAlbumLossPreservePendingAndDeduplicateNotices() async throws {
        let (worker, library, _, notifications, _, _) = try make()
        _ = await worker.scan(); library.granted = false
        _ = await worker.scan(); _ = await worker.scan()
        XCTAssertEqual(try worker.store.read().records.first?.status, .pending)
        XCTAssertEqual(notifications.messages.count, 1)
        library.granted = true; library.missing = true
        _ = await worker.scan(); _ = await worker.scan()
        XCTAssertEqual(notifications.messages.count, 2)
        XCTAssertEqual(try worker.store.read().records.first?.status, .pending)
    }
    func testPausedAndCellularPoliciesPreventTransfers() async throws {
        let (worker, _, transfers, _, _, api) = try make()
        await worker.setPaused(true); _ = await worker.process()
        XCTAssertTrue(transfers.submitted.isEmpty)
        await worker.setPaused(false)
        worker.setCellular(false); worker.expensive = true
        _ = await worker.process()
        XCTAssertEqual(worker.heading, "Waiting for Wi-Fi")
        XCTAssertTrue(transfers.submitted.isEmpty)
        worker.online = false; worker.expensive = false; _ = await worker.process()
        XCTAssertTrue(transfers.submitted.isEmpty)
        worker.online = true; _ = await worker.process()
        XCTAssertEqual(transfers.submitted.count, 1); XCTAssertEqual(api.creates, 0)
    }
    func testWrongAccountCannotTransferAndCannotReassignQueue() async throws {
        let (worker, _, transfers, notifications, sessions, api) = try make()
        api.owner = "0x3333333333333333333333333333333333333333"
        _ = await worker.process(); _ = await worker.process()
        XCTAssertTrue(transfers.submitted.isEmpty)
        XCTAssertEqual(notifications.messages.count, 1)
        await worker.resumeSession(try XCTUnwrap(sessions.value), owner: api.owner)
        XCTAssertNotNil(worker.error)
        XCTAssertEqual(try worker.store.read().configuration?.owner, owner)
    }
    func testMetadataFailureReusesTransferAndRetriesWithBackoff() async throws {
        let (worker, _, transfers, _, _, api) = try make()
        _ = await worker.process()
        let record = try XCTUnwrap(worker.store.read().records.first)
        transfers.completed = [TransferEvent(jobID: "job", operation: record.id, succeeded: true, message: nil)]
        api.failMetadataOnce = true
        _ = await worker.process(); _ = await worker.process()
        XCTAssertEqual(api.uploads, 1); XCTAssertEqual(api.creates, 0)
        time = time.addingTimeInterval(61)
        _ = await worker.process()
        XCTAssertEqual(api.uploads, 2); XCTAssertEqual(api.creates, 1)
        XCTAssertEqual(transfers.submitted.count, 1)
    }
    func testAcknowledgmentInterruptionDoesNotLoseTerminalResultOrCountFailureTwice() async throws {
        let (worker, _, transfers, _, _, _) = try make()
        _ = await worker.process()
        let record = try XCTUnwrap(worker.store.read().records.first)
        transfers.completed = [TransferEvent(jobID: "failed-job", operation: record.id, succeeded: false, message: "Offline")]
        transfers.failAcknowledgment = true
        _ = await worker.process(); _ = await worker.process()
        XCTAssertEqual(try worker.store.read().records.first?.attempts, 1)
        XCTAssertEqual(try worker.store.read().records.first?.status, .failed)
        transfers.failAcknowledgment = false; _ = await worker.process()
        XCTAssertEqual(transfers.acknowledged, ["failed-job"])
    }
    func testManualPublicationSharesLedgerAndPreventsLaterAlbumCreate() async throws {
        let (worker, _, transfers, _, sessions, api) = try make()
        let drafts = try DraftStore(directory: worker.store.directory.appendingPathComponent("manual"))
        let model = AppModel(api: api, sessions: sessions, drafts: drafts, uploadStore: worker.store)
        model.identity = Identity(artistAddress: owner, profile: .init(username: "Test")); model.destination = destination
        model.session = SavedSession(token: "test-only", email: "test@example.invalid", expiresAt: Date().addingTimeInterval(3600))
        model.draft = Draft(owner: owner, destination: destination)
        let data = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 10)).pngData { $0.fill(CGRect(x: 0, y: 0, width: 20, height: 10)) }
        try model.acceptPhoto(data, sourceAssetID: "fixture-current-edited-photo")
        _ = await worker.scan() // Manual takes ownership of a pending, not started item.
        await model.publish()
        XCTAssertEqual(model.draft?.stage, .published)
        model.startAnother()
        _ = await worker.process()
        XCTAssertTrue(transfers.submitted.isEmpty); XCTAssertEqual(api.creates, 1)
        XCTAssertEqual(try worker.store.read().records.filter { $0.status == .published }.count, 1)
    }
    func testCrossProcessLeaseExcludesAnotherWorkerAndDiskFailuresFailClosed() async throws {
        let (worker, _, transfers, _, _, api) = try make()
        let lease = try XCTUnwrap(worker.store.lease())
        _ = await worker.process()
        XCTAssertTrue(transfers.submitted.isEmpty); XCTAssertEqual(api.creates, 0)
        withExtendedLifetime(lease) {}
        try Data("corrupt".utf8).write(to: worker.store.directory.appendingPathComponent("queue.json"))
        XCTAssertThrowsError(try worker.store.read())
        _ = await worker.process(); XCTAssertEqual(api.creates, 0)
    }
    func testDeviceVerifiedStorageExceptionIsNarrowAndKeepsRequestConstraints() throws {
        let base = URL(string: "https://zzgteesackezack.invalid")! // Never used for network.
        var draft = Draft(owner: owner, destination: destination)
        func accepts(_ request: URLRequest, status: Int = 200, limit: String? = nil, responseURL: URL? = nil) -> Bool {
            var headers: [String: String] = [:]
            if let limit { headers["Upload-Limit"] = limit }
            let response = HTTPURLResponse(url: responseURL ?? request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return PhotoKitTransfer.acceptsEndpointPreflight(upload: request, response: response)
        }
        let supported = URL(string: "https://zzgteesackezhtnuqfyw.supabase.co")!
        for (mime, ext) in [("image/jpeg", "jpg"), ("image/png", "png"), ("image/heic", "heic")] {
            draft.mediaMIME = mime; draft.mediaExtension = ext
            let request = PhotoKitTransfer.makeRequest(base: supported, bucket: "in_process_files", key: "public-fixture", draft: draft, cellular: false)
            XCTAssertTrue(accepts(request))
            XCTAssertTrue(accepts(request, status: 501))
            XCTAssertTrue(accepts(request, limit: "100000"))
            for status in [201, 301, 400, 401, 403, 404, 429, 500] { XCTAssertFalse(accepts(request, status: status)) }
            XCTAssertFalse(accepts(request, limit: "invalid"))
            XCTAssertFalse(accepts(request, limit: "0"))
            XCTAssertFalse(accepts(request, responseURL: base))
            for (field, value) in [("Content-Type", "video/mp4"), ("Authorization", "Bearer wrong"), ("apikey", ""), ("x-upsert", "true")] {
                var changed = request; changed.setValue(value, forHTTPHeaderField: field)
                XCTAssertFalse(accepts(changed), field)
            }
            var changed = request; changed.httpMethod = "PUT"
            XCTAssertFalse(accepts(changed))
            for raw in ["http://zzgteesackezhtnuqfyw.supabase.co", "https://zzgteesackezhtnuqfyw.supabase.co:444", "https://zzgteesackezhtnuqfyw.supabase.co.evil.invalid", "https://other.supabase.co"] {
                XCTAssertFalse(accepts(PhotoKitTransfer.makeRequest(base: URL(string: raw)!, bucket: "in_process_files", key: "public-fixture", draft: draft, cellular: false)))
            }
            XCTAssertFalse(accepts(PhotoKitTransfer.makeRequest(base: supported, bucket: "other", key: "public-fixture", draft: draft, cellular: false)))
            changed = request; changed.url = URL(string: request.url!.absoluteString + "?redirect=other")!
            XCTAssertFalse(accepts(changed))
            changed = request; changed.url = supported.appendingPathComponent("storage/v1/object/in_process_files/arbitrary.png")
            XCTAssertFalse(accepts(changed))
        }
    }

    func testEndpointGateAndDeniedPermissionCannotEnableSetup() async throws {
        let (worker, library, transfers, notices, sessions, _) = try make()
        try worker.store.update { $0.configuration = nil }
        transfers.compatible = false
        await worker.configure(owner: owner, destination: destination, albumID: nil, session: try XCTUnwrap(sessions.value))
        XCTAssertNil(try worker.store.read().configuration); XCTAssertFalse(transfers.enabled); XCTAssertFalse(notices.requested)
        transfers.compatible = true; library.granted = false
        await worker.configure(owner: owner, destination: destination, albumID: nil, session: try XCTUnwrap(sessions.value))
        XCTAssertNil(try worker.store.read().configuration)
        XCTAssertFalse(PhotoKitTransfer.acceptsPreflight(status: 200, uploadLimit: nil))
        XCTAssertTrue(PhotoKitTransfer.acceptsPreflight(status: 501, uploadLimit: nil))
    }
    func testPreservesPNGAndHEICDimensionsMetadataAndBytes() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40), format: format).image { UIColor.red.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 80, height: 40)) }
        for type in [UTType.png, UTType.heic] {
            let output = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(rendered.cgImage), [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "synthetic-marker"], kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 0.0]] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let prepared = try PhotoProcessor.inspect(output as Data)
            XCTAssertEqual(prepared.data, output as Data)
            XCTAssertEqual(prepared.mime, type == .heic ? "image/heic" : "image/png")
            XCTAssertTrue(prepared.alterations.isEmpty)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(prepared.data as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            XCTAssertNotNil(properties[kCGImagePropertyExifDictionary as String])
            let inputSource = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
            let inputProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(inputSource, 0, nil) as? [String: Any])
            XCTAssertEqual(properties[kCGImagePropertyGPSDictionary as String] as? NSDictionary, inputProperties[kCGImagePropertyGPSDictionary as String] as? NSDictionary)
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, 80)
            XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, 40)
        }
    }
    func testConversionRequiresVerifiedReasonAndRetainsDimensions() throws {
        let input = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 50)).jpegData(withCompressionQuality: 1) { $0.fill(CGRect(x: 0, y: 0, width: 100, height: 50)) }
        XCTAssertThrowsError(try PhotoProcessor.convertToPNG(input, verifiedReason: ""))
        let converted = try PhotoProcessor.convertToPNG(input, verifiedReason: "a verified test destination constraint")
        XCTAssertEqual(converted.mime, "image/png")
        let convertedSource = try XCTUnwrap(CGImageSourceCreateWithData(converted.data as CFData, nil))
        let inputSource = try XCTUnwrap(CGImageSourceCreateWithData(input as CFData, nil))
        let outputProperties = CGImageSourceCopyPropertiesAtIndex(convertedSource, 0, nil) as? [String: Any]
        let inputProperties = CGImageSourceCopyPropertiesAtIndex(inputSource, 0, nil) as? [String: Any]
        XCTAssertEqual(outputProperties?[kCGImagePropertyPixelWidth as String] as? Int, inputProperties?[kCGImagePropertyPixelWidth as String] as? Int)
        XCTAssertNotEqual(converted.data, input)
    }
    func testCurrentEditedResourceSelectionNeverFallsBackToOriginal() throws {
        XCTAssertEqual(try PhotosAlbumAccess.resourceIndex(types: [.photo, .pairedVideo]), 0)
        XCTAssertEqual(try PhotosAlbumAccess.resourceIndex(types: [.photo, .adjustmentData, .fullSizePhoto, .fullSizePairedVideo]), 2)
        XCTAssertThrowsError(try PhotosAlbumAccess.resourceIndex(types: [.photo, .adjustmentData]))
        XCTAssertThrowsError(try PhotosAlbumAccess.resourceIndex(types: [.video]))
    }

    func testSignOutBlocksEvenWithRetainedTokenAndReauthenticationKeepsUserPause() async throws {
        let (worker, _, transfers, _, sessions, _) = try make()
        await worker.setPaused(true)
        let saved = try XCTUnwrap(sessions.value)
        worker.signOut()
        sessions.value = saved // Model a credential that could not be removed.
        _ = await worker.process()
        XCTAssertTrue(transfers.submitted.isEmpty)
        XCTAssertEqual(try worker.store.read().configuration?.signedOut, true)
        await worker.resumeSession(saved, owner: owner)
        XCTAssertEqual(try worker.store.read().configuration?.paused, true)
        XCTAssertEqual(try worker.store.read().configuration?.signedOut, false)
    }
    func testStorageRequestUsesOriginalMIMEStablePathAndCellularPolicy() throws {
        var draft = Draft(owner: owner, destination: destination)
        draft.mediaMIME = "image/heic"; draft.mediaExtension = "heic"
        let request = PhotoKitTransfer.makeRequest(base: URL(string: "https://fixture.example.invalid")!, bucket: "test", key: "public-test-only", draft: draft, cellular: false)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.lastPathComponent, draft.mediaObject)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "image/heic")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer public-test-only")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-upsert"), "false")
        XCTAssertNil(request.httpBody)
        XCTAssertFalse(request.allowsCellularAccess); XCTAssertFalse(request.allowsExpensiveNetworkAccess)
        XCTAssertFalse(PhotoKitTransfer.acceptsPreflight(status: 200, uploadLimit: "invalid"))
    }
    func testAlterationExplainedAndNotifiedOnceWithoutPublishConfirmation() async throws {
        let (worker, _, _, notices, sessions, api) = try make()
        let model = AppModel(api: api, sessions: sessions, drafts: try DraftStore(directory: worker.store.directory.appendingPathComponent("manual")), automatic: worker)
        model.identity = Identity(artistAddress: owner, profile: .init(username: "Test"))
        model.draft = Draft(owner: owner, destination: destination)
        let data = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 10)).pngData { $0.fill(CGRect(x: 0, y: 0, width: 20, height: 10)) }
        var prepared = try PhotoProcessor.inspect(data)
        prepared.alterations = ["Synthetic test: embedded metadata could not be retained."]
        let notified = expectation(description: "The alteration is reported through the injected notifier")
        notices.didNotify = { notified.fulfill() }
        try model.acceptPhoto(prepared)
        try model.acceptPhoto(prepared)
        await fulfillment(of: [notified], timeout: 2)
        XCTAssertEqual(model.draft?.alterations, prepared.alterations)
        XCTAssertEqual(notices.messages.count, 1)
        XCTAssertEqual(model.draft?.stage, .draft)
    }
    func testCanceledOperationIgnoresLateTransferSuccess() async throws {
        let (worker, library, transfers, _, _, api) = try make()
        _ = await worker.process()
        var record = try XCTUnwrap(worker.store.read().records.first)
        record.status = .canceled; try worker.store.save(record)
        library.items = []
        transfers.completed = [TransferEvent(jobID: "late", operation: record.id, succeeded: true, message: nil)]
        _ = await worker.process()
        XCTAssertEqual(try worker.store.read().records.first?.status, .canceled)
        XCTAssertEqual(api.creates, 0)
    }

    func testPhysicalDiagnosticFailsClosedInSimulatorBeforePhotosOrNetwork() async {
        do { _ = try await PhotoDiagnostic.prepare(); XCTFail("A simulator test must not create a Photos asset") }
        catch { XCTAssertTrue(error.localizedDescription.contains("physical iPhone")) }
        do { try await PhotoDiagnostic.start(); XCTFail("A simulator test must not reach storage") }
        catch { XCTAssertTrue(error.localizedDescription.contains("physical iPhone")) }
        do { try await PhotoDiagnostic.prepareScenario("Host backgrounded"); XCTFail("A simulator test must not read real Photos") }
        catch { XCTAssertTrue(error.localizedDescription.contains("physical iPhone")) }
    }


    func testRemovingFromAlbumAllowsOnlyPendingAndFailedAndReAddStartsFresh() async throws {
        let (worker, library, _, _, _, _) = try make()
        library.items = ["waiting", "failed", "uploading", "uncertain", "published"].map { LibraryPhoto(id: $0, revision: "v1", mime: "image/jpeg", fileExtension: "jpg") }
        let scanned = await worker.scan()
        XCTAssertTrue(scanned)
        try worker.store.update { state in
            for i in state.records.indices {
                switch state.records[i].draft.sourceAssetID {
                case "failed": state.records[i].status = .failed; state.records[i].attempts = 3; state.records[i].draft.stage = .uploadingPhoto
                case "uploading": state.records[i].status = .uploading
                case "uncertain": state.records[i].status = .uncertain
                case "published": state.records[i].status = .published
                default: break
                }
            }
        }
        worker.refresh()
        XCTAssertEqual(library.items.map(\.id).filter(worker.removable), ["waiting", "failed"])
        await worker.removeFromAlbum(library.items.map(\.id))
        // Only the waiting and failed photos left the album; nothing that is or may be public was touched.
        XCTAssertEqual(library.items.map(\.id), ["uploading", "uncertain", "published"])
        let records = try worker.store.read().records
        XCTAssertEqual(records.first { $0.draft.sourceAssetID == "waiting" }?.status, .canceled)
        XCTAssertEqual(records.first { $0.draft.sourceAssetID == "failed" }?.status, .canceled)
        XCTAssertEqual(records.first { $0.draft.sourceAssetID == "published" }?.status, .published)
        XCTAssertEqual(records.first { $0.draft.sourceAssetID == "uncertain" }?.status, .uncertain)
        // Adding the failed photo back queues a new upload instead of reviving the failed one.
        await worker.addToAlbum(["failed"])
        let again = try worker.store.read().records.filter { $0.draft.sourceAssetID == "failed" }
        XCTAssertEqual(again.map(\.status), [.canceled, .pending])
        XCTAssertEqual(worker.record(for: "failed")?.status, .pending)
    }

    func testAutomaticUploadingOffQueuesOnlyApprovedPhotos() async throws {
        let (worker, library, _, _, _, _) = try make()
        try worker.store.update { $0.configuration?.autoUpload = false }
        library.items = ["a", "b", "c"].map { LibraryPhoto(id: $0, revision: "v1", mime: "image/jpeg", fileExtension: "jpg") }
        let scanned = await worker.scan()
        XCTAssertTrue(scanned)
        // The album is read, but nothing is queued without approval.
        XCTAssertEqual(worker.albumPhotos.map(\.id), ["a", "b", "c"])
        XCTAssertTrue(try worker.store.read().records.isEmpty)
        await worker.approve(["b"])
        XCTAssertEqual(try worker.store.read().records.map(\.draft.sourceAssetID), ["b"])
        // A later scan does not sweep in the unapproved ones, or queue the approved one twice.
        await worker.scan()
        XCTAssertEqual(try worker.store.read().records.map(\.draft.sourceAssetID), ["b"])
        // Turning automatic uploading on queues everything still waiting.
        await worker.setAutoUpload(true)
        XCTAssertEqual(Set(try worker.store.read().records.compactMap(\.draft.sourceAssetID)), ["a", "b", "c"])
        // A configuration saved before this setting existed uploads automatically.
        let legacy = try JSONDecoder().decode(AutomaticConfiguration.self, from: Data(#"{"owner":"0x1","destination":{"address":"0x2","name":"Process","chain_id":8453},"albumID":"album","cellular":true,"paused":false}"#.utf8))
        XCTAssertTrue(legacy.uploadsAutomatically)
    }

    func testTurningAutomaticOffReturnsUnstartedUploadsToWaitingAndUnapproveTakesBackOne() async throws {
        let (worker, library, transfers, _, _, _) = try make()
        library.items = ["a", "b", "started", "done"].map { LibraryPhoto(id: $0, revision: "v1", mime: "image/jpeg", fileExtension: "jpg") }
        await worker.scan()
        try worker.store.update { state in
            for i in state.records.indices {
                switch state.records[i].draft.sourceAssetID {
                case "started": state.records[i].status = .uploading; state.records[i].draft.stage = .uploadingPhoto
                case "done": state.records[i].status = .published; state.records[i].draft.stage = .published
                default: break
                }
            }
        }
        // Off is the pause: queued photos that have not started go back to waiting; anything started or done is untouched.
        await worker.setAutoUpload(false)
        XCTAssertNil(worker.record(for: "a")); XCTAssertNil(worker.record(for: "b"))
        XCTAssertEqual(worker.record(for: "started")?.status, .uploading)
        XCTAssertEqual(worker.record(for: "done")?.status, .published)
        XCTAssertEqual(worker.albumPhotos.count, 4, "Returned photos stay in the album")
        XCTAssertTrue(transfers.submitted.isEmpty)
        // An approval queues one photo and can be taken back before it starts.
        await worker.approve(["a"])
        XCTAssertEqual(worker.record(for: "a")?.status, .pending)
        XCTAssertTrue(worker.unapprovable("a")); XCTAssertFalse(worker.unapprovable("b")); XCTAssertFalse(worker.unapprovable("started"))
        await worker.unapprove(["a", "started"])
        XCTAssertNil(worker.record(for: "a"))
        XCTAssertEqual(worker.record(for: "started")?.status, .uploading)
        // On is the resume: everything waiting is queued, and un-approve no longer applies.
        await worker.setAutoUpload(true)
        XCTAssertEqual(worker.record(for: "a")?.status, .pending); XCTAssertEqual(worker.record(for: "b")?.status, .pending)
        XCTAssertFalse(worker.unapprovable("a"))
        await worker.unapprove(["a"])
        XCTAssertEqual(worker.record(for: "a")?.status, .pending)
    }

    func testForegroundUploadsPublishQueuedPhotosWithoutThePhotosExtension() async throws {
        let (worker, library, transfers, _, _, api) = try make()
        library.items = ["a", "b"].map { LibraryPhoto(id: $0, revision: "v1", mime: "image/jpeg", fileExtension: "jpg") }
        await worker.scan()
        // Nothing happens until the app is in front.
        await worker.drainInForeground()
        XCTAssertEqual(api.creates, 0)
        worker.setForeground(true)
        await worker.finishForegroundUploads()
        XCTAssertEqual(worker.record(for: "a")?.status, .published); XCTAssertEqual(worker.record(for: "b")?.status, .published)
        XCTAssertEqual(api.creates, 2, "One create per photo")
        XCTAssertEqual(api.uploads, 4, "Photo and metadata for each")
        XCTAssertTrue(transfers.submitted.isEmpty, "No Photos job is registered for a photo the app uploads itself")
        XCTAssertEqual(worker.record(for: "a")?.viaApp, true)
        // A later pass, by either path, publishes nothing again.
        await worker.drainInForeground(); _ = await worker.process()
        XCTAssertEqual(api.creates, 2)
    }
    func testForegroundUploadsLeavePhotosJobsAloneAndResumeTheirOwn() async throws {
        let (worker, library, transfers, _, _, api) = try make()
        library.items = ["photos-job", "app-started"].map { LibraryPhoto(id: $0, revision: "v1", mime: "image/jpeg", fileExtension: "jpg") }
        await worker.scan()
        try worker.store.update { state in
            for i in state.records.indices {
                state.records[i].status = .uploading; state.records[i].draft.stage = .uploadingPhoto
                if state.records[i].draft.sourceAssetID == "app-started" { state.records[i].viaApp = true }
            }
        }
        worker.setForeground(true)
        await worker.finishForegroundUploads()
        // The transfer Photos may hold is untouched; the one the app began earlier is finished.
        XCTAssertEqual(worker.record(for: "photos-job")?.status, .uploading)
        XCTAssertNil(worker.record(for: "photos-job")?.draft.mediaURI)
        XCTAssertEqual(worker.record(for: "app-started")?.status, .published)
        XCTAssertEqual(api.creates, 1)
        XCTAssertTrue(transfers.submitted.isEmpty)
    }
    func testLeavingTheAppFinishesThePhotoInFlightAndStartsNoOther() async throws {
        let (worker, library, _, _, _, api) = try make()
        library.items = ["first", "second"].map { LibraryPhoto(id: $0, revision: "v1", mime: "image/jpeg", fileExtension: "jpg") }
        await worker.scan()
        // The app goes to the background while the first photo is being read.
        library.didReadData = { worker.setForeground(false) }
        worker.setForeground(true)
        await worker.finishForegroundUploads()
        XCTAssertEqual(api.creates, 1)
        XCTAssertEqual(try worker.store.read().records.filter { $0.status == .published }.count, 1)
        XCTAssertEqual(try worker.store.read().records.filter { $0.status == .pending && $0.draft.stage == .draft }.count, 1, "The other stays queued for the extension")
        // The shared publication lock is free again, so the extension is not shut out.
        XCTAssertNotNil(try worker.store.lease())
    }
    func testForegroundFailureSetsThePhotoAsideAndContinuesWithTheNext() async throws {
        let (worker, library, _, _, _, api) = try make()
        library.items = ["bad", "good"].map { LibraryPhoto(id: $0, revision: "v1", mime: "image/jpeg", fileExtension: "jpg") }
        await worker.scan()
        var reads = 0
        library.didReadData = { reads += 1; library.failData = reads == 1 }
        worker.setForeground(true)
        await worker.finishForegroundUploads()
        let records = try worker.store.read().records
        XCTAssertEqual(records.filter { $0.status == .failed }.count, 1)
        XCTAssertEqual(records.filter { $0.status == .published }.count, 1)
        XCTAssertEqual(api.creates, 1)
    }
    func testApprovalStartsUploadingAtOnceWhileTheAppIsOpenAndRespectsPause() async throws {
        let (worker, library, _, _, _, api) = try make()
        try worker.store.update { $0.configuration?.autoUpload = false }
        library.items = ["a", "b"].map { LibraryPhoto(id: $0, revision: "v1", mime: "image/jpeg", fileExtension: "jpg") }
        worker.setForeground(true)
        await worker.finishForegroundUploads()
        XCTAssertEqual(api.creates, 0, "Nothing unapproved is uploaded")
        await worker.approve(["a"])
        await worker.finishForegroundUploads()
        XCTAssertEqual(worker.record(for: "a")?.status, .published)
        XCTAssertNil(worker.record(for: "b"))
        XCTAssertEqual(api.creates, 1)
        // A problem pause holds approved photos in the foreground too.
        try worker.store.update { $0.configuration?.paused = true }
        await worker.approve(["b"])
        await worker.finishForegroundUploads()
        XCTAssertEqual(worker.record(for: "b")?.status, .pending)
        XCTAssertEqual(api.creates, 1)
    }
}
