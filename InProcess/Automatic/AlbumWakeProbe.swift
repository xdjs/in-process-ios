#if DEBUG
import Foundation
import Photos
import CryptoKit

/// Explicit physical-device diagnostic. Its marker routes both processes away
/// from production clients. It creates neither Photos assets nor upload jobs.
struct AlbumWakeProbeRecord: Codable {
    let id: UUID
    let owner: String
    let albumID: String
    let probeAssetID: String
    let originalPaused: Bool
    let originalEnabled: Bool
    let cellular: Bool
    var token: Data
}

struct AlbumWakeProbeStorage {
    let store: UploadStore
    var marker: URL { store.directory.appendingPathComponent("album-wake-probe.json") }
    static func isArmed() throws -> Bool {
        FileManager.default.fileExists(atPath: try UploadStore.shared().directory.appendingPathComponent("album-wake-probe.json").path)
    }
    func read() throws -> AlbumWakeProbeRecord {
        try JSONDecoder().decode(AlbumWakeProbeRecord.self, from: Data(contentsOf: marker))
    }
    func save(_ record: AlbumWakeProbeRecord) throws {
        try JSONEncoder().encode(record).write(to: marker, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func arm(_ record: AlbumWakeProbeRecord) throws {
        guard let lease = try store.lease() else { throw AppError.message("An upload is still running.") }
        defer { withExtendedLifetime(lease) {} }
        let state = try store.read()
        guard !FileManager.default.fileExists(atPath: marker.path),
              state.configuration?.owner == record.owner, state.configuration?.albumID == record.albumID,
              state.records.allSatisfy({ $0.status == .published || $0.status == .canceled }) else {
            throw AppError.message("The wake diagnostic requires the configured account and an empty upload queue.")
        }
        try save(record)
        // Also protects a normal/Release worker if diagnostic routing is absent.
        try store.update { $0.configuration?.paused = true }
    }
    func restore(probeIsOutsideAlbum: Bool, restoreExtension: () throws -> Void) throws {
        guard probeIsOutsideAlbum else { throw AppError.message("Remove the synthetic card from the connected album before ending the diagnostic.") }
        guard let lease = try store.lease() else { throw AppError.message("Wait for the active worker to finish.") }
        defer { withExtendedLifetime(lease) {} }
        let record = try read()
        guard try store.read().configuration?.owner == record.owner,
              try store.read().configuration?.albumID == record.albumID else { throw CredentialSetupError.mismatch }
        try restoreExtension()
        try store.update { $0.configuration?.paused = record.originalPaused }
        try FileManager.default.removeItem(at: marker)
    }
}

@MainActor enum AlbumWakeProbe {
    static func requirePhysicalDevice() throws {
        #if targetEnvironment(simulator)
        throw AppError.message("The Photos wake diagnostic requires an explicitly authorized physical-device run.")
        #else
        guard NSClassFromString("XCTestCase") == nil,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            throw AppError.message("The Photos wake diagnostic is disabled in XCTest.")
        }
        #endif
    }
    static func start() async throws {
        try requirePhysicalDevice()
        if try AlbumWakeProbeStorage.isArmed() {
            let storage = AlbumWakeProbeStorage(store: try UploadStore.shared())
            let record = try storage.read()
            let state = try storage.store.read()
            guard state.configuration?.owner == record.owner,
                  state.configuration?.albumID == record.albumID,
                  state.configuration?.paused == true,
                  state.records.allSatisfy({ $0.status == .published || $0.status == .canceled }) else {
                throw AppError.message("The saved diagnostic is not isolated from production work.")
            }
            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
                  let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [record.albumID], options: nil).firstObject,
                  let asset = PHAsset.fetchAssets(withLocalIdentifiers: [record.probeAssetID], options: nil).firstObject else {
                throw AppError.message("The diagnostic album or synthetic card is unavailable.")
            }
            let members = PHAsset.fetchAssets(in: album, options: nil)
            let present = members.contains(asset)
            if ProcessInfo.processInfo.arguments.contains("--album-wake-probe-restart") {
                guard !present else { throw AppError.message("Remove the synthetic card from the connected album before restarting the diagnostic baseline.") }
                // An explicit new baseline, never a production wake workaround.
                if PHPhotoLibrary.shared().uploadJobExtensionEnabled { try PHPhotoLibrary.shared().disableUploadJobExtension() }
                let options = PHAssetResourceUploadJobOptions(); options.preventsExpensiveNetworkAccess = !record.cellular
                try PHPhotoLibrary.shared().enableUploadJobExtension(with: options)
            }
            DevelopmentLog.shared.emit(.configuration, .diagnostics, [.operation: .id(record.id), .paused: .flag(true),
                .enabled: .flag(PHPhotoLibrary.shared().uploadJobExtensionEnabled), .existing: .flag(present), .count: .number(members.count)])
            if ProcessInfo.processInfo.arguments.contains("--album-wake-probe-observe") {
                // Explicit post-window readback; never an idle wake or a job.
                let observer = try AlbumWakeProbeObserver(storage: storage)
                try observer.snapshot()
            }
            return
        }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { throw LibraryProblem.permission }
        let store = try UploadStore.shared()
        guard let config = try store.read().configuration else { throw LibraryProblem.missingAlbum }
        // Identify only the explicitly authorized card, then verify its bytes.
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "pixelWidth == 1536 AND pixelHeight == 1536 AND creationDate >= %@", Date(timeIntervalSince1970: 1794240000) as NSDate)
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        // Saving from Safari can rename the resource. Require one bounded
        // candidate and the exact authorized byte hash, never a filename guess.
        DevelopmentLog.shared.emit(.mediaInventory, .diagnostics, [.count: .number(assets.count)])
        guard assets.count == 1, let asset = assets.firstObject else { throw AppError.message("The authorized synthetic card could not be uniquely identified.") }
        let bytes = try await PhotosAlbumAccess.currentData(id: asset.localIdentifier, networkAllowed: false)
        let matchesFixture = SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == "0b090c9fa35c2345e77e865ebf373418fa6fb73e860e9bddc20d2682d20475d6"
        DevelopmentLog.shared.emit(.photoPrepare, .diagnostics, [.existing: .flag(matchesFixture)])
        guard matchesFixture else {
            throw AppError.message("The synthetic card does not match the authorized fixture.")
        }
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [config.albumID], options: nil).firstObject,
              !PHAsset.fetchAssets(in: album, options: nil).contains(asset) else { throw AppError.message("The synthetic card must start outside the connected album.") }
        let record = AlbumWakeProbeRecord(id: UUID(), owner: config.owner, albumID: config.albumID,
            probeAssetID: asset.localIdentifier, originalPaused: config.paused,
            originalEnabled: PHPhotoLibrary.shared().uploadJobExtensionEnabled, cellular: config.cellular,
            token: try NSKeyedArchiver.archivedData(withRootObject: PHPhotoLibrary.shared().currentChangeToken, requiringSecureCoding: true))
        try AlbumWakeProbeStorage(store: store).arm(record)
        // Explicit initial enable boundary, before the later membership-only test.
        if PHPhotoLibrary.shared().uploadJobExtensionEnabled { try PHPhotoLibrary.shared().disableUploadJobExtension() }
        let uploadOptions = PHAssetResourceUploadJobOptions(); uploadOptions.preventsExpensiveNetworkAccess = !record.cellular
        try PHPhotoLibrary.shared().enableUploadJobExtension(with: uploadOptions)
        DevelopmentLog.shared.emit(.configuration, .diagnostics, [.operation: .id(record.id), .paused: .flag(true), .enabled: .flag(true), .existing: .flag(false)])
    }
    static func stop() throws {
        try requirePhysicalDevice()
        let storage = AlbumWakeProbeStorage(store: try UploadStore.shared())
        let record = try storage.read()
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [record.albumID], options: nil).firstObject else { throw LibraryProblem.missingAlbum }
        let probe = PHAsset.fetchAssets(withLocalIdentifiers: [record.probeAssetID], options: nil).firstObject
        let outside = probe.map { !PHAsset.fetchAssets(in: album, options: nil).contains($0) } ?? true
        try storage.restore(probeIsOutsideAlbum: outside) {
            if record.originalEnabled {
                let options = PHAssetResourceUploadJobOptions(); options.preventsExpensiveNetworkAccess = !record.cellular
                if PHPhotoLibrary.shared().uploadJobExtensionEnabled { try PHPhotoLibrary.shared().setUploadJobExtensionOptions(options) }
                else { try PHPhotoLibrary.shared().enableUploadJobExtension(with: options) }
            } else if PHPhotoLibrary.shared().uploadJobExtensionEnabled { try PHPhotoLibrary.shared().disableUploadJobExtension() }
        }
        DevelopmentLog.shared.emit(.configuration, .diagnostics, [.operation: .id(record.id), .paused: .flag(record.originalPaused), .enabled: .flag(record.originalEnabled), .existing: .flag(false)])
    }
}

