import Photos
import UIKit
import UniformTypeIdentifiers

@MainActor final class PhotosAlbumAccess: NSObject, AlbumAccess, PHPhotoLibraryChangeObserver {
    var changed: (() -> Void)?
    private var observing = false
    override init() { super.init(); observeIfDecided() }
    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    /// Registering a change observer before the user has answered makes iOS show the
    /// Photos prompt at launch, ahead of sign-in. Wait until a decision exists.
    private func observeIfDecided() {
        guard !observing, PHPhotoLibrary.authorizationStatus(for: .readWrite) != .notDetermined else { return }
        PHPhotoLibrary.shared().register(self); observing = true
    }
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        DevelopmentLog.shared.emit(.libraryChange, .library)
        Task { @MainActor [weak self] in self?.changed?() }
    }
    func requestAccess() async -> Bool {
        return await DevelopmentLog.shared.trace(.permission, .library) {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            DevelopmentLog.shared.emit(.permission, .library, [.status: .number(status.rawValue), .prompt: .flag(status == .notDetermined)])
            if status != .notDetermined { return status == .authorized }
            let result = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            DevelopmentLog.shared.emit(.permission, .library, [.status: .number(result.rawValue), .authorized: .flag(result == .authorized), .prompt: .flag(true)])
            observeIfDecided()
            return result == .authorized
        }
    }
    var authorizationStatus: PhotosAccessStatus {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: .full
        case .limited: .limited
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notRequested
        @unknown default: .unknown
        }
    }
    /// Small local rendition for history rows. Never fetches from iCloud.
    func thumbnail(for assetID: String, side: CGFloat) async -> UIImage? {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat; options.isNetworkAccessAllowed = false; options.resizeMode = .fast
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFill, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
    func albumName(for id: String) throws -> String {
        guard authorizationStatus == .full else { throw LibraryProblem.permission }
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw LibraryProblem.missingAlbum
        }
        return album.localizedTitle ?? "Untitled album"
    }
    func albums() throws -> [AlbumChoice] {
        return try DevelopmentLog.shared.trace(.albumList, .library) {
            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { throw LibraryProblem.permission }
            var result: [AlbumChoice] = []
            PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil).enumerateObjects { album, _, _ in
                if album.localizedTitle == "In Process" {
                    result.append(AlbumChoice(id: album.localIdentifier, name: album.localizedTitle ?? "In Process", count: PHAsset.fetchAssets(in: album, options: nil).count))
                }
            }
            return result
        }
    }
    func createAlbum() async throws -> String {
        return try await DevelopmentLog.shared.trace(.albumCreate, .library) {
            var identifier: String?
            try await PHPhotoLibrary.shared().performChanges {
                identifier = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "In Process").placeholderForCreatedAssetCollection.localIdentifier
            }
            guard let identifier else { throw AppError.message("Could not create the album.") }
            return identifier
        }
    }
    func add(_ assetIDs: [String], to album: String) async throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { throw LibraryProblem.permission }
        guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album], options: nil).firstObject else { throw LibraryProblem.missingAlbum }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        guard assets.count > 0 else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: collection)?.addAssets(assets)
        }
    }
    func remove(_ assetIDs: [String], from album: String) async throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { throw LibraryProblem.permission }
        guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album], options: nil).firstObject else { throw LibraryProblem.missingAlbum }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        guard assets.count > 0 else { return }
        // Album membership only: this never deletes the photo itself.
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: collection)?.removeAssets(assets)
        }
    }
    func data(for assetID: String) async throws -> Data { try await Self.currentData(id: assetID) }
    static func asset(_ id: String) throws -> PHAsset {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { throw LibraryProblem.permission }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { throw AppError.message("This photo is no longer available in Photos.") }
        guard asset.mediaType == .image else { throw AppError.message("Only still photos are supported.") }
        return asset
    }
    static func resource(_ asset: PHAsset) throws -> PHAssetResource {
        let resources = PHAssetResource.assetResources(for: asset)
        let index = try resourceIndex(types: resources.map(\.type))
        let resource = resources[index]
        _ = try PhotoProcessor.format(resource.uniformTypeIdentifier)
        return resource
    }
    func photos(in album: String) async throws -> [LibraryPhoto] {
        return try await DevelopmentLog.shared.trace(.scan, .library) {
            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { throw LibraryProblem.permission }
            guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album], options: nil).firstObject else { throw LibraryProblem.missingAlbum }
            var result: [LibraryPhoto] = []
            var videos = 0; var other = 0; var unsupported = 0
            PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
                guard asset.mediaType == .image else {
                    if asset.mediaType == .video { videos += 1 } else { other += 1 }; return
                }
                let resource = try? Self.resource(asset)
                let format = resource.flatMap { try? PhotoProcessor.format($0.uniformTypeIdentifier) }
                if format == nil { unsupported += 1 }
                // Keep unsupported stills visible in the queue; submission reports an item error.
                result.append(LibraryPhoto(id: asset.localIdentifier,
                    revision: String(asset.modificationDate?.timeIntervalSince1970 ?? asset.creationDate?.timeIntervalSince1970 ?? 0),
                    mime: format?.mime ?? "application/octet-stream", fileExtension: format?.ext ?? "unsupported"))
            }
            DevelopmentLog.shared.emit(.mediaInventory, .library, [.eligible: .number(result.count), .skippedVideo: .number(videos), .skippedOther: .number(other), .unsupported: .number(unsupported)])
            return result
        }
    }
    static func resourceIndex(types: [PHAssetResourceType]) throws -> Int {
        let edited = types.contains(.adjustmentData)
        guard let index = types.firstIndex(of: edited ? .fullSizePhoto : .photo) else {
            throw AppError.message("Photos has not supplied this photo’s current rendered still. Open it in Photos to finish downloading or rendering edits, then retry.")
        }
        return index
    }
    static func currentData(id: String, networkAllowed: Bool = true) async throws -> Data {
        try await resourceData(resource(asset(id)), networkAllowed: networkAllowed)
    }
    static func resourceData(_ resource: PHAssetResource, networkAllowed: Bool) async throws -> Data {
        return try await DevelopmentLog.shared.trace(.photoPrepare, .library) {
            let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = networkAllowed
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: temporary, options: options)
            try Task.checkCancellation()
            let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= PhotoProcessor.maximumInputBytes else { throw AppError.message("This rendition exceeds the app’s preparation safety limit. It has not been resized.") }
            return try Data(contentsOf: temporary)
        }
    }
}
