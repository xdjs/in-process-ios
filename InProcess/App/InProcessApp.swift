import SwiftUI

@main
struct InProcessApp: App {
    @UIApplicationDelegateAdaptor(NotificationDelegate.self) private var notificationDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: AppModel?
    @State private var startupError: String?
    @State private var diagnostic = false
    @State private var keychainProbe = false
    @State private var albumWakeProbe = false
    init() {
        Theme.registerFonts()
        do {
            if ProcessInfo.processInfo.arguments.contains("--ui-test-automatic") {
                #if DEBUG && targetEnvironment(simulator)
                _model = State(initialValue: try AutomaticUIFixture.makeModel())
                return
                #else
                throw AppError.message("Automatic UI fixtures require a Debug simulator build.")
                #endif
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-test-publish") {
                #if DEBUG && targetEnvironment(simulator)
                _model = State(initialValue: try PublishUITestService.makeModel())
                return
                #else
                throw AppError.message("The publishing UI fixture requires a Debug simulator build.")
                #endif
            }
            #if DEBUG && targetEnvironment(simulator)
            if PublishUITestService.isHostedUnitTest {
                _model = State(initialValue: try PublishUITestService.makeModel(runID: UUID()))
                return
            }
            #endif
            #if DEBUG
            if try ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--album-wake-probe") }) || AlbumWakeProbeStorage.isArmed() {
                _albumWakeProbe = State(initialValue: true)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--keychain-probe") {
                _keychainProbe = State(initialValue: true)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--photo-upload-diagnostic") || (try? PhotoDiagnostic.read()) != nil {
                _diagnostic = State(initialValue: true)
                return
            }
            #endif
            guard !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--album-wake-probe") }) else { throw AppError.message("The wake diagnostic requires a Debug build.") }
            DevelopmentLog.shared.emit(.lifecycle, .app, [.stage: .tag(.initialize)])
            let api = try InProcessAPI()
            let library = PhotosAlbumAccess()
            let uploadStore = try UploadStore.shared()
            let legacy: [any SessionStoring] = [KeychainSessionStore(), KeychainSessionStore(shared: true)]
            let vault = KeychainCredentialVault(item: KeychainSessionStore(shared: true, accountOverride: "artist-credentials-v1"),
                lockDirectory: uploadStore.directory, legacy: legacy, uploadStore: uploadStore)
            let sessions = VaultSessions(vault: vault, legacyToClear: legacy)
            let automatic = try UploadCoordinator(store: uploadStore, library: library,
                transfer: PhotoKitTransfer(api: api), notifications: UploadNotifications(), api: api,
                sessions: sessions)
            #if DEBUG && !targetEnvironment(simulator)
            let validatingCredential = ProcessInfo.processInfo.arguments.contains("--validate-artist-credential")
            if validatingCredential {
                // Explicitly authorized live auth checks must not release pending
                // publication. Persist the normal pause before restore/observers.
                try uploadStore.update { $0.configuration?.paused = true }
                try automatic.transfer.disable()
            }
            #endif
            let setup = ArtistCredentialSetup(vault: vault, api: ObservedService(base: api, log: .shared))
            let model = AppModel(api: api, sessions: sessions, drafts: try DraftStore(), automatic: automatic, credentialSetup: setup)
            #if DEBUG && !targetEnvironment(simulator)
            model.credentialValidationMode = validatingCredential
            #endif
            model.connectivity = UploadConnectivity(coordinator: automatic)
            library.changed = { [weak automatic] in Task { await automatic?.refreshConfiguration(); await automatic?.scan() } }
            _model = State(initialValue: model)
        } catch { DevelopmentLog.shared.emit(.lifecycle, .app, DevelopmentLog.safeError(error), level: .error); _startupError = State(initialValue: error.localizedDescription) }
    }
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if albumWakeProbe { AlbumWakeProbeView() }
            else if keychainProbe { KeychainProbeView() }
            else if diagnostic { PhotoDiagnosticView() }
            else { content }
            #else
            content
            #endif
        }
    }
    @ViewBuilder private var content: some View {
            if let model {
                RootView(model: model).task {
                        await model.restore(); await model.automatic?.scan()
                        if UIApplication.shared.applicationState == .active { model.automatic?.setForeground(true) }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .openUploadStatus)) { _ in
                        model.openUploadStatus()
                        Task { await model.automatic?.scan() }
                    }
                    .onChange(of: scenePhase) { _, phase in
                        DevelopmentLog.shared.emit(.lifecycle, .app, [.stage: .tag(phase == .active ? .foreground : phase == .background ? .background : .inactive)])
                        if phase == .active {
                            Task {
                                await model.foreground(); await model.automatic?.refreshConfiguration(); await model.automatic?.scan()
                                // The app may have left again while that ran; only an app still in front uploads.
                                if UIApplication.shared.applicationState == .active { model.automatic?.setForeground(true) }
                            }
                        } else if phase == .background, let automatic = model.automatic {
                            // Start nothing new, let the step in flight finish, and release the shared lock before suspension.
                            automatic.setForeground(false)
                            var finishing = UIBackgroundTaskIdentifier.invalid
                            finishing = UIApplication.shared.beginBackgroundTask(withName: "FinishUpload") { automatic.cancelForegroundUploads() }
                            Task {
                                await automatic.finishForegroundUploads()
                                UIApplication.shared.endBackgroundTask(finishing)
                            }
                        }
                    }
                    #if DEBUG && targetEnvironment(simulator)
                    .overlay(alignment: .topTrailing) {
                        if let fixture = model.api as? AutomaticUITestAPI {
                            VStack(alignment: .trailing) {
                                Text("Isolated automatic test").accessibilityIdentifier("automaticTestMode").accessibilityValue(String(fixture.eventsHandled))
                                Text("Keys: \(fixture.keyCreates)").accessibilityIdentifier("keyCreateCount").accessibilityValue(String(fixture.keyCreates))
                            }.font(.caption2).allowsHitTesting(false)
                        }
                        if let fixture = model.api as? PublishUITestService {
                            PublishUITestStatus(service: fixture)
                        }
                    }
                    #endif
            }
            else { ContentUnavailableView("Couldn’t open In Process", systemImage: "exclamationmark.triangle", description: Text(startupError ?? "Please reopen the app.")) }
    }
}
