import Foundation
import Observation

@MainActor @Observable
final class UploadCoordinator {
    let log: DevelopmentLog
    let store: UploadStore
    let library: any AlbumAccess
    let transfer: any ResourceTransferring
    let notifications: any UploadNotifying
    private var tracedAPI: ObservedService { ObservedService(base: api, log: log) }
    let api: any InProcessServing
    let sessions: any SessionStoring
    let now: () -> Date
    var state = UploadState()
    var online = true
    var expensive = false
    var busy = false
    var preparingSetup = false
    var error: String?
    var choices: [AlbumChoice] = []
    /// The connected album's stills as of the last successful scan, in album order.
    var albumPhotos: [LibraryPhoto] = []
    /// Whether the app may upload queued photos itself while it is open. Off in fixtures that need a still queue.
    var foregroundUploads = true
    /// True only while the host app is frontmost. The extension never sets it.
    private(set) var foregroundActive = false
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    var photosAccess: PhotosAccessStatus = .unknown
    var notificationAccess: NotificationAccessStatus?
    var connectedAlbumName = "Checking…"
    var extensionEnabled = false
    var sessionStatus = "Checking…"
    var automaticStatus: String {
        guard let configuration = state.configuration else { return "Not configured" }
        if configuration.paused { return "Paused" }
        if configuration.signedOut == true { return "Sign in needed" }
        return extensionEnabled ? "Enabled" : "Disabled"
    }
    var configured: Bool { state.configuration != nil }
    /// True only for the real transfer adapter running in the Simulator, where Photos cannot run background
    /// uploads. Setup and the controls still work there so the screens can be exercised; nothing is uploaded.
    var backgroundTransfersUnavailable: Bool {
        #if targetEnvironment(simulator)
        return transfer is PhotoKitTransfer
        #else
        return false
        #endif
    }
    private func enableTransfers(cellular: Bool) throws {
        if backgroundTransfersUnavailable { log.emit(.extensionEnable, .photokit, [.available: .flag(false), .reason: .tag(.simulator)]); return }
        try transfer.enable(cellular: cellular)
    }
    private var diagnosticState: [LogField: LogValue] {
        [.failed: .flag(error != nil || state.lastWorkerError != nil || state.blocker != nil),
         .configured: .flag(configured), .paused: .flag(state.configuration?.paused ?? false),
         .cellular: .flag(state.configuration?.cellular ?? false), .enabled: .flag(extensionEnabled),
         .pending: .number(state.records.filter { $0.status == .pending }.count),
         .uploading: .number(state.records.filter { $0.status == .uploading }.count)]
    }
    var heading: String {
        if !configured { return "Not configured" }
        if error != nil || state.blocker != nil || state.lastWorkerError != nil || state.records.contains(where: { $0.draft.owner.lowercased() == state.configuration?.owner.lowercased() && ($0.status == .failed || $0.status == .uncertain) }) { return "Needs attention" }
        if state.configuration?.paused == true { return "Uploads paused" }
        if !online { return "Waiting for connection" }
        if state.configuration?.cellular == false && expensive { return "Waiting for Wi-Fi" }
        if !extensionEnabled && !backgroundTransfersUnavailable { return "Automatic uploads disabled" }
        return "Active"
    }
    init(store: UploadStore, library: any AlbumAccess, transfer: any ResourceTransferring,
         notifications: any UploadNotifying, api: any InProcessServing, sessions: any SessionStoring,
         now: @escaping () -> Date = Date.init, log: DevelopmentLog = .shared) throws {
        self.log = log
        self.store = store; self.library = library; self.transfer = transfer
        self.notifications = notifications; self.api = api; self.sessions = sessions; self.now = now
        state = try store.read()
        log.emit(.configuration, .setup, [.configured: .flag(state.configuration != nil), .count: .number(state.records.count)])
    }
    func refresh() {
        do { state = try store.read() } catch { log.emit(.configuration, .setup, DevelopmentLog.safeError(error), level: .error); self.error = error.localizedDescription }
        photosAccess = library.authorizationStatus
        extensionEnabled = transfer.isEnabled
        if let configuration = state.configuration {
            do { connectedAlbumName = try library.albumName(for: configuration.albumID) }
            catch LibraryProblem.permission { connectedAlbumName = "Full Photos access needed" }
            catch LibraryProblem.missingAlbum { connectedAlbumName = "Album unavailable" }
            catch { connectedAlbumName = "Couldn’t read album" }
        } else { connectedAlbumName = "Not connected" }
        do {
            let session = try sessions.load()
            sessionStatus = state.configuration?.signedOut != true && session.map({ $0.isValid(at: now()) }) == true ? "Valid" : "Sign in needed"
        } catch { sessionStatus = "Couldn’t read session" }
    }
    /// Observes configuration only: no permission prompt, album scan, or job creation.
    func refreshConfiguration() async {
        return await log.action(.statusRefresh, .app, outcome: { self.diagnosticState }) {
            refresh()
            notificationAccess = await notifications.authorizationStatus()
        }
    }
    @discardableResult
    func prepareSetup() async -> Bool {
        return await log.action(.setup, .setup, outcome: { self.diagnosticState }) {
            guard !preparingSetup, !busy else { return false }
            preparingSetup = true; error = nil; choices = []
            defer { preparingSetup = false; photosAccess = library.authorizationStatus }
            log.emit(.permission, .setup, [.status: .tag(LogTag(rawValue: String(describing: library.authorizationStatus)) ?? .unknown), .prompt: .flag(library.authorizationStatus == .notRequested)])
            if library.authorizationStatus == .notRequested { _ = await library.requestAccess() }
            guard library.authorizationStatus == .full else {
                switch library.authorizationStatus {
                case .limited:
                    error = "Limited Photos access cannot read albums. Choose Full Access in Settings, then try again. Manual upload is still available."
                case .restricted:
                    error = "Photos access is restricted on this iPhone. Manual upload is still available."
                default:
                    error = "Full Photos access is required to publish from an album. Allow Full Access in Settings, then try again. Manual upload is still available."
                }
                return false
            }
            do { choices = try log.trace(.albumList, .library) { try library.albums() }; log.emit(.albumList, .library, [.count: .number(choices.count)]); return true }
            catch {
                self.error = "Couldn’t read your Photos albums. Try again. \(error.localizedDescription)"
                return false
            }
        }
    }
    func configure(owner: String, destination: Destination, albumID: String?, session: SavedSession, autoUpload: Bool = true) async {
        return await log.action(.albumConnect, .setup, fields: [.existing: .flag(albumID != nil)], outcome: { self.diagnosticState }) {
            guard !busy else { return }; busy = true; error = nil
            defer { busy = false; refresh() }
            do {
                guard session.isValid(at: now()) else { throw AppError.sessionExpired }
                guard await library.requestAccess() else { throw AppError.message("Full Photos access is required.") }
                if let old = try store.read().configuration, old.owner.lowercased() != owner.lowercased() {
                    throw AppError.message("Sign in with the account that configured automatic uploads.")
                }
                // Resolve endpoint and secure-sharing failures before creating any album.
                try await log.trace(.endpointCheck, .setup) { try await transfer.validateEndpoint() }
                try log.trace(.secureSave, .auth, [.shared: .flag(true)]) { try sessions.save(session) }
                let album: String
                if let albumID { album = albumID } else { album = try await log.trace(.albumCreate, .library) { try await library.createAlbum() } }
                log.emit(.albumSelection, .setup, [.album: .correlated(album), .existing: .flag(albumID != nil)])
                _ = try await library.photos(in: album)
                try store.update { $0.configuration = AutomaticConfiguration(owner: owner, destination: destination, albumID: album, autoUpload: autoUpload); $0.blocker = nil }
                log.emit(.configuration, .setup, [.configured: .flag(true)])
                do { try log.trace(.extensionEnable, .photokit, [.cellular: .flag(true)]) { try enableTransfers(cellular: true) } }
                catch {
                    try store.update { $0.configuration?.paused = true; $0.blocker = "Automatic uploads could not be enabled. \(error.localizedDescription)" }
                    throw error
                }
                await notifications.requestPermission()
                await refreshConfiguration()
                await scan()
            } catch { log.emit(.configuration, .setup, DevelopmentLog.safeError(error), level: .error); self.error = error.localizedDescription }
        }
    }
    func setPaused(_ paused: Bool) async {
        return await log.action(.pause, .setup, fields: [.paused: .flag(paused)], outcome: { self.diagnosticState }) {
            do {
                try store.update { $0.configuration?.paused = paused }
                if paused { try transfer.disable() }
                else {
                    guard let c = try store.read().configuration else { return }
                    try await log.trace(.endpointCheck, .setup) { try await transfer.validateEndpoint() }; try log.trace(.extensionEnable, .photokit, [.cellular: .flag(c.cellular)]) { try enableTransfers(cellular: c.cellular) }
                    await scan()
                }
            } catch {
                self.error = error.localizedDescription
                try? store.update { $0.configuration?.paused = true; $0.blocker = "Uploads could not resume. \(error.localizedDescription)" }
            }
            refresh()
        }
    }
    func setCellular(_ allowed: Bool) {
        return log.action(.cellular, .setup, fields: [.cellular: .flag(allowed)], outcome: { self.diagnosticState }) {
            do {
                // Persist the restrictive policy before touching the system; worker rechecks it.
                try store.update { $0.configuration?.cellular = allowed }
                if try store.read().configuration?.paused == false { try enableTransfers(cellular: allowed) }
            } catch {
                self.error = error.localizedDescription
                try? store.update { $0.configuration?.paused = true; $0.blocker = "Could not apply the network setting. Uploads are paused." }
                try? transfer.disable()
            }
            refresh()
        }
    }
    func signOut() {
        return log.action(.signOut, .auth, outcome: { self.diagnosticState }) {
            do {
                // Only an account with a connected album has uploads to resume; otherwise leave no note behind.
                try store.update { if $0.configuration != nil { $0.configuration?.signedOut = true; $0.blocker = "Sign in to resume uploads." } }
                try sessions.clear(); try transfer.disable()
            } catch { log.emit(.configuration, .setup, DevelopmentLog.safeError(error), level: .error); self.error = error.localizedDescription }
            albumPhotos = []
            refresh()
        }
    }
    func resumeSession(_ session: SavedSession, owner: String) async {
        return await log.action(.sessionRecovery, .auth, outcome: { self.diagnosticState }) {
            do {
                guard let c = try store.read().configuration else {
                    // Nothing is connected, so no saved problem can apply. This also clears a note left by an older sign-out.
                    if try store.read().blocker != nil { try store.update { $0.blocker = nil } }
                    refresh(); return
                }
                guard c.owner.lowercased() == owner.lowercased() else {
                    throw AppError.message("These uploads belong to another account. Sign in with the account that configured them.")
                }
                try log.trace(.secureSave, .auth, [.shared: .flag(true)]) { try sessions.save(session) }
                try store.update { $0.configuration?.signedOut = false }
                if !c.paused { try await log.trace(.endpointCheck, .setup) { try await transfer.validateEndpoint() }; try log.trace(.extensionEnable, .photokit, [.cellular: .flag(c.cellular)]) { try enableTransfers(cellular: c.cellular) } }
                await scan()
            } catch { log.emit(.configuration, .setup, DevelopmentLog.safeError(error), level: .error); self.error = error.localizedDescription }
            refresh()
        }
    }
    private func block(_ key: String, _ message: String) async throws {
        let identifier = try store.update { state -> String? in
            state.blocker = message
            let id = (state.configuration?.owner.lowercased() ?? "") + ":" + key
            return state.incidents.insert(id).inserted ? id : nil
        }
        log.emit(.notification, .app, [.reason: .tag(identifier == nil ? .incidentDeduplicated : .notificationDelivered)])
        if let identifier { await notifications.notify(id: identifier, message: message) }
    }
    private func token() throws -> APICredential {
        guard try store.read().configuration?.signedOut != true, let session = try sessions.load(), session.isValid(at: now()) else {
            log.emit(.authGate, .auth, [.reason: .tag(.authUnavailable)], level: .error)
            throw AppError.sessionExpired
        }
        if let owner = session.owner, let configured = try store.read().configuration?.owner,
           owner.lowercased() != configured.lowercased() { throw CredentialSetupError.mismatch }
        return session.credential
    }
    /// Full album reconciliation is deliberate: correctness does not depend on a
    /// retained change token, and inaccessible albums must never become empty scans.
    /// With automatic uploading off, a photo new to the album is left alone until the user approves it;
    /// `approving` names the photos approved by this call.
    @discardableResult func scan(approving: Set<String> = []) async -> Bool {
        return await log.action(.scan, .library, outcome: { self.diagnosticState }) {
            defer { refresh() }
            do {
                guard let configuration = try store.read().configuration else { log.emit(.scan, .library, [.reason: .tag(.noConfiguration)]); return false }
                do { _ = try token() }
                catch { log.emit(.scan, .auth, DevelopmentLog.safeError(error), level: .error); try await block("auth", "Sign in to resume uploads. Pending photos are saved."); return false }
                let photos: [LibraryPhoto]
                do { photos = try await library.photos(in: configuration.albumID) }
                catch LibraryProblem.permission {
                    log.emit(.scan, .library, [.reason: .tag(.permissionDenied)], level: .error)
                    try await block("permission", "Photos access was removed. Allow Full Access in Settings to resume."); return false
                } catch LibraryProblem.missingAlbum {
                    log.emit(.scan, .library, [.reason: .tag(.missingAlbum)], level: .error)
                    try await block("album", "The connected album is missing. Reconnect an album to resume; pending photos are saved."); return false
                }
                log.emit(.scan, .library, [.eligible: .number(photos.count), .album: .correlated(configuration.albumID)])
                albumPhotos = photos
                let ids = Set(photos.map(\.id))
                var enqueued: [(UUID, String)] = []; var removed: [UUID] = []; var deduplicated = 0
                try store.update { state in
                    state.lastCheck = now(); state.blocker = nil
                    for key in ["auth", "permission", "album"] { state.incidents.remove(configuration.owner.lowercased() + ":" + key) }
                    for i in state.records.indices where state.records[i].automatic && state.records[i].draft.owner.lowercased() == configuration.owner.lowercased() {
                        if state.records[i].draft.stage == .draft, let id = state.records[i].draft.sourceAssetID, !ids.contains(id) {
                            removed.append(state.records[i].id); state.records[i].status = .canceled; state.records[i].reason = "Removed from the album before upload started."
                        }
                    }
                    for photo in photos {
                        guard !state.records.contains(where: { $0.draft.owner.lowercased() == configuration.owner.lowercased() && $0.draft.sourceAssetID == photo.id && $0.status != .canceled }) else { deduplicated += 1; continue }
                        guard configuration.uploadsAutomatically || approving.contains(photo.id) else { continue } // Waits for approval.
                        var draft = Draft(owner: configuration.owner, destination: configuration.destination)
                        draft.sourceAssetID = photo.id; draft.mediaMIME = photo.mime; draft.mediaExtension = photo.fileExtension
                        state.records.append(UploadRecord(draft: draft, automatic: true, revision: photo.revision))
                        enqueued.append((draft.id, photo.id))
                    }
                }
                for (id, asset) in enqueued { log.emit(.queueEnqueue, .queue, [.operation: .id(id), .asset: .correlated(asset), .status: .tag(.pending), .reason: .tag(.waitingForExtension)]) }
                for id in removed { log.emit(.queueRemove, .queue, [.operation: .id(id)]) }
                log.emit(.queueDeduplicate, .queue, [.count: .number(deduplicated), .enqueued: .number(enqueued.count), .removed: .number(removed.count)])
                return true
            } catch { log.emit(.scan, .library, DevelopmentLog.safeError(error), level: .error); self.error = error.localizedDescription; return false }
        }
    }
    /// Puts library photos into the connected album, then reconciles so they appear queued. Album membership is the consent to publish.
    func addToAlbum(_ assetIDs: [String]) async {
        return await log.action(.photoPicker, .library, fields: [.count: .number(assetIDs.count)], outcome: { self.diagnosticState }) {
            guard !assetIDs.isEmpty else { return }
            do {
                guard let configuration = try store.read().configuration else { return }
                try await library.add(assetIDs, to: configuration.albumID)
                await scan()
                startForegroundUploads()
            } catch {
                log.emit(.photoPicker, .library, DevelopmentLog.safeError(error), level: .error)
                self.error = "Couldn’t add to the In Process album. \(error.localizedDescription)"
            }
        }
    }
    /// Queues album photos the user has approved. Only meaningful while automatic uploading is off.
    func approve(_ assetIDs: [String]) async {
        guard !assetIDs.isEmpty else { return }
        await scan(approving: Set(assetIDs))
        startForegroundUploads() // An approval made in the app starts uploading now, not when Photos next wakes the extension.
    }
    /// The one upload switch. Turning it on queues everything waiting in the album. Turning it off sends queued
    /// photos whose upload has not started back to waiting for approval; an upload already under way continues.
    func setAutoUpload(_ automatic: Bool) async {
        return await log.action(.configuration, .setup, fields: [.automatic: .flag(automatic)], outcome: { self.diagnosticState }) {
            do {
                let returned = try store.update { state -> [UUID] in
                    state.configuration?.autoUpload = automatic
                    return automatic ? [] : Self.returnToWaiting(&state, assetIDs: nil)
                }
                await cancelTransfers(returned)
            } catch { log.emit(.configuration, .setup, DevelopmentLog.safeError(error), level: .error); self.error = error.localizedDescription }
            await scan()
            if automatic { startForegroundUploads() }
        }
    }
    /// Whether an approved photo can still be taken back: automatic uploading is off and its upload has not started.
    func unapprovable(_ assetID: String) -> Bool {
        guard state.configuration?.uploadsAutomatically == false, let record = record(for: assetID) else { return false }
        return record.status == .pending && record.draft.stage == .draft
    }
    /// Takes back approvals. Photos stay in the album and return to waiting.
    func unapprove(_ assetIDs: [String]) async {
        return await log.action(.queueRemove, .queue, fields: [.count: .number(assetIDs.count)], outcome: { self.diagnosticState }) {
            do {
                let returned = try store.update { state -> [UUID] in
                    guard state.configuration?.uploadsAutomatically == false else { return [] }
                    return Self.returnToWaiting(&state, assetIDs: Set(assetIDs))
                }
                await cancelTransfers(returned)
            } catch { log.emit(.queueRemove, .queue, DevelopmentLog.safeError(error), level: .error); self.error = error.localizedDescription }
            await scan()
        }
    }
    /// Cancels queued uploads that have not started, for the configured account. `nil` means every such photo.
    /// Only draft-stage records qualify, so nothing that has begun transferring or may have published is touched.
    private static func returnToWaiting(_ state: inout UploadState, assetIDs: Set<String>?) -> [UUID] {
        guard let owner = state.configuration?.owner.lowercased() else { return [] }
        var returned: [UUID] = []
        for i in state.records.indices where state.records[i].automatic && state.records[i].draft.owner.lowercased() == owner
            && state.records[i].status == .pending && state.records[i].draft.stage == .draft {
            if let assetIDs, !assetIDs.contains(state.records[i].draft.sourceAssetID ?? "") { continue }
            state.records[i].status = .canceled; state.records[i].reason = "Returned to waiting for approval."
            returned.append(state.records[i].id)
        }
        return returned
    }
    private func cancelTransfers(_ operations: [UUID]) async {
        for id in operations { try? await transfer.cancel(operation: id); log.emit(.queueRemove, .queue, [.operation: .id(id)]) }
    }
    /// Whether the home screen may take this photo out of the album: only while it is waiting, or after it failed.
    /// A failed record never reached a create request, so nothing was published. Uploading, uploaded and
    /// uncertain photos stay put; an uncertain one may already be public.
    func removable(_ assetID: String) -> Bool {
        record(for: assetID).map { $0.status == .pending || $0.status == .failed } ?? true
    }
    /// Takes pending or failed photos out of the connected album. Pending uploads are cancelled by the scan;
    /// a failed attempt is closed here so adding the photo back later starts a fresh upload.
    func removeFromAlbum(_ assetIDs: [String]) async {
        return await log.action(.photoRemove, .library, fields: [.count: .number(assetIDs.count)], outcome: { self.diagnosticState }) {
            do {
                guard let configuration = try store.read().configuration else { return }
                state = try store.read() // Judge each photo on the saved queue, not a stale copy.
                let assetIDs = assetIDs.filter(removable)
                guard !assetIDs.isEmpty else { return }
                let failed = assetIDs.compactMap { record(for: $0) }.filter { $0.status == .failed }.map(\.id)
                try await library.remove(assetIDs, from: configuration.albumID)
                if !failed.isEmpty {
                    try store.update { state in
                        for i in state.records.indices where failed.contains(state.records[i].id) && state.records[i].status == .failed {
                            state.records[i].status = .canceled; state.records[i].reason = "Removed from the album after the upload failed."
                        }
                    }
                    for id in failed { try? await transfer.cancel(operation: id); log.emit(.queueRemove, .queue, [.operation: .id(id)]) }
                }
                await scan()
            } catch {
                log.emit(.photoRemove, .library, DevelopmentLog.safeError(error), level: .error)
                self.error = "Couldn’t remove from the In Process album. \(error.localizedDescription)"
            }
        }
    }
    /// The live upload record for an album photo, if the scan has queued one.
    func record(for assetID: String) -> UploadRecord? {
        guard let owner = state.configuration?.owner.lowercased() else { return nil }
        return state.records.last { $0.automatic && $0.draft.owner.lowercased() == owner && $0.draft.sourceAssetID == assetID && $0.status != .canceled }
    }
    func retry(_ id: UUID) async {
        return await log.action(.retry, .queue, outcome: { self.diagnosticState }) {
            do {
                try store.update { state in
                    guard let i = state.records.firstIndex(where: { $0.id == id }), state.records[i].automatic,
                          state.records[i].status == .failed else { return }
                    state.records[i].retryAt = nil; state.records[i].attempts = 0
                    state.records[i].status = .pending; state.records[i].reason = nil
                }
                await scan()
                startForegroundUploads()
            } catch { log.emit(.configuration, .setup, DevelopmentLog.safeError(error), level: .error); self.error = error.localizedDescription }
            refresh()
        }
    }
    func checkPublication(_ id: UUID) async {
        return await log.action(.reconciliation, .queue, outcome: { self.diagnosticState }) {
            do {
                guard let lease = try store.lease() else { return }
                defer { withExtendedLifetime(lease) {} }
                guard var record = try store.read().records.first(where: { $0.id == id && $0.status == .uncertain }) else { return }
                let auth = try token()
                let person = try await tracedAPI.identity(token: auth)
                guard person.artistAddress.lowercased() == record.draft.owner.lowercased() else { throw AppError.message("Sign in with this upload’s account.") }
                if let found = try await tracedAPI.reconcile(record.draft, token: auth) {
                    record.draft.result = found; record.draft.stage = .published; record.status = .published; record.reason = nil
                    try store.save(record)
                } else { error = "This Moment has not appeared yet. It will not be created a second time." }
            } catch { log.emit(.configuration, .setup, DevelopmentLog.safeError(error), level: .error); self.error = error.localizedDescription }
            refresh()
        }
    }
    enum ExtensionOutcome: Equatable { case processing, completed, failure }
    private struct InvocationResult {
        /// A photo failed in this pass and was set aside until its retry time.
        var failed = false
        var progressed = false
        var examinedWork = false
        var awaitingRegisteredTransfer = false
    }

