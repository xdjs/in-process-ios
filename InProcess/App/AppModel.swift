import SwiftUI
import PhotosUI
import Photos

enum AppRoute { case home, manual, setup }

@MainActor @Observable
final class AppModel {
    let log: DevelopmentLog
    private var tracedAPI: ObservedService { ObservedService(base: api, log: log) }
    let api: any InProcessServing
    let sessions: any SessionStoring
    let drafts: DraftStore
    let automatic: UploadCoordinator?
    let uploadStore: UploadStore?
    let credentialSetup: ArtistCredentialSetup?
    private var bootstrapSession: SavedSession?
    var needsCredentialRetry = false
    var mayReplaceCredential = false
    var signOutStatus: String?
    #if DEBUG
    var credentialValidationMode = false
    var credentialValidationStatus: String?
    #endif
    var route: AppRoute = .home { didSet { log.emit(.navigation, .app, [.stage: .tag(route == .home ? .home : route == .manual ? .manual : .setup), .authorized: .flag(isAuthenticated)]) } }
    var connectivity: UploadConnectivity?
    var email = ""
    var code = ""
    var codeSent = false
    var resendAvailableAt = Date.distantPast
    /// The address the last code went to. The resend wait applies only to that address.
    private var codeSentTo: String?
    var session: SavedSession?
    var identity: Identity?
    var destination: Destination?
    var draft: Draft?
    var photo: UIImage?
    var activity: String?
    var error: String?
    var didRestore = false
    private(set) var isRestoring = false
    /// True while a submitted code is being verified and the account loaded, so recovery controls are not shown mid sign-in.
    private(set) var isSigningIn = false
    /// True from launch until the saved session has been checked, so the sign-in screen is not shown in between.
    var restoringSession: Bool { !didRestore || isRestoring }
    var loadingPhoto = false
    private var selectionGeneration = UUID()

