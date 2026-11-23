import Photos
import ExtensionFoundation
import Foundation

@main final class UploadExtension: PHBackgroundResourceUploadJobExtension {
    private let lock = NSLock()
    private var work: Task<PHBackgroundResourceUploadProcessingResult, Never>?
    #if DEBUG
    @MainActor private var wakeProbe: AlbumWakeProbeObserver?
    #endif
    required init() { DevelopmentLog.shared.emit(.lifecycle, .photokit, [.stage: .tag(.initialize)]) }
    func processJobs() async -> PHBackgroundResourceUploadProcessingResult {
        let invocation = DevelopmentLog.shared.begin(.extensionInvocation, .photokit)
        let task = Task { @MainActor () -> PHBackgroundResourceUploadProcessingResult in
            await DevelopmentLog.$parentSpan.withValue(invocation.id) {
            do {
                #if DEBUG
                if try AlbumWakeProbeStorage.isArmed() {
                    if self.wakeProbe == nil { self.wakeProbe = try AlbumWakeProbeObserver(storage: AlbumWakeProbeStorage(store: UploadStore.shared())) }
                    try self.wakeProbe?.snapshot()
                    return .completed
                }
                if let diagnostic = await PhotoDiagnostic.runIfConfigured() { return diagnostic }
                #endif
                let config = URLSessionConfiguration.ephemeral
                let store = try UploadStore.shared()
                config.allowsCellularAccess = try store.read().configuration?.cellular ?? false
                config.allowsExpensiveNetworkAccess = config.allowsCellularAccess
                let api = try InProcessAPI(session: URLSession(configuration: config), networkPolicy: { (try? store.read().configuration?.cellular) ?? false })
                let vault = KeychainCredentialVault(item: KeychainSessionStore(shared: true, accountOverride: "artist-credentials-v1"),
                    lockDirectory: store.directory, legacy: [KeychainSessionStore(shared: true)], uploadStore: store)
                let worker = try UploadCoordinator(store: store, library: PhotosAlbumAccess(),
                    transfer: PhotoKitTransfer(api: api, runsInExtension: true), notifications: UploadNotifications(),
                    api: api, sessions: VaultSessions(vault: vault))
                let monitor = UploadConnectivity(coordinator: worker)
                defer { withExtendedLifetime(monitor) {} }
                DevelopmentLog.shared.emit(.configuration, .photokit, [.configured: .flag(worker.configured), .enabled: .flag(worker.transfer.isEnabled), .cellular: .flag(config.allowsCellularAccess)])
                let connectivity = await UploadConnectivity.current()
                DevelopmentLog.shared.emit(.connectivity, .network, [.online: .flag(connectivity.online), .expensive: .flag(connectivity.expensive)])
                worker.online = connectivity.online; worker.expensive = connectivity.expensive
                try Task.checkCancellation()
                switch await worker.processForExtension() {
                case .processing: return .processing
                case .failure: return .failure
                case .completed: return .completed
                }
            } catch { DevelopmentLog.shared.emit(.extensionInvocation, .photokit, DevelopmentLog.safeError(error), level: .error); return .failure }
            }
        }
        lock.withLock { work = task }
        let result = await task.value
        lock.withLock { work = nil }
        invocation.end(result == .processing ? .processing : result == .completed ? .completed : .failed)
        return result
    }
    func willTerminate() async {
        DevelopmentLog.shared.emit(.extensionTermination, .photokit, [.reason: .tag(.cancellation)])
        lock.withLock { work?.cancel() }
    }
}
