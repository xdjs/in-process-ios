import UIKit
import Foundation
import Darwin

struct AlbumChoice: Identifiable, Equatable { let id: String; let name: String; let count: Int }
struct LibraryPhoto: Equatable {
    let id: String
    let revision: String
    let mime: String
    let fileExtension: String
}
enum LibraryProblem: Error { case permission, missingAlbum }
enum PhotosAccessStatus: String {
    case full = "Full access", limited = "Limited access", denied = "Denied"
    case restricted = "Restricted", notRequested = "Not requested", unknown = "Unknown"
}
enum NotificationAccessStatus: String {
    case allowed = "Allowed", quiet = "Quiet delivery", temporary = "Temporary access"
    case denied = "Denied", notRequested = "Not requested", unknown = "Unknown"
}
struct AutomaticConfiguration: Codable, Equatable {
    var owner: String
    var destination: Destination
    var albumID: String
    var cellular = true
    var paused = false
    var signedOut: Bool?
    /// Whether photos added to the album are queued without asking. Missing in configurations saved before
    /// this setting existed, which always uploaded automatically.
    var autoUpload: Bool?
    var uploadsAutomatically: Bool { autoUpload ?? true }
}
enum QueueStatus: String, Codable { case pending, uploading, published, failed, canceled, uncertain }
struct UploadRecord: Codable, Identifiable {
    var draft: Draft
    var automatic: Bool
    var revision: String?
    var status: QueueStatus = .pending
    var reason: String?
    var attempts = 0
    var retryAt: Date?
    /// True once the app itself, not Photos, began transferring this photo. The app may resume such a transfer;
    /// one without the mark may be held by a Photos upload job and is left to the extension.
    var viaApp: Bool?
    var id: UUID { draft.id }
}
struct UploadState: Codable {
    var version = 1
    var configuration: AutomaticConfiguration?
    var records: [UploadRecord] = []
    var incidents: Set<String> = []
    var handledJobs: Set<String> = []
    var blocker: String?
    var lastWorkerError: String?
    var lastCheck: Date?
}

/// OS locks serialize host/extension writes. A separate nonblocking lifetime lock
/// serializes publication across awaits; process death releases it automatically.
final class UploadLease {
    private let descriptor: Int32
    init?(url: URL, blocking: Bool = false) throws {
        descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AppError.message("Could not open the upload lock.") }
        if flock(descriptor, LOCK_EX | (blocking ? 0 : LOCK_NB)) != 0 {
            close(descriptor)
            if !blocking && (errno == EWOULDBLOCK || errno == EAGAIN) { return nil }
            throw AppError.message("Could not lock saved uploads.")
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
struct UploadStore {
    static let group = "group.com.xdjs.InProcess"
    let directory: URL
    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var folder = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }
    static func shared() throws -> UploadStore {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw AppError.message("Shared upload storage is unavailable. Check the app’s App Group signing configuration.")
        }
        return try UploadStore(directory: root.appendingPathComponent("Uploads", isDirectory: true))
    }
    func lease() throws -> UploadLease? { try UploadLease(url: directory.appendingPathComponent("worker.lock")) }
    func update<T>(_ body: (inout UploadState) throws -> T) throws -> T {
        guard let lock = try UploadLease(url: directory.appendingPathComponent("state.lock"), blocking: true) else {
            throw AppError.message("Could not lock saved uploads.")
        }
        defer { withExtendedLifetime(lock) {} }
        let url = directory.appendingPathComponent("queue.json")
        var state = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode(UploadState.self, from: Data(contentsOf: url)) : UploadState()
        guard state.version == 1 else { throw AppError.message("Update the app to read saved uploads.") }
        let result = try body(&state)
        try JSONEncoder().encode(state).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return result
    }
    func read() throws -> UploadState { try update { $0 } }
    func save(_ record: UploadRecord, handledJob: String? = nil) throws {
        try update { state in
            if let index = state.records.firstIndex(where: { $0.id == record.id }) { state.records[index] = record }
            else { state.records.append(record) }
            if let handledJob { state.handledJobs.insert(handledJob) }
        }
        DevelopmentLog.shared.emit(.queueCheckpoint, .queue, [.operation: .id(record.id), .status: .tag(LogTag(rawValue: record.status.rawValue) ?? .unknown), .stage: .tag(LogTag(rawValue: record.draft.stage.rawValue) ?? .unknown), .attempts: .number(record.attempts)])
    }
    /// Call with the publication lease held, before a manual upload starts.
    func reserveManual(_ draft: Draft) throws -> Draft? {
        try update { state in
            if let asset = draft.sourceAssetID, let existing = state.records.first(where: {
                $0.id != draft.id && $0.draft.owner.lowercased() == draft.owner.lowercased() && $0.draft.sourceAssetID == asset && $0.status != .canceled
            }) {
                if existing.status == .published { return existing.draft }
                guard existing.automatic && existing.status == .pending && existing.draft.stage == .draft else {
                    throw AppError.message("This photo already has an upload in progress or needing recovery. Open upload history to check it.")
                }
                state.records.removeAll { $0.id == existing.id }
            }
            if !state.records.contains(where: { $0.id == draft.id }) {
                state.records.append(UploadRecord(draft: draft, automatic: false))
            }
            return nil
        }
    }
    func recordManual(_ draft: Draft) throws {
        let status: QueueStatus = draft.stage == .published ? .published : (draft.stage.mayHavePublished ? .uncertain : .uploading)
        try save(UploadRecord(draft: draft, automatic: false, status: status))
    }
}

@MainActor protocol AlbumAccess {
    var authorizationStatus: PhotosAccessStatus { get }
    func albumName(for id: String) throws -> String
    func requestAccess() async -> Bool
    func albums() throws -> [AlbumChoice]
    func createAlbum() async throws -> String
    func photos(in album: String) async throws -> [LibraryPhoto]
    /// Adds existing library photos to the album. Already-present photos are left alone.
    func add(_ assetIDs: [String], to album: String) async throws
    /// Takes photos out of the album only. The photos stay in the library.
    func remove(_ assetIDs: [String], from album: String) async throws
    /// The same bytes Photos would upload for this photo: its current full-size edited still, or the original when unedited.
    func data(for assetID: String) async throws -> Data
    func thumbnail(for assetID: String, side: CGFloat) async -> UIImage?
    /// Fixtures supply generated identifiers here so tests never open the system photo picker. Nil means use the picker.
    var fixtureSelection: (() -> [String])? { get }
}
extension LibraryPhoto: Identifiable {}
extension AlbumAccess {
    var fixtureSelection: (() -> [String])? { nil }
    /// Fixtures and tests have no real library; history rows fall back to a placeholder.
    func thumbnail(for assetID: String, side: CGFloat) async -> UIImage? { nil }
}
@MainActor protocol UploadNotifying {
    func authorizationStatus() async -> NotificationAccessStatus
    func requestPermission() async
    func notify(id: String, message: String) async
}
struct TransferEvent {
    let jobID: String
    let operation: UUID
    let succeeded: Bool
    let message: String?
}
@MainActor protocol ResourceTransferring {
    var isEnabled: Bool { get }
    func validateEndpoint() async throws
    func enable(cellular: Bool) throws
    func disable() throws
    func events() async throws -> [TransferEvent]
    func submit(_ record: UploadRecord, cellular: Bool) async throws -> Bool
    func acknowledge(_ event: TransferEvent) async throws
    func cancel(operation: UUID) async throws
    func publicURI(for draft: Draft) -> String
}