    init(api: any InProcessServing, sessions: any SessionStoring, drafts: DraftStore, automatic: UploadCoordinator? = nil, uploadStore: UploadStore? = nil, credentialSetup: ArtistCredentialSetup? = nil, log: DevelopmentLog = .shared) {
        self.log = log
        self.api = api; self.sessions = sessions; self.drafts = drafts
        self.automatic = automatic; self.uploadStore = uploadStore ?? automatic?.store
        self.credentialSetup = credentialSetup
    }
    var isAuthenticated: Bool { session?.isExpired == false && identity != nil && destination != nil }
    var isBusy: Bool { activity != nil || loadingPhoto }
    var validEmail: Bool { email.trimmingCharacters(in: .whitespacesAndNewlines).range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) != nil }
    var validCode: Bool { code.range(of: "^[0-9]{6}$", options: .regularExpression) != nil }
    var ownsDraft: Bool { draft?.owner.lowercased() == identity?.artistAddress.lowercased() }
    var canPublish: Bool {
        #if DEBUG
        if credentialValidationMode { return false }
        #endif
        return !isBusy && ownsDraft && draft?.hasPhoto == true && draft?.stage.mayHavePublished == false
    }

    func restore() async {
        await log.action(.authRestore, .auth, outcome: { [.failed: .flag(self.error != nil), .authorized: .flag(self.isAuthenticated)] }) {
            guard !didRestore else { return }
            didRestore = true; isRestoring = true; activity = "Opening In Process…"
            defer { activity = nil; isRestoring = false }
            do {
                draft = try drafts.load()
                if let credentialSetup, credentialSetup.pendingRevocationCount != 0 {
                    signOutStatus = "Remote key removal is pending; sign in to the same account online to finish."
                }
                if let credentialSetup, try credentialSetup.vault.snapshot().pending != nil {
                    session = try await credentialSetup.resume()
                    try await loadAccount(); return
                }
                if let saved = try log.trace(.secureLoad, .auth, body: { try sessions.load() }) {
                    email = saved.email
                    session = saved
                    if saved.isExpired { expireSessionIfNeeded(); return }
                    try await loadAccount()
                    route = .home
                }
            } catch { handleSetupOrAccount(error) }
        }
    }
    func sendCode() async {
        await log.action(.authCode, .auth, outcome: { [.failed: .flag(self.error != nil), .authorized: .flag(self.isAuthenticated)] }) {
            guard !isBusy, validEmail else { return }
            email = email.trimmingCharacters(in: .whitespacesAndNewlines)
            // A corrected address must not wait out the previous address's resend delay.
            guard Date() >= resendAvailableAt || email.lowercased() != codeSentTo else {
                codeSent = true; return // The code for this address was just sent; go back to entering it.
            }
            activity = "Sending your code…"; error = nil
            defer { activity = nil }
            do {
                try await tracedAPI.sendCode(email: email)
                codeSent = true; code = ""; resendAvailableAt = Date().addingTimeInterval(60); codeSentTo = email.lowercased()
            } catch { handle(error) }
        }
    }
    func signIn() async {
        await log.action(.authVerify, .auth, outcome: { [.failed: .flag(self.error != nil), .authorized: .flag(self.isAuthenticated)] }) {
            guard !isBusy, validCode else { return }
            activity = "Signing in…"; error = nil; isSigningIn = true
            defer { activity = nil; isSigningIn = false }
            do {
                let response = try await tracedAPI.login(email: email, code: code)
                let saved = SavedSession(token: response.token, email: email, expiresAt: SavedSession.expiration(token: response.token))
                guard !saved.isExpired else { throw AppError.sessionExpired }
                code = ""; signOutStatus = nil
                if let credentialSetup {
                    bootstrapSession = saved
                    session = try await credentialSetup.begin(saved)
                    bootstrapSession = nil
                } else {
                    try log.trace(.secureSave, .auth) { try sessions.save(saved) }; session = saved
                }
                try await loadAccount()
                route = .home
            } catch { handleSetupOrAccount(error) }
        }
    }
    func retryAccount() async {
        await log.action(.accountRecovery, .auth, outcome: { [.failed: .flag(self.error != nil), .authorized: .flag(self.isAuthenticated)] }) {
            guard !isBusy else { return }
            activity = "Loading your account…"; error = nil
            defer { activity = nil }
            do {
                if let credentialSetup {
                    if let bootstrapSession { session = try await credentialSetup.begin(bootstrapSession); self.bootstrapSession = nil }
                    else { session = try await credentialSetup.resume() }
                }
                try await loadAccount(); route = .home
            } catch { handleSetupOrAccount(error) }
        }
    }
    func replaceUncertainCredential() async {
        guard !isBusy, let credentialSetup else { return }
        do { try credentialSetup.allowReplacement(); mayReplaceCredential = false; await retryAccount() }
        catch { handleSetupOrAccount(error) }
    }
    private func handleSetupOrAccount(_ problem: Error) {
        if let credentialSetup, (try? credentialSetup.vault.snapshot().pending) != nil || bootstrapSession != nil {
            needsCredentialRetry = true; mayReplaceCredential = credentialSetup.needsReplacement
            error = (problem as? LocalizedError)?.errorDescription ?? CredentialSetupError.retry.errorDescription
            let needsOTP: Bool
            if case CredentialSetupError.signIn = problem { needsOTP = true }
            else if case AppError.sessionExpired = problem { needsOTP = true }
            else { needsOTP = false }
            if needsOTP {
                bootstrapSession = nil; codeSent = false
                // Keep a still-working active credential; otherwise show OTP recovery.
                if session?.isExpired != false { session = nil; needsCredentialRetry = false }
            }
        } else { handle(problem) }
    }
    private func loadAccount() async throws {
        try await log.trace(.accountLoad, .auth) {
            if let credentialSetup, let session, session.kind == .bearer {
                self.session = try await credentialSetup.begin(session)
            }
            let token = try activeToken()
            let person = try await tracedAPI.identity(token: token)
            if session?.kind == .artistKey {
                guard session?.owner?.lowercased() == person.artistAddress.lowercased() else { throw CredentialSetupError.mismatch }
            }
            guard CreateMomentRequest.isAddress(person.artistAddress), person.profile != nil else {
                throw AppError.message("An existing In Process profile is required. Open inprocess.world to check your account.")
            }
            let collection = try await tracedAPI.destination(token: token)
            guard collection.chain_id == 8453, CreateMomentRequest.isAddress(collection.address) else {
                throw AppError.message("Your default collection must be on Base for this version of the app.")
            }
            guard try activeToken() == token else { throw AppError.sessionExpired }
            identity = person; destination = collection; codeSent = false
            needsCredentialRetry = false; mayReplaceCredential = false
            if draft == nil {
                let fresh = Draft(owner: person.artistAddress, destination: collection)
                try drafts.save(fresh); draft = fresh
            }
            if ownsDraft, let draft, draft.hasPhoto { photo = UIImage(data: try drafts.photo(draft)) }
            else { photo = nil }
            if let session { await automatic?.resumeSession(session, owner: person.artistAddress) }
            if let draft, draft.stage == .published { try uploadStore?.recordManual(draft) }
            if let credentialSetup {
                await credentialSetup.revokePending(using: token, owner: person.artistAddress)
                if credentialSetup.pendingRevocationCount != 0 { signOutStatus = "Removal of an earlier sign-in key is pending. It will be retried when that account signs in online." }
                else { signOutStatus = nil }
            }
            #if DEBUG
            if credentialValidationMode { try await validateCredentialWithoutPublishing() }
            #endif
        }
    }
    #if DEBUG
    func validateCredentialWithoutPublishing() async throws {
        guard credentialValidationMode, session?.kind == .artistKey,
              try uploadStore?.read().configuration?.paused == true else { throw CredentialSetupError.retry }
        guard ownsDraft, let draft, draft.stage == .published, let metadata = draft.metadataURI else {
            credentialValidationStatus = "Artist-key account validation passed. Simulation skipped: no published draft is available. Uploads remain paused."
            return
        }
        let credential = try activeToken()
        try await tracedAPI.simulate(CreateMomentRequest(draft: draft, metadataURI: metadata), token: credential)
        guard try activeToken() == credential else { throw CredentialSetupError.changed }
        credentialValidationStatus = "Artist-key account validation and simulation passed. No publication was requested. Uploads remain paused."
    }
    #endif
    func signOut() {
        log.action(.signOut, .auth, outcome: { [.failed: .flag(self.error != nil), .authorized: .flag(self.isAuthenticated)] }) {
            guard !isBusy else { return }
            let outgoing = session
            signOutStatus = nil
            defer {
                session = nil; identity = nil; destination = nil; photo = nil; code = ""; codeSent = false
                bootstrapSession = nil; needsCredentialRetry = false; mayReplaceCredential = false; route = .home
                credentialSetup?.discardMemory()
            }
            do {
                automatic?.signOut()
                try log.trace(.secureClear, .auth) { try sessions.clear() }
                route = .home
                session = nil; identity = nil; destination = nil; photo = nil; code = ""; codeSent = false; error = nil
                bootstrapSession = nil; needsCredentialRetry = false; mayReplaceCredential = false
                if let credentialSetup {
                    signOutStatus = credentialSetup.pendingRevocationCount != 0
                        ? "Signed out on this iPhone. Remote key removal is pending; sign in to the same account online to finish."
                        : "Signed out on this iPhone."
                    if let outgoing, let owner = outgoing.owner {
                        Task {
                            await credentialSetup.revokePending(using: outgoing.credential, owner: owner)
                            guard self.session == nil else { return }
                            if credentialSetup.pendingRevocationCount == 0 { self.signOutStatus = "Signed out. This iPhone’s sign-in key was removed from the service." }
                        }
                    }
                }
            } catch { handle(error) }
        }
    }
    // All external status entry points share the same home destination. RootView
    // applies the authentication gate before rendering any route.
    func openUploadStatus() {
        expireSessionIfNeeded()
        route = .home
    }
    func expireSessionIfNeeded() {
        guard session?.isExpired == true else { return }
        log.emit(.authExpiry, .auth, [.expired: .flag(true)])
        handle(AppError.sessionExpired)
    }
    func waitForSessionExpiry() async {
        guard session?.kind == .bearer, let expiry = session?.expiresAt else { return }
        do { try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow))) }
        catch { return }
        guard !Task.isCancelled, session?.expiresAt == expiry else { return }
        expireSessionIfNeeded()
    }
    func foreground() async {
        guard credentialSetup != nil, didRestore, !isBusy else { expireSessionIfNeeded(); return }
        var attempted: APICredential?
        do {
            guard let current = try sessions.load(), !current.isExpired else {
                if session != nil { handle(AppError.sessionExpired) }
                return
            }
            if current.credential != session?.credential || current.kind == .bearer || identity == nil {
                session = current; await retryAccount(); return
            }
            attempted = current.credential
            let person = try await tracedAPI.identity(token: current.credential)
            guard session?.credential == current.credential else { return }
            guard person.artistAddress.lowercased() == current.owner?.lowercased() else { throw CredentialSetupError.mismatch }
        } catch {
            // Foreground checks can overlap a later sign-out/sign-in. A late
            // rejection must never invalidate that replacement credential.
            if let attempted, session?.credential != attempted { return }
            handle(error)
        }
    }
    func activeToken() throws -> APICredential {
        guard let session, !session.isExpired else { throw AppError.sessionExpired }
        if credentialSetup != nil {
            guard let current = try sessions.load(), current.credential == session.credential, !current.isExpired else { throw AppError.sessionExpired }
        }
        return session.credential
    }

    func loadPhoto(_ item: PhotosPickerItem?) async {
        await log.action(.photoPicker, .library, outcome: { [.failed: .flag(self.error != nil), .authorized: .flag(self.isAuthenticated)] }) {
            guard let item, ownsDraft, draft?.stage == .draft else { return }
            let generation = UUID(); selectionGeneration = generation
            loadingPhoto = true; error = nil
            defer { if selectionGeneration == generation { loadingPhoto = false } }
            do {
                let data: Data
                if let id = item.itemIdentifier, PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized {
                    data = try await PhotosAlbumAccess.currentData(id: id)
                } else {
                    guard let selected = try await item.loadTransferable(type: Data.self) else { throw AppError.message("This photo could not be downloaded. Try selecting it again.") }
                    data = selected
                }
                try Task.checkCancellation()
                let prepared = try await Task.detached(priority: .userInitiated) { try PhotoProcessor.prepare(data) }.value
                try Task.checkCancellation()
                guard generation == selectionGeneration else { return }
                try acceptPhoto(prepared, sourceAssetID: item.itemIdentifier)
            } catch is CancellationError { /* Keep the previous selection. */ }
            catch { if generation == selectionGeneration { handle(error) } }
        }
    }
    func cancelPhotoLoad() { log.emit(.photoCancel, .library); selectionGeneration = UUID(); loadingPhoto = false }
    func acceptPhoto(_ prepared: Data, sourceAssetID: String? = nil) throws {
        try log.trace(.photoPrepare, .library) {
            try acceptPhoto(PhotoProcessor.inspect(prepared), sourceAssetID: sourceAssetID)
        }
    }
    func acceptPhoto(_ inspected: PreparedPhoto, sourceAssetID: String? = nil) throws {
        let span = log.begin(.photoPrepare, .library)
        defer { span.end(.returned, [.available: .flag(photo != nil)]) }
        guard var value = draft, ownsDraft, value.stage == .draft else { return }
        let oldURL = drafts.photoURL(value)
        value.sourceAssetID = sourceAssetID; value.mediaMIME = inspected.mime; value.mediaExtension = inspected.fileExtension
        value.alterations = inspected.alterations
        try drafts.savePhoto(inspected.data, draft: value)
        value.hasPhoto = true; try drafts.save(value)
        if oldURL != drafts.photoURL(value) { try? FileManager.default.removeItem(at: oldURL) }
        draft = value; photo = UIImage(data: inspected.data)
        if !inspected.alterations.isEmpty, let automatic {
            let noticeID = "alteration:\(value.id.uuidString)"
            let first = try automatic.store.update { $0.incidents.insert(noticeID).inserted }
            if first { Task { await automatic.notifications.notify(id: noticeID, message: inspected.alterations.joined(separator: " ")) } }
        }
    }
    func removePhoto() {
        log.action(.photoRemove, .library, outcome: { [.failed: .flag(self.error != nil), .authorized: .flag(self.isAuthenticated)] }) {
            guard !isBusy, var value = draft, value.stage == .draft else { return }
            value.hasPhoto = false; value.sourceAssetID = nil
            do { try drafts.save(value); draft = value; photo = nil } catch { handle(error) }
        }
    }
    func edit(title: String? = nil, description: String? = nil) {
        guard !isBusy, var value = draft, value.stage == .draft else { return }
        if let title { value.title = title }
        if let description { value.description = description }
        do { try drafts.save(value); draft = value } catch { handle(error) }
    }
    private func persist(_ value: Draft) throws {
        log.emit(.manualCheckpoint, .queue, [.operation: .id(value.id), .stage: .tag(LogTag(rawValue: value.stage.rawValue) ?? .unknown)])
        try drafts.save(value); draft = value
        if value.stage != .draft { try uploadStore?.recordManual(value) }
    }

    func publish() async {
        await log.action(.manualPublish, .queue, outcome: { [.failed: .flag(self.error != nil), .authorized: .flag(self.isAuthenticated)] }) {
            guard canPublish, var value = draft else { return }
            var lease: UploadLease?
            do {
                if let uploadStore {
                    guard let acquired = try uploadStore.lease() else { throw AppError.message("Another upload is finishing. Try again shortly.") }
                    lease = acquired
                    if let previous = try uploadStore.reserveManual(value) {
                        value.stage = .published; value.result = previous.result
                        value.mediaURI = previous.mediaURI; value.metadataURI = previous.metadataURI
                        try persist(value); return
                    }
                }
            } catch { handle(error); return }
            defer { withExtendedLifetime(lease) {} }
            activity = "Checking your account…"; error = nil
            defer { activity = nil }
            do {
                let token = try activeToken()
                let person = try await tracedAPI.identity(token: token)
                guard person.artistAddress.lowercased() == value.owner.lowercased() else {
                    throw AppError.message("This draft belongs to a different account. Sign in with the account that created it.")
                }
                // All subsequent content is frozen. A retry reuses the exact same bytes and paths.
                if value.mediaURI == nil {
                    value.stage = .uploadingPhoto; try persist(value)
                    activity = "Uploading your photo…"
                    value.mediaURI = try await tracedAPI.upload(data: drafts.photo(value), object: value.mediaObject, contentType: value.mime)
                    try persist(value)
                }
                if value.metadataURI == nil {
                    value.stage = .uploadingMetadata; try persist(value)
                    activity = "Saving the details…"
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    let data = try encoder.encode(MomentMetadata(draft: value, mediaURI: value.mediaURI!))
                    value.metadataURI = try await tracedAPI.upload(data: data, object: value.metadataObject, contentType: "application/json")
                    try persist(value)
                }
                value.stage = .ready; try persist(value)
                let request = try CreateMomentRequest(draft: value, metadataURI: value.metadataURI!)
                activity = "Preparing your Moment…"
                try await tracedAPI.simulate(request, token: token)
                guard try activeToken() == token else { throw AppError.sessionExpired }
                value.stage = .submitting
                // Durable write MUST succeed before the sole broadcast request.
                try persist(value)
                activity = "Publishing your Moment…"
                let result = try await tracedAPI.create(request, token: token)
                guard result.contractAddress.lowercased() == value.destination.address.lowercased(), result.chainId == 8453,
                      !result.tokenId.isEmpty, result.hash?.hasPrefix("0x") == true else {
                    throw AppError.message("The publication response needs to be checked.")
                }
                value.result = result; value.stage = .published
                try persist(value)
            } catch {
                if draft?.stage == .submitting {
                    // Keep the in-memory lock even if the next disk write fails; the
                    // persisted submitting state also restores as uncertain on launch.
                    draft?.stage = .uncertain
                    if let locked = draft { try? drafts.save(locked) }
                    self.error = "The response was interrupted. Your Moment may already be published. Check its status before doing anything else."
                } else { handle(error) }
            }
        }
    }
    func checkPublication() async {
        await log.action(.reconciliation, .queue, outcome: { [.failed: .flag(self.error != nil), .authorized: .flag(self.isAuthenticated)] }) {
            guard !isBusy, ownsDraft, var value = draft, value.stage == .uncertain else { return }
            activity = "Checking your timeline…"; error = nil
            defer { activity = nil }
            do {
                let token = try activeToken()
                if let found = try await tracedAPI.reconcile(value, token: token) {
                    value.result = found; value.stage = .published; try persist(value)
                } else { error = "This Moment has not appeared in your timeline yet. Check again later. We will not publish it a second time." }
            } catch { handle(error) }
        }
    }
    func startAnother() {
        log.action(.newDraft, .queue, outcome: { [.failed: .flag(self.error != nil), .authorized: .flag(self.isAuthenticated)] }) {
            guard !isBusy, let value = draft, value.stage == .published, let identity, let destination else { return }
            do {
                try uploadStore?.recordManual(value)
                try drafts.remove(value)
                let fresh = Draft(owner: identity.artistAddress, destination: destination)
                try persist(fresh); photo = nil; error = nil
            } catch { handle(error) }
        }
    }
    private func handle(_ problem: Error) {
        log.emit(.authGate, .auth, DevelopmentLog.safeError(problem), level: .error)
        if case AppError.sessionExpired = problem {
            if let session { try? sessions.invalidate(session.credential) }
            cancelPhotoLoad()
            session = nil; identity = nil; destination = nil; photo = nil; code = ""; codeSent = false
            route = .home
            Task { await automatic?.scan() }
        }
        error = (problem as? LocalizedError)?.errorDescription ?? "The connection was interrupted. Try again when you’re online. Your draft is saved."
    }
}
