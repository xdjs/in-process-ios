import Foundation
import OSLog
import CryptoKit
import Darwin

/// Only closed vocabulary, numbers, booleans and one-way correlation IDs cross
/// this boundary. Never accept free-form messages, URLs, bodies or NSError text.
enum LogEvent: String, Codable {
    case lifecycle, configuration, authCode, authVerify, authRestore, accountLoad, accountRecovery, signOut, authExpiry, authGate, navigation
    case secureLoad, secureSave, secureClear, setup, permission, albumList, albumCreate, albumConnect, albumSelection, consent
    case endpointCheck, extensionEnable, extensionDisable, scan, libraryChange, mediaInventory, queueEnqueue, queueDeduplicate, queueRemove, queueCheckpoint
    case worker, extensionInvocation, extensionTermination, registration, systemJob, acknowledgment, jobCancel, retry, reconciliation
    case serviceStage, network, connectivity, pause, cellular, sessionRecovery, notification, statusRefresh
    case photoPicker, photoPrepare, photoCancel, photoRemove, manualPublish, manualCheckpoint, newDraft, diagnosticsExport
}
enum LogCategory: String, Codable { case app, auth, setup, library, queue, photokit, network, diagnostics }
enum LogLevel: String, Codable { case debug, info, error }
enum LogPhase: String, Codable { case event, begin, end }
enum LogOutcome: String, Codable { case returned, succeeded, failed, canceled, skipped, processing, completed, unavailable }
enum LogField: String, Codable {
    case operation, job, asset, album, invocation, configured, enabled, paused, cellular, online, expensive, authorized, available, expired, shared
    case count, eligible, skippedVideo, skippedOther, unsupported, deduplicated, removed, enqueued, attempts, pending, uploading, published, failed
    case stage, status, reason, errorDomain, errorCode, httpStatus, durationMS, progress, automatic, prompt, consent, existing, retainedFiles, fileFailures
}
enum LogTag: String, Codable {
    case unknown, host, uploadExtension, simulator, full, limited, denied, restricted, notRequested
    case foreground, background, inactive, initialize, home, manual, setup, settingsReturn
    case noConfiguration, busy, leaseBusy, authUnavailable, missingAlbum, permissionDenied, policyBlocked, noEligibleWork, waitingForExtension, alreadyRegistered, unmappedJob
    case registered, systemPending, succeeded
    case draft, pending, uploading, published, failed, canceled, uncertain, uploadingPhoto, uploadingMetadata, ready, submitting
    case authCode, authVerify, artistKeyCreate, artistKeyList, artistKeyRevoke, identity, destination, mediaUpload, metadataUpload, objectReadback, momentSimulate, momentCreate, momentReconcile, endpointPreflight
    case urlError, cocoaError, photosError, keychainError, sessionExpired, cancellation, appError, otherError
    case permissionRequest, notificationSuppressed, notificationDelivered, incidentDeduplicated, configured, photoPrepared, processing, completed, failure
}
enum LogValue: Encodable {
    case flag(Bool), number(Int), tag(LogTag), id(UUID), hash(String)
    static func correlated(_ raw: String) -> LogValue {
        .hash(SHA256.hash(data: Data(raw.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined())
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .flag(let x): try c.encode(x)
        case .number(let x): try c.encode(x)
        case .tag(let x): try c.encode(x.rawValue)
        case .id(let x): try c.encode(x.uuidString)
        // Defense in depth even for an accidental direct .hash(secret) call.
        case .hash(let x): try c.encode(x.count == 24 && x.allSatisfy({ "0123456789abcdef".contains($0) }) ? x : "redacted")
        }
    }
}
struct DiagnosticRecord: Encodable {
    var timestamp: String
    let schema = 1
    let eventID = UUID()
    let role: LogTag
    let lifecycle: UUID
    let build: String
    let event: LogEvent
    let category: LogCategory
    let severity: LogLevel
    let phase: LogPhase
    let span: UUID?
    let parent: UUID?
    let outcome: LogOutcome?
    let fields: [String: LogValue]
}

/// The stable lock inode is never rotated. Independent processes use their own
/// fd and flock. Atomic replacement commits a complete JSONL append, so a killed
/// writer cannot leave a partial trailing record. Export holds the same lock.
struct DiagnosticFile {
    let directory: URL
    var maximumBytes = 512 * 1024
    var generations = 4
    private func file(_ index: Int) -> URL { directory.appendingPathComponent("events-\(index).jsonl") }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var folder = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let path = directory.appendingPathComponent("events.lock")
        let fd = open(path.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path.path)
        // Bounded contention: diagnostics must never stall an upload indefinitely.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN,
                  ProcessInfo.processInfo.systemUptime < deadline else { throw CocoaError(.fileLocking) }
            usleep(1_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    func append(_ record: inout DiagnosticRecord) throws {
        try locked {
            record.timestamp = Self.timestamp()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var line = try encoder.encode(record); line.append(10)
            guard line.count <= maximumBytes, generations > 0 else { throw CocoaError(.fileWriteOutOfSpace) }
            var data = FileManager.default.fileExists(atPath: file(0).path) ? try Data(contentsOf: file(0)) : Data()
            if data.count + line.count > maximumBytes {
                for i in stride(from: generations - 1, through: 1, by: -1) {
                    if FileManager.default.fileExists(atPath: file(i - 1).path) {
                        // Copy-before-delete: a crash during rotation can duplicate
                        // history, never lose the newest committed generation.
                        let old = try Data(contentsOf: file(i - 1))
                        try old.write(to: file(i), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    }
                }
                data = Data()
            }
            data.append(line)
            try data.write(to: file(0), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
    func snapshot() throws -> Data {
        try locked {
            var result = Data()
            for i in (0..<generations).reversed() where FileManager.default.fileExists(atPath: file(i).path) {
                result.append(try Data(contentsOf: file(i)))
            }
            return result
        }
    }
    static func timestamp() -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date()) // UTC Z, including milliseconds.
    }
}

final class DevelopmentLog: @unchecked Sendable {
    @TaskLocal static var parentSpan: UUID?
    static let shared: DevelopmentLog = {
        #if DEBUG
        let isolated = NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--ui-test-") })
        let root = isolated ? FileManager.default.temporaryDirectory.appendingPathComponent("isolated-diagnostics-\(UUID())") :
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.xdjs.InProcess")?.appendingPathComponent("DevelopmentDiagnostics")
        return DevelopmentLog(file: root.map { DiagnosticFile(directory: $0) }, role: Bundle.main.bundleURL.pathExtension == "appex" ? .uploadExtension : .host)
        #else
        return DevelopmentLog(file: nil, role: .host, enabled: false)
        #endif
    }()
    let file: DiagnosticFile?
    let role: LogTag
    let lifecycle = UUID()
    let enabled: Bool
    private let failureLock = NSLock()
    private var failures = 0
    var fileFailures: Int { failureLock.withLock { failures } }
    init(file: DiagnosticFile?, role: LogTag, enabled: Bool = true) { self.file = file; self.role = role; self.enabled = enabled }
    func emit(_ event: LogEvent, _ category: LogCategory = .app, _ fields: [LogField: LogValue] = [:],
              level: LogLevel = .info, phase: LogPhase = .event, span: UUID? = nil, outcome: LogOutcome? = nil, parent: UUID? = DevelopmentLog.parentSpan) {
        guard enabled else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let safeBuild = (version + "/" + build).filter { "0123456789./".contains($0) }.prefix(40)
        var record = DiagnosticRecord(timestamp: DiagnosticFile.timestamp(), role: role, lifecycle: lifecycle, build: String(safeBuild),
            event: event, category: category, severity: level, phase: phase, span: span, parent: parent, outcome: outcome,
            fields: Dictionary(uniqueKeysWithValues: fields.map { ($0.key.rawValue, $0.value) }))
        if let file {
            do { try file.append(&record) }
            catch { failureLock.withLock { failures += 1 } } // Never recurse or propagate.
        } else { failureLock.withLock { failures += 1 } }
        guard let data = try? JSONEncoder().encode(record), let text = String(data: data, encoding: .utf8) else { return }
        let logger = Logger(subsystem: "com.xdjs.InProcess", category: category.rawValue)
        switch level {
        case .debug: logger.debug("\(text, privacy: .public)")
        case .info: logger.info("\(text, privacy: .public)")
        case .error: logger.error("\(text, privacy: .public)")
        }
    }
    func begin(_ event: LogEvent, _ category: LogCategory = .app, _ fields: [LogField: LogValue] = [:]) -> DiagnosticSpan {
        DiagnosticSpan(log: self, event: event, category: category, fields: fields)
    }
    static func safeError(_ error: Error) -> [LogField: LogValue] {
        let ns = error as NSError
        let tag: LogTag
        if error is CancellationError { tag = .cancellation }
        else if case AppError.sessionExpired = error { tag = .sessionExpired }
        else if error is KeychainFailure { tag = .keychainError }
        else if error is AppError { tag = .appError }
        else {
            switch ns.domain {
            case NSURLErrorDomain: tag = .urlError
            case NSCocoaErrorDomain: tag = .cocoaError
            case "PHPhotosErrorDomain": tag = .photosError
            default: tag = .otherError
            }
        }
        return [.errorDomain: .tag(tag), .errorCode: .number((error as? KeychainFailure).map { Int($0.status) } ?? ns.code)]
    }
    /// Read-only snapshot of BOTH processes. Never reads queue/session/config.
    /// Fixed destination bounds exported history to one <= 2 MiB snapshot.
    func export(to directory: URL) throws -> URL {
        let span = begin(.diagnosticsExport, .diagnostics)
        do {
            guard let file else { throw CocoaError(.fileNoSuchFile) }
            let data = try file.snapshot()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var folder = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true; try folder.setResourceValues(values)
            let url = directory.appendingPathComponent("InProcess-Diagnostics.jsonl")
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            span.end(.succeeded, [.fileFailures: .number(fileFailures)])
            return url
        } catch { span.fail(error); throw error }
    }
}
final class DiagnosticSpan {
    let id = UUID()
    let log: DevelopmentLog
    let event: LogEvent
    let category: LogCategory
    private let parent = DevelopmentLog.parentSpan
    private let start = ProcessInfo.processInfo.systemUptime
    private var ended = false
    init(log: DevelopmentLog, event: LogEvent, category: LogCategory, fields: [LogField: LogValue]) {
        self.log = log; self.event = event; self.category = category
        log.emit(event, category, fields, phase: .begin, span: id)
    }
    func end(_ outcome: LogOutcome = .returned, _ fields: [LogField: LogValue] = [:]) {
        guard !ended else { return }; ended = true
        var values = fields; values[.durationMS] = .number(Int((ProcessInfo.processInfo.systemUptime - start) * 1000))
        log.emit(event, category, values, level: outcome == .failed ? .error : .info, phase: .end, span: id, outcome: outcome, parent: parent)
    }
    func fail(_ error: Error) { end(error is CancellationError ? .canceled : .failed, DevelopmentLog.safeError(error)) }
    deinit { if !ended { end(.returned) } }
}

extension DevelopmentLog {
    func trace<T>(_ event: LogEvent, _ category: LogCategory = .app,
                            _ fields: [LogField: LogValue] = [:], body: () async throws -> T) async rethrows -> T {
        let span = begin(event, category, fields)
        return try await Self.$parentSpan.withValue(span.id) {
            do { let value = try await body(); span.end(.succeeded); return value }
            catch { span.fail(error); throw error }
        }
    }
    func trace<T>(_ event: LogEvent, _ category: LogCategory = .app,
                            _ fields: [LogField: LogValue] = [:], body: () throws -> T) rethrows -> T {
        let span = begin(event, category, fields)
        return try Self.$parentSpan.withValue(span.id) {
            do { let value = try body(); span.end(.succeeded); return value }
            catch { span.fail(error); throw error }
        }
    }
    /// For UI/coordinator methods that handle errors internally, `returned` is
    /// deliberately NOT success. The outcome fields and child error describe it.
    @MainActor func action<T>(_ event: LogEvent, _ category: LogCategory = .app,
                             fields: [LogField: LogValue] = [:], outcome: () -> [LogField: LogValue] = { [:] },
                             body: () async -> T) async -> T {
        let span = begin(event, category, fields)
        return await Self.$parentSpan.withValue(span.id) {
            let value = await body(); span.end(Task.isCancelled ? .canceled : .returned, outcome()); return value
        }
    }
    @MainActor func action<T>(_ event: LogEvent, _ category: LogCategory = .app,
                             fields: [LogField: LogValue] = [:], outcome: () -> [LogField: LogValue] = { [:] },
                             body: () -> T) -> T {
        let span = begin(event, category, fields)
        return Self.$parentSpan.withValue(span.id) {
            let value = body(); span.end(.returned, outcome()); return value
        }
    }
}