    /// Shared by the real extension entry point and offline lifecycle tests.
    func processForExtension() async -> ExtensionOutcome {
        let invocation = await runInvocation()
        if invocation.progressed { return .processing }
        // A blocked scan has not established that the library is up to date.
        // In particular, expired credentials must not signal monitoring/completion.
        if !invocation.examinedWork || error != nil || state.blocker != nil || state.records.contains(where: { $0.automatic && $0.status == .failed && $0.attempts < 3 }) {
            return .failure
        }
        // submit() returning false means the same system job already exists,
        // not that it finished. Keep the processing lifecycle until its terminal
        // event is acknowledged; do not re-create it or report monitoring idle.
        if invocation.awaitingRegisteredTransfer { return .processing }
        if state.records.contains(where: { $0.automatic && [.pending, .uploading, .uncertain].contains($0.status) }) {
            return .failure
        }
        return .completed
    }

    /// The app calls this as it becomes active or leaves. Becoming active starts uploading whatever is queued.
    func setForeground(_ active: Bool) {
        foregroundActive = active
        if active { startForegroundUploads() }
    }
    /// Uploads queued photos from the app while it is open, so an approval does not wait for Photos to wake the
    /// extension. One pass at a time; a second request while one is running is ignored.
    func startForegroundUploads() {
        guard foregroundUploads, foregroundActive, drainTask == nil else { return }
        drainTask = Task { [weak self] in
            await self?.drainInForeground()
            self?.drainTask = nil
        }
    }
    /// Lets the step in flight finish after the app leaves the foreground. No new photo is started once inactive.
    func finishForegroundUploads() async { await drainTask?.value }
    /// Stops the work in flight when the system is out of time. Saved checkpoints decide what happens next:
    /// a cut-off transfer is repeated, and a cut-off create is checked before anything else, never repeated.
    func cancelForegroundUploads() { drainTask?.cancel() }
    func drainInForeground() async {
        // Each pass handles one photo. Stop when the app leaves, when a pass finds nothing it may take, or after
        // a bounded number of passes so a persistent failure cannot spin.
        var idle = 0
        for _ in 0..<64 where foregroundActive && !Task.isCancelled {
            let invocation = await runInvocation(foreground: true)
            // A published photo or a newly failed one both mean the next pass has different work to try.
            if invocation.progressed || invocation.failed { idle = 0 } else { idle += 1 }
            if idle >= 1 { break }
        }
    }
    /// Invoked by the PhotoKit extension (or deterministic fixtures), never a timer.
    /// Returns true only when this invocation made progress. Work is bounded.
    func process() async -> Bool {
        await runInvocation().progressed
    }
    /// `foreground` is the app's own pass: it transfers the photo itself instead of registering a Photos job, and
    /// skips photos whose transfer Photos may already hold.
    private func runInvocation(foreground: Bool = false) async -> InvocationResult {
        var invocation = InvocationResult()
        var attemptedCredential: APICredential?
        let progressed = await log.action(.worker, .queue, outcome: { self.diagnosticState }) {
            guard !busy else { log.emit(.worker, .queue, [.reason: .tag(.busy)]); return false }; busy = true; error = nil
            defer { busy = false; refresh() }
            do {
                guard let lease = try store.lease() else { log.emit(.worker, .queue, [.reason: .tag(.leaseBusy)]); return false }
                defer { withExtendedLifetime(lease) {} }
                guard await scan(), let c = try store.read().configuration else { return false }
                guard !c.paused, online, c.cellular || !expensive else { log.emit(.worker, .queue, [.reason: .tag(.policyBlocked), .paused: .flag(c.paused), .online: .flag(online), .expensive: .flag(expensive), .cellular: .flag(c.cellular)]); return false }
                try Task.checkCancellation()
                let auth = try token()
                attemptedCredential = auth
                let person = try await tracedAPI.identity(token: auth)
                guard person.artistAddress.lowercased() == c.owner.lowercased() else {
                    try await block("owner", "Sign in with the account that configured these uploads."); return false
                }
                invocation.examinedWork = true
                try store.update { $0.incidents.remove(c.owner.lowercased() + ":owner"); $0.lastWorkerError = nil }
                var progress = false
                for event in try await log.trace(.systemJob, .photokit) { try await transfer.events() } {
                    try Task.checkCancellation()
                    guard var record = try store.read().records.first(where: { $0.id == event.operation && $0.automatic && $0.draft.owner.lowercased() == c.owner.lowercased() }) else { continue }
                    if try store.read().handledJobs.contains(event.jobID) {
                        try await log.trace(.acknowledgment, .photokit, [.operation: .id(event.operation), .job: .correlated(event.jobID)]) { try await transfer.acknowledge(event) }; progress = true; continue
                    }
                    // Persist terminal transfer result BEFORE acknowledging system tracking.
                    if record.draft.mediaURI == nil && record.status != .published && record.status != .uncertain && record.status != .canceled {
                        if event.succeeded {
                            record.draft.mediaURI = transfer.publicURI(for: record.draft)
                            record.draft.stage = .uploadingMetadata; record.status = .uploading; record.reason = nil
                        } else {
                            record.status = .failed; record.reason = event.message ?? "The photo transfer failed."
                            record.attempts += 1
                            record.retryAt = now().addingTimeInterval(min(3600, pow(2, Double(record.attempts)) * 30))
                        }
                        try store.save(record, handledJob: event.jobID)
                    }
                    _ = try store.update { $0.handledJobs.insert(event.jobID) }
                    try await log.trace(.acknowledgment, .photokit, [.operation: .id(event.operation), .job: .correlated(event.jobID)]) { try await transfer.acknowledge(event) }; progress = true
                }
                let records = try store.read().records.filter {
                    $0.automatic && $0.draft.owner.lowercased() == c.owner.lowercased() && $0.status != .published && $0.status != .canceled &&
                    !($0.status == .failed && ($0.attempts >= 3 || ($0.retryAt ?? .distantPast) > now()))
                }.sorted { ($0.status == .uncertain ? 1 : 0) < ($1.status == .uncertain ? 1 : 0) }
                log.emit(.worker, .queue, [.eligible: .number(records.count), .reason: .tag(records.isEmpty ? .noEligibleWork : .processing)])
                for var record in records.prefix(foreground ? records.count : 8) {
                    try Task.checkCancellation()
                    if foreground {
                        guard foregroundActive else { return progress } // Leaving the app starts nothing new.
                        // A transfer that began without the app's mark may belong to a Photos job; leave it to the extension.
                        if record.draft.mediaURI == nil && record.draft.stage != .draft && record.viaApp != true { continue }
                    }

                    // Recheck pause/auth/connectivity after every await and before new work.
                    guard let current = try store.read().configuration, !current.paused, online, current.cellular || !expensive else { return progress }
                    _ = try token()
                    if record.status == .failed && (record.attempts >= 3 || (record.retryAt ?? .distantPast) > now()) { continue }
                    if record.draft.stage == .submitting || record.draft.stage == .uncertain {
                        record.draft.stage = .uncertain; record.status = .uncertain; try store.save(record)
                        if let result = try await tracedAPI.reconcile(record.draft, token: token()) {
                            record.draft.result = result; record.draft.stage = .published; record.status = .published; record.reason = nil
                            try store.save(record); progress = true
                        }
                        continue
                    }
                    do {
                        if record.draft.mediaURI == nil {
                            let members = try await library.photos(in: current.albumID)
                            guard let photo = members.first(where: { $0.id == record.draft.sourceAssetID }) else {
                                // Cancel registered/pending work where possible; an already
                                // completed transfer is handled above, without promising undo.
                                record.status = .canceled; record.reason = "Removed from the album; no further publication will be started."
                                try store.save(record)
                                try await transfer.cancel(operation: record.id)
                                continue
                            }
                            guard record.draft.stage == .draft || record.revision == photo.revision else {
                                throw AppError.message("This photo changed after upload started. Its frozen operation needs checking before retry.")
                            }
                            if record.draft.stage == .draft {
                                record.revision = photo.revision; record.draft.mediaMIME = photo.mime; record.draft.mediaExtension = photo.fileExtension
                            }
                            record.draft.stage = .uploadingPhoto; record.status = .uploading
                            if foreground {
                                // The user may have un-approved or removed it since this pass listed its work.
                                guard try store.read().records.contains(where: { $0.id == record.id && $0.status != .canceled }) else { continue }
                                record.viaApp = true
                                try store.save(record); refresh() // Shown as uploading before the transfer begins.
                                let data = try await log.trace(.photoPrepare, .library, [.operation: .id(record.id)]) { try await library.data(for: photo.id) }
                                try Task.checkCancellation()
                                record.draft.mediaURI = try await tracedAPI.upload(data: data, object: record.draft.mediaObject, contentType: record.draft.mime)
                                record.draft.stage = .uploadingMetadata
                                try store.save(record); refresh()
                                // Metadata and creation follow below, in this same pass.
                            } else {
                                try store.save(record) // Stable object identity precedes PhotoKit registration.
                                let submitted = try await log.trace(.registration, .photokit, [.operation: .id(record.id)]) { try await transfer.submit(record, cellular: current.cellular) }
                                invocation.awaitingRegisteredTransfer = true
                                progress = progress || submitted
                                continue
                            }
                        }
                        if record.draft.metadataURI == nil {
                            record.draft.stage = .uploadingMetadata; try store.save(record)
                            let data = try JSONEncoder().encode(MomentMetadata(draft: record.draft, mediaURI: record.draft.mediaURI!))
                            record.draft.metadataURI = try await tracedAPI.upload(data: data, object: record.draft.metadataObject, contentType: "application/json")
                            try store.save(record)
                        }
                        let request = try CreateMomentRequest(draft: record.draft, metadataURI: record.draft.metadataURI!)
                        try await tracedAPI.simulate(request, token: token())
                        try Task.checkCancellation()
                        guard let latest = try store.read().configuration, !latest.paused, latest.signedOut != true, online, latest.cellular || !expensive else { return progress }
                        let freshToken = try token()
                        attemptedCredential = freshToken
                        record.draft.stage = .submitting; record.status = .uncertain
                        try store.save(record)
                        let result = try await tracedAPI.create(request, token: freshToken)
                        guard result.contractAddress.lowercased() == record.draft.destination.address.lowercased(), result.chainId == 8453,
                              !result.tokenId.isEmpty, result.hash?.hasPrefix("0x") == true else { throw AppError.message("Publication response needs checking.") }
                        record.draft.result = result; record.draft.stage = .published; record.status = .published; record.reason = nil
                        try store.save(record); progress = true
                    } catch {
                        log.emit(.worker, .queue, DevelopmentLog.safeError(error).merging([.operation: .id(record.id), .stage: .tag(LogTag(rawValue: record.draft.stage.rawValue) ?? .unknown)]) { _, new in new }, level: .error)
                        if record.status == .canceled {
                            record.reason = "Removed from the album. Transfer cancellation could not be confirmed; this operation will not be published."
                        } else if record.draft.stage.mayHavePublished {
                            record.draft.stage = .uncertain; record.status = .uncertain
                            record.reason = "The request may have completed. Checking will not publish another copy."
                        } else if case AppError.sessionExpired = error {
                            record.status = .pending; record.reason = "Sign in to resume uploads."
                        } else {
                            record.status = .failed; record.attempts += 1; record.reason = error.localizedDescription
                            invocation.failed = true
                            record.retryAt = now().addingTimeInterval(min(3600, pow(2, Double(record.attempts)) * 30))
                        }
                        try store.save(record)
                        if case AppError.sessionExpired = error { throw error }
                        if error is CancellationError { throw error }
                    }
                    break // One publication per invocation; do not monopolize extension runtime.
                }
                log.emit(.worker, .queue, [.progress: .flag(progress)])
                return progress
            } catch AppError.sessionExpired {
                if let attemptedCredential { try? sessions.invalidate(attemptedCredential) }
                try? await block("auth", "Sign in to resume uploads. Pending photos are saved.")
            } catch is CancellationError { log.emit(.worker, .queue, [.reason: .tag(.cancellation)]); /* Durable checkpoints survive termination. */ }
            catch {
                log.emit(.worker, .queue, DevelopmentLog.safeError(error), level: .error)
                self.error = error.localizedDescription
                try? store.update { $0.lastWorkerError = "Uploads could not continue. \(error.localizedDescription)" }
            }
            return false
        }
        invocation.progressed = progressed
        return invocation
    }
}