/// Retains both the collection fetch and its members for PHChange delivery and
/// registers the iOS 27 persistent-history observer. No callback schedules work.
@MainActor final class AlbumWakeProbeObserver: NSObject, PHPhotoLibraryChangeObserver, PHPhotoLibraryPersistentChangesObserver {
    private let storage: AlbumWakeProbeStorage
    private var collections: PHFetchResult<PHAssetCollection>
    private var members: PHFetchResult<PHAsset>
    init(storage: AlbumWakeProbeStorage) throws {
        try AlbumWakeProbe.requirePhysicalDevice()
        let record = try storage.read()
        self.storage = storage
        collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [record.albumID], options: nil)
        guard let album = collections.firstObject else { throw LibraryProblem.missingAlbum }
        members = PHAsset.fetchAssets(in: album, options: nil)
        super.init()
        PHPhotoLibrary.shared().register(self as any PHPhotoLibraryChangeObserver)
        PHPhotoLibrary.shared().register(self as any PHPhotoLibraryPersistentChangesObserver)
    }
    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        PHPhotoLibrary.shared().unregisterPersistentChangesObserver(self)
    }
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let change = changeInstance.changeDetails(for: self.collections) { self.collections = change.fetchResultAfterChanges }
            if let change = changeInstance.changeDetails(for: self.members) { self.members = change.fetchResultAfterChanges }
            self.observe(persistent: false)
        }
    }
    nonisolated func photoLibraryPersistentChangesDidUpdate(_ photoLibrary: PHPhotoLibrary) {
        Task { @MainActor [weak self] in self?.observe(persistent: true) }
    }
    private func observe(persistent: Bool) {
        do {
            guard try AlbumWakeProbeStorage.isArmed() else { return }
            try snapshot(event: .libraryChange, persistent: persistent)
        } catch { DevelopmentLog.shared.emit(.libraryChange, .diagnostics, DevelopmentLog.safeError(error), level: .error) }
    }
    func snapshot(event: LogEvent = .scan, persistent: Bool = true) throws {
        guard let lock = try UploadLease(url: storage.store.directory.appendingPathComponent("album-wake-probe.lock"), blocking: true) else { throw AppError.message("Could not lock the wake diagnostic.") }
        defer { withExtendedLifetime(lock) {} }
        var record = try storage.read()
        guard let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: record.token) else { throw AppError.message("The wake diagnostic token is unavailable.") }
        var inserted = Set<String>(), updated = Set<String>(), deleted = Set<String>()
        var collectionChanged = false, count = 0
        for change in try PHPhotoLibrary.shared().fetchPersistentChanges(since: token) {
            guard count < 100 else { throw AppError.message("The wake diagnostic history exceeded its bounded pass.") }
            count += 1
            do {
                let detail = try change.changeDetails(for: .asset)
                inserted.formUnion(detail.insertedLocalIdentifiers); updated.formUnion(detail.updatedLocalIdentifiers); deleted.formUnion(detail.deletedLocalIdentifiers)
            }
            do {
                let detail = try change.changeDetails(for: .assetCollection)
                collectionChanged = collectionChanged || detail.insertedLocalIdentifiers.contains(record.albumID) || detail.updatedLocalIdentifiers.contains(record.albumID) || detail.deletedLocalIdentifiers.contains(record.albumID)
            }
            record.token = try NSKeyedArchiver.archivedData(withRootObject: change.changeToken, requiringSecureCoding: true)
        }
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [record.albumID], options: nil).firstObject else { throw LibraryProblem.missingAlbum }
        members = PHAsset.fetchAssets(in: album, options: nil)
        let probe = PHAsset.fetchAssets(withLocalIdentifiers: [record.probeAssetID], options: nil).firstObject
        let present = probe.map { members.contains($0) } ?? false
        try storage.save(record)
        DevelopmentLog.shared.emit(event, .diagnostics, [.operation: .id(record.id), .album: .correlated(record.albumID),
            .count: .number(members.count), .existing: .flag(present), .configured: .flag(collectionChanged),
            .eligible: .number(updated.count), .enqueued: .number(inserted.count), .removed: .number(deleted.count),
            .attempts: .number(count), .automatic: .flag(persistent)])
    }
}
#endif
