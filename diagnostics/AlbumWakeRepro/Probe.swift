import Foundation
import Photos
import OSLog

// This target has its own App Group. No production source or container is used.
enum ProbeError: Error { case physicalDevice, authorization, missingGroup, missingAlbum, historyLimit, emptyAlbumRequired }
struct ProbeConfiguration: Codable {
    let albumID: String
    var baseline: Data?
}
struct ProbeEvent: Codable {
    let time: Date
    let process: UUID
    let role: String
    let event: String
    var members: Int?
    var history: Int?
    var inserted: Int?
    var updated: Int?
    var deleted: Int?
    var albumChanged: Bool?
    var enabled: Bool?
    var errorCode: Int?
}
final class ProbeLog: @unchecked Sendable {
    static let shared = ProbeLog()
    let process = UUID()
    private let lock = NSLock()
    private var count = 0
    private var failures = 0
    private let logger = Logger(subsystem: "com.xdjs.AlbumWakeRepro", category: "wake")
    #if WAKE_EXTENSION
    let role = "extension"
    #else
    let role = "host"
    #endif
    func emit(_ event: String, members: Int? = nil, history: Int? = nil,
              inserted: Int? = nil, updated: Int? = nil, deleted: Int? = nil,
              albumChanged: Bool? = nil, enabled: Bool? = nil, errorCode: Int? = nil) {
        let record = ProbeEvent(time: Date(), process: process, role: role, event: event,
            members: members, history: history, inserted: inserted, updated: updated,
            deleted: deleted, albumChanged: albumChanged, enabled: enabled, errorCode: errorCode)
        lock.lock(); defer { lock.unlock() }
        do {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(record) + Data([10])
            logger.notice("\(String(decoding: data, as: UTF8.self), privacy: .public)")
            guard count < 1000 else { return }; count += 1
            let url = try Probe.directory().appendingPathComponent("\(role)-\(process).jsonl")
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } else {
                let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: data)
            }
        } catch { failures += 1; logger.error("diagnostic file-write failures: \(self.failures)") }
    }
    func export() throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(at: Probe.directory(), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
        guard files.count <= 100 else { throw ProbeError.historyLimit }
        var lines = [String]()
        for file in files {
            let data = try Data(contentsOf: file)
            guard data.count <= 1_000_000 else { throw ProbeError.historyLimit }
            // Each process writes its own file. Ignore only an incomplete trailing line.
            let parts = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            lines += parts.dropLast()
        }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("WakeEvents.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
enum Probe {
    static func physical() throws {
        #if targetEnvironment(simulator)
        throw ProbeError.physicalDevice
        #else
        guard NSClassFromString("XCTestCase") == nil else { throw ProbeError.physicalDevice }
        #endif
    }
    static func directory() throws -> URL {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.xdjs.AlbumWakeRepro") else { throw ProbeError.missingGroup }
        let dir = group.appendingPathComponent("WakeRepro", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static func read() throws -> ProbeConfiguration {
        try JSONDecoder().decode(ProbeConfiguration.self, from: Data(contentsOf: directory().appendingPathComponent("configuration.json")))
    }
    static func save(_ config: ProbeConfiguration) throws {
        try JSONEncoder().encode(config).write(to: directory().appendingPathComponent("configuration.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func album(_ config: ProbeConfiguration) throws -> PHAssetCollection {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { throw ProbeError.authorization }
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [config.albumID], options: nil).firstObject else { throw ProbeError.missingAlbum }
        return album
    }
    static func snapshot() throws -> Int {
        try physical()
        let config = try read(), collection = try album(config)
        let members = PHAsset.fetchAssets(in: collection, options: nil).count
        var inserted = Set<String>(), updated = Set<String>(), deleted = Set<String>()
        var changed = false, count = 0
        if let data = config.baseline,
           let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data) {
            for change in try PHPhotoLibrary.shared().fetchPersistentChanges(since: token) {
                guard count < 1000 else { throw ProbeError.historyLimit }; count += 1
                let assets = try change.changeDetails(for: .asset)
                inserted.formUnion(assets.insertedLocalIdentifiers)
                updated.formUnion(assets.updatedLocalIdentifiers)
                deleted.formUnion(assets.deletedLocalIdentifiers)
                let albums = try change.changeDetails(for: .assetCollection)
                changed = changed || albums.insertedLocalIdentifiers.contains(config.albumID)
                    || albums.updatedLocalIdentifiers.contains(config.albumID) || albums.deletedLocalIdentifiers.contains(config.albumID)
            }
        }
        ProbeLog.shared.emit("snapshot", members: members, history: count, inserted: inserted.count,
            updated: updated.count, deleted: deleted.count, albumChanged: changed,
            enabled: PHPhotoLibrary.shared().uploadJobExtensionEnabled)
        return members
    }
}
