#if DEBUG
import Foundation
import Photos
import UIKit
import CryptoKit

/// A deliberately separate, one-resource diagnostic. It never constructs an
/// authenticated API client or calls metadata/simulate/create. Only explicit
/// interaction in the Debug diagnostic screen can create its synthetic asset.
struct PhotoDiagnosticRecord: Codable {
    var id = UUID()
    var assetID: String
    var createdAt = Date()
    var phase = "Ready"
    var preflight: String?
    var detail: String?
    var active = true
    var sourceSHA256: String?
    var sourceByteCount: Int?
    var scenario: String?
    var notBefore: Date?
    var hostIsBackground: Bool?
    var hostBackgroundAt: Date?
    var hostForegroundAt: Date?
    var extensionInvokedAt: Date?
    var extensionProcessID: Int32?
    var registeredAt: Date?
    var registeredWhileBackground: Bool?
    var completedAt: Date?
    var jobID: String?
    var objectPath: String { "ios-photokit-diagnostic/\(id.uuidString.lowercased()).png" }
    var isExpired: Bool { Date().timeIntervalSince(createdAt) > 1800 }
    func registrationAllowed(at date: Date) -> Bool {
        scenario == nil || (hostIsBackground == true && notBefore.map { date >= $0 } == true)
    }
}
@MainActor enum PhotoDiagnostic {
    private static func file() throws -> URL { try UploadStore.shared().directory.appendingPathComponent("photo-diagnostic.json") }
    static func read() throws -> PhotoDiagnosticRecord? {
        let url = try file()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(PhotoDiagnosticRecord.self, from: Data(contentsOf: url))
    }
    static func save(_ record: PhotoDiagnosticRecord) throws {
        guard let lock = try UploadLease(url: UploadStore.shared().directory.appendingPathComponent("diagnostic.lock"), blocking: true) else { return }
        defer { withExtendedLifetime(lock) {} }
        var merged = record
        if let current = try read(), current.id == record.id {
            // Host lifecycle observations can arrive while the extension awaits Photos.
            merged.hostIsBackground = current.hostIsBackground
            merged.hostBackgroundAt = current.hostBackgroundAt
            merged.hostForegroundAt = current.hostForegroundAt
        }
        try JSONEncoder().encode(merged).write(to: file(), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try exportSharedEvidence(merged)
    }
    static func recordHostState(background: Bool) throws {
        guard let lock = try UploadLease(url: UploadStore.shared().directory.appendingPathComponent("diagnostic.lock"), blocking: true) else { return }
        defer { withExtendedLifetime(lock) {} }
        guard var record = try read() else { return }
        record.hostIsBackground = background
        if background { record.hostBackgroundAt = record.hostBackgroundAt ?? Date() }
        else { record.hostForegroundAt = Date() }
        try JSONEncoder().encode(record).write(to: file(), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try exportSharedEvidence(record)
    }
    // Explicit diagnostic export in the group's Documents directory. This is
    // separate from private control storage and contains no credentials.
    private static func exportSharedEvidence(_ record: PhotoDiagnosticRecord) throws {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: UploadStore.group) else { return }
        let directory = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: directory.appendingPathComponent("PhotoDiagnostic.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func exportEvidence(_ record: PhotoDiagnosticRecord) throws {
        try requirePhysicalInteraction()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("PhotoDiagnostic.json")
        try encoder.encode(record).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    /// Reuses only the previously verified generated PNG; never selects personal content.
    static func prepareScenario(_ scenario: String) async throws {
        try requirePhysicalInteraction()
        guard ["Host backgrounded", "Mirroring disconnected"].contains(scenario), try read() == nil else {
            throw AppError.message("Finish the current diagnostic before preparing a scenario.")
        }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { throw LibraryProblem.permission }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "pixelWidth == 320 AND pixelHeight == 240 AND creationDate >= %@ AND creationDate <= %@", Date(timeIntervalSince1970: 1794193200) as NSDate, Date(timeIntervalSince1970: 1794194100) as NSDate)
        let candidates = PHAsset.fetchAssets(with: .image, options: options)
        var matches: [PHAsset] = []
        candidates.enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            if !resources.contains(where: { $0.type == .adjustmentData }), resources.contains(where: { $0.filename == "InProcess-Synthetic-Diagnostic.png" }) { matches.append(asset) }
        }
        guard matches.count == 1, let asset = matches.first else { throw AppError.message("The original generated diagnostic photo could not be identified uniquely. No upload was prepared.") }
        let bytes = try await PhotosAlbumAccess.currentData(id: asset.localIdentifier, networkAllowed: false)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard hash == "49a4dd0ad692b1cdda13b1b63d4cd7b8f3a3048567bfca06a73ef16cae2a3da3", bytes.count == 2952 else {
            throw AppError.message("The generated photo no longer matches the verified source. No upload was prepared.")
        }
        var record = PhotoDiagnosticRecord(assetID: asset.localIdentifier)
        record.scenario = scenario; record.sourceSHA256 = hash; record.sourceByteCount = bytes.count
        try save(record)
    }
    static func configuration() throws -> (base: URL, bucket: String, key: String) {
        guard let file = Bundle.main.url(forResource: "ServiceConfig", withExtension: "plist"),
              let dictionary = NSDictionary(contentsOf: file),
              let raw = dictionary["StorageURL"] as? String, let base = URL(string: raw), base.scheme == "https",
              let bucket = dictionary["StorageBucket"] as? String,
              let key = dictionary["StoragePublicKey"] as? String else { throw AppError.message("Diagnostic storage configuration is missing.") }
        return (base, bucket, key)
    }
    static func request(_ record: PhotoDiagnosticRecord) throws -> URLRequest {
        let c = try configuration()
        var request = URLRequest(url: c.base.appendingPathComponent("storage/v1/object/\(c.bucket)/\(record.objectPath)"))
        request.httpMethod = "POST"
        request.setValue("image/png", forHTTPHeaderField: "Content-Type")
        request.setValue(c.key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(c.key)", forHTTPHeaderField: "Authorization")
        request.setValue("false", forHTTPHeaderField: "x-upsert")
        request.allowsCellularAccess = false; request.allowsExpensiveNetworkAccess = false
        return request
    }
    private static func requirePhysicalInteraction() throws {
        #if targetEnvironment(simulator)
        throw AppError.message("This diagnostic requires a physical iPhone; simulator tests cannot access its Photos or upload endpoint.")
        #else
        guard NSClassFromString("XCTestCase") == nil, !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--ui-test-") }) else {
            throw AppError.message("Physical diagnostics are disabled in test hosts.")
        }
        #endif
    }
    static func prepare() async throws -> PhotoDiagnosticRecord {
        try requirePhysicalInteraction()
        guard try read() == nil else { throw AppError.message("Finish the existing diagnostic before creating another.") }
        guard await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized else { throw LibraryProblem.permission }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240), format: format).pngData { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
            UIColor.systemYellow.setFill(); context.fill(CGRect(x: 80, y: 60, width: 160, height: 120))
        }
        var assetID: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions(); options.originalFilename = "InProcess-Synthetic-Diagnostic.png"
            request.addResource(with: .photo, data: bytes, options: options)
            assetID = request.placeholderForCreatedAsset?.localIdentifier
        }
        guard let assetID else { throw AppError.message("The synthetic photo could not be created.") }
        let record = PhotoDiagnosticRecord(assetID: assetID)
        try save(record)
        return record
    }
    static func start() async throws {
        try requirePhysicalInteraction()
        guard var record = try read(), record.phase == "Ready", !record.isExpired else { throw AppError.message("Prepare a fresh diagnostic first.") }
        // This read-only observation is deliberately NOT the production gate:
        // the diagnostic investigates actual system behavior even after generic 200.
        var preflight = try request(record); preflight.httpMethod = "OPTIONS"
        let (_, response) = try await URLSession.shared.data(for: preflight)
        if let response = response as? HTTPURLResponse {
            record.preflight = "OPTIONS \(response.statusCode); Upload-Limit: \(response.value(forHTTPHeaderField: "Upload-Limit") ?? "absent")"
        }
        if let scenario = record.scenario { record.notBefore = Date().addingTimeInterval(scenario == "Mirroring disconnected" ? 90 : 45) }
        record.phase = "Waiting for Photos"; try save(record)
        #if targetEnvironment(simulator)
        throw AppError.message("Actual PhotoKit diagnostics require the physical iPhone.")
        #else
        let options = PHAssetResourceUploadJobOptions(); options.preventsExpensiveNetworkAccess = true
        if PHPhotoLibrary.shared().uploadJobExtensionEnabled { try PHPhotoLibrary.shared().setUploadJobExtensionOptions(options) }
        else { try PHPhotoLibrary.shared().enableUploadJobExtension(with: options) }
        #endif
    }
    static func stop() throws {
        guard var record = try read() else { return }
        record.active = false
        if record.phase == "Ready" || record.phase == "Transfer succeeded" || record.phase == "Transfer failed" { record.phase = "Stopped" }
        else { record.phase = "Stopping" }
        record.detail = "No more uploads will be registered. Photos will cancel pending work when the extension runs; an already-sent upload may finish. The synthetic asset and any uploaded object are retained. No Moment was created."
        try save(record)
    }
    /// Reads only the already-recorded generated resource; creates no asset or job.
    static func verifySource() async throws {
        try requirePhysicalInteraction()
        guard var record = try read(), ["Transfer succeeded", "Transfer failed", "Stopped"].contains(record.phase) else {
            throw AppError.message("Wait for the diagnostic to finish before checking its source bytes.")
        }
        let asset = try PhotosAlbumAccess.asset(record.assetID)
        guard !PHAssetResource.assetResources(for: asset).contains(where: { $0.type == .adjustmentData }) else {
            throw AppError.message("The diagnostic asset has been edited; original-byte comparison is unavailable.")
        }
        let resource = try PhotosAlbumAccess.resource(asset)
        guard resource.filename == "InProcess-Synthetic-Diagnostic.png", resource.uniformTypeIdentifier == "public.png" else {
            throw AppError.message("The expected synthetic PNG resource is unavailable.")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = false
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: temporary, options: options)
        let bytes = try Data(contentsOf: temporary)
        record.sourceByteCount = bytes.count
        record.sourceSHA256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try save(record)
    }
    static func finish() throws {
        guard let record = try read() else { return }
        guard ["Ready", "Stopped", "Transfer succeeded", "Transfer failed"].contains(record.phase) else {
            throw AppError.message("Stop the diagnostic and wait for Photos to acknowledge or cancel its job before finishing. Refresh status to check.")
        }
        #if !targetEnvironment(simulator)
        if PHPhotoLibrary.shared().uploadJobExtensionEnabled { try PHPhotoLibrary.shared().disableUploadJobExtension() }
        #endif
        // Remove only diagnostic control state, never the synthetic photo, remote
        // object, queue or session. Ordinary app operation resumes on relaunch.
        let file = try file()
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    static func runIfConfigured() async -> PHBackgroundResourceUploadProcessingResult? {
        do {
            guard var record = try read() else { return nil }
            guard let lease = try UploadStore.shared().lease() else { return .processing }
            defer { withExtendedLifetime(lease) {} }
            try Task.checkCancellation()
            record.extensionInvokedAt = record.extensionInvokedAt ?? Date()
            record.extensionProcessID = ProcessInfo.processInfo.processIdentifier
            try save(record)
            let destination = try request(record)
            let terminal = PHAssetResourceUploadJob.fetchJobs(action: .acknowledge, options: nil)
            for i in 0..<terminal.count {
                let job = terminal.object(at: i)
                guard job.destination.url == destination.url else { continue }
                record.phase = job.state == .succeeded ? "Transfer succeeded" : "Transfer failed"
                record.completedAt = Date(); record.jobID = job.localIdentifier
                let headers = job.responseHeaderFields ?? [:]
                record.detail = "PhotoKit terminal result. Content-Type: \(headers["content-type"] ?? "not supplied"). \(job.error?.localizedDescription ?? "No transfer error reported.") No Moment was created."
                record.active = false; try save(record)
                try await PHPhotoLibrary.shared().performChanges { PHAssetResourceUploadJobChangeRequest(for: job)?.acknowledge() }
                return .completed
            }
            let pending = PHAssetResourceUploadJob.fetchJobs(action: .process, options: nil)
            if !record.active || record.isExpired {
                for i in 0..<pending.count {
                    let job = pending.object(at: i)
                    guard job.destination.url == destination.url else { continue }
                    try await PHPhotoLibrary.shared().performChanges { PHAssetResourceUploadJobChangeRequest(for: job)?.cancel() }
                }
                record.active = false; record.phase = "Stopped"; try save(record)
                return .completed
            }
            for i in 0..<pending.count where pending.object(at: i).destination.url == destination.url { return .processing }
            guard record.phase == "Waiting for Photos" || record.phase == "Registered" else { return .completed }
            // A lifecycle + time gate prevents a tiny upload finishing before the
            // intended Home/disconnect action. It never creates a second job.
            guard let latest = try read(), latest.id == record.id else { return .completed }
            record = latest
            guard record.registrationAllowed(at: Date()) else { return .processing }
            let asset = try PhotosAlbumAccess.asset(record.assetID)
            guard !PHAssetResource.assetResources(for: asset).contains(where: { $0.type == .adjustmentData }) else { throw AppError.message("The diagnostic asset was edited. Stop this diagnostic; it will not upload an edited resource.") }
            let resource = try PhotosAlbumAccess.resource(asset)
            guard resource.filename == "InProcess-Synthetic-Diagnostic.png", resource.uniformTypeIdentifier == "public.png" else { throw AppError.message("The expected synthetic PNG resource is unavailable.") }
            try Task.checkCancellation()
            record.phase = "Registered"; try save(record)
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetResourceUploadJobChangeRequest.creationRequestForJob(destination: destination, resource: resource)
            }
            record.registeredAt = Date(); record.registeredWhileBackground = record.hostIsBackground
            try save(record)
            return .processing
        } catch {
            if var record = try? read() { record.phase = "Diagnostic needs attention"; record.detail = error.localizedDescription; try? save(record) }
            // A diagnostic error must NEVER fall through into normal publication.
            return .failure
        }
    }
}
#endif
