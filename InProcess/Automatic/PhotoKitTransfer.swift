import Photos
import Foundation

@MainActor final class PhotoKitTransfer: ResourceTransferring {
    let api: InProcessAPI
    let runsInExtension: Bool
    var isEnabled: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        // Touching the library before a permission decision can raise the Photos prompt at launch.
        PHPhotoLibrary.authorizationStatus(for: .readWrite) != .notDetermined && PHPhotoLibrary.shared().uploadJobExtensionEnabled
        #endif
    }
    init(api: InProcessAPI, runsInExtension: Bool = false) { self.api = api; self.runsInExtension = runsInExtension }
    func request(for draft: Draft, cellular: Bool) -> URLRequest {
        Self.makeRequest(base: api.storageURL, bucket: api.bucket, key: api.storageKey, draft: draft, cellular: cellular)
    }
    static func makeRequest(base: URL, bucket: String, key: String, draft: Draft, cellular: Bool) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent("storage/v1/object/\(bucket)/\(draft.mediaObject)"))
        request.httpMethod = "POST"
        request.setValue(draft.mime, forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("false", forHTTPHeaderField: "x-upsert")
        request.allowsCellularAccess = cellular; request.allowsExpensiveNetworkAccess = cellular
        return request
    }
    static func acceptsPreflight(status: Int, uploadLimit: String?) -> Bool {
        // A 200 + limit is only capability advertisement. Actual 104/resumption
        // and the 501 fallback still require a device integration test.
        status == 501 || (status == 200 && (uploadLimit.flatMap(Int64.init) ?? 0) > 0)
    }
    static func acceptsEndpointPreflight(upload: URLRequest, response: HTTPURLResponse) -> Bool {
        guard let url = upload.url, url.scheme == "https", response.url == url,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port == nil || url.port == 443,
              upload.httpMethod == "POST",
              let key = upload.value(forHTTPHeaderField: "apikey"), !key.isEmpty,
              upload.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)",
              upload.value(forHTTPHeaderField: "x-upsert") == "false",
              let mime = upload.value(forHTTPHeaderField: "Content-Type"),
              ["image/jpeg", "image/png", "image/heic"].contains(mime) else { return false }
        let limit = response.value(forHTTPHeaderField: "Upload-Limit")
        if acceptsPreflight(status: response.statusCode, uploadLimit: limit) { return true }

        // This exact service/bucket completed three actual iOS 27.2 PhotoKit
        // jobs despite OPTIONS 200 without Upload-Limit, with matching readback
        // bytes (including a locked-phone run). See photokit-server-requirements.md.
        // This is a pinned compatibility exception, not a resumability claim.
        guard response.statusCode == 200, limit == nil,
              url.host == "zzgteesackezhtnuqfyw.supabase.co" else { return false }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 5,
              Array(components.prefix(4)) == ["storage", "v1", "object", "in_process_files"] else { return false }
        let file = url.lastPathComponent
        let extensions = ["image/jpeg": ["jpg", "jpeg"], "image/png": ["png"], "image/heic": ["heic"]]
        guard UUID(uuidString: String(file.prefix(36))) != nil,
              extensions[mime]?.contains(url.pathExtension) == true else { return false }
        return String(file.dropFirst(36)) == "-photo.\(url.pathExtension)"
    }
    func validateEndpoint() async throws {
        return try await DevelopmentLog.shared.trace(.endpointCheck, .photokit) {
            let sample = Draft(owner: "", destination: Destination(address: "", name: "", chain_id: 8453))
            let upload = request(for: sample, cellular: true)
            var preflight = upload; preflight.httpMethod = "OPTIONS"
            let (_, response) = try await api.loggedData(for: preflight, stage: .endpointPreflight)
            guard let http = response as? HTTPURLResponse,
                  Self.acceptsEndpointPreflight(upload: upload, response: http) else {
                throw AppError.message("Automatic uploads need a compatible server response before they can be enabled. Manual upload is available. The upload endpoint has not passed the Photos background-transfer check.")
            }
        }
    }
    func enable(cellular: Bool) throws {
        return try DevelopmentLog.shared.trace(.extensionEnable, .photokit) {
            DevelopmentLog.shared.emit(.extensionEnable, .photokit, [.cellular: .flag(cellular), .enabled: .flag(isEnabled)])
            #if targetEnvironment(simulator)
            throw AppError.message("Photos background transfers require a physical iPhone. The simulator can test the app using isolated fixtures.")
            #else
            let options = PHAssetResourceUploadJobOptions(); options.preventsExpensiveNetworkAccess = !cellular
            if PHPhotoLibrary.shared().uploadJobExtensionEnabled {
                try PHPhotoLibrary.shared().setUploadJobExtensionOptions(options)
            } else { try PHPhotoLibrary.shared().enableUploadJobExtension(with: options) }
            #endif
        }
    }
    func disable() throws {
        return try DevelopmentLog.shared.trace(.extensionDisable, .photokit) {
            #if !targetEnvironment(simulator)
            if PHPhotoLibrary.shared().uploadJobExtensionEnabled { try PHPhotoLibrary.shared().disableUploadJobExtension() }
            #endif
        }
    }
    func publicURI(for draft: Draft) -> String {
        api.storageURL.appendingPathComponent("storage/v1/object/public/\(api.bucket)/\(draft.mediaObject)").absoluteString
    }
    private static func stateTag(_ state: PHAssetResourceUploadJob.State) -> LogTag {
        switch state {
        case .registered: .registered
        case .pending: .systemPending
        case .failed: .failed
        case .succeeded: .succeeded
        case .cancelled: .canceled
        @unknown default: .unknown
        }
    }
    private func jobs(_ action: PHAssetResourceUploadJob.Action) -> [PHAssetResourceUploadJob] {
        let result = PHAssetResourceUploadJob.fetchJobs(action: action, options: nil)
        return (0..<result.count).map { result.object(at: $0) }
    }
    private func operation(_ job: PHAssetResourceUploadJob) -> UUID? {
        guard let url = job.destination.url, url.host == api.storageURL.host,
              url.path.hasPrefix("/storage/v1/object/\(api.bucket)/") else { return nil }
        let name = url.lastPathComponent
        guard name.count > 36, name.dropFirst(36).hasPrefix("-photo.") else { return nil }
        return UUID(uuidString: String(name.prefix(36)))
    }
    func events() async throws -> [TransferEvent] {
        return try await DevelopmentLog.shared.trace(.systemJob, .photokit) {
            guard runsInExtension else { DevelopmentLog.shared.emit(.systemJob, .photokit, [.reason: .tag(.waitingForExtension)]); return [] }
            for job in jobs(.process) {
                DevelopmentLog.shared.emit(.systemJob, .photokit, [.job: .correlated(job.localIdentifier), .operation: operation(job).map(LogValue.id) ?? .tag(.unmappedJob), .status: .tag(Self.stateTag(job.state))])
            }
            var result: [TransferEvent] = []
            for job in jobs(.acknowledge) {
                guard let operation = operation(job) else { DevelopmentLog.shared.emit(.systemJob, .photokit, [.reason: .tag(.unmappedJob)]); continue }
                var fields: [LogField: LogValue] = [.operation: .id(operation), .job: .correlated(job.localIdentifier), .status: .tag(Self.stateTag(job.state))]
                if let error = job.error { fields.merge(DevelopmentLog.safeError(error)) { _, new in new } }
                DevelopmentLog.shared.emit(.systemJob, .photokit, fields)
                var succeeded = job.state == .succeeded
                if !succeeded, let resource = PHAssetResource.assetResource(forUploadJob: job),
                   let bytes = try? await PhotosAlbumAccess.resourceData(resource, networkAllowed: false),
                   let uploadURL = job.destination.url {
                    // A failed response may follow a completed write. Compare the actual
                    // job resource, never a subsequently edited asset, before recovering.
                    let publicURL = api.storageURL.appendingPathComponent("storage/v1/object/public/\(api.bucket)/\(uploadURL.lastPathComponent)")
                    succeeded = (try? await api.existingObject(publicURL, equals: bytes)) == true
                }
                result.append(TransferEvent(jobID: job.localIdentifier, operation: operation,
                    succeeded: succeeded, message: job.error == nil ? nil : "Photos could not complete the transfer. Retry when connected; no Moment has been created by this transfer."))
            }
            return result
        }
    }

    func submit(_ record: UploadRecord, cellular: Bool) async throws -> Bool {
        return try await DevelopmentLog.shared.trace(.registration, .photokit) {
            guard runsInExtension else { throw AppError.message("Waiting for Photos to schedule the upload extension.") }
            // Recover a registration that succeeded before the process saved/returned.
            if let job = (jobs(.process) + jobs(.acknowledge)).first(where: { operation($0) == record.id }) {
                DevelopmentLog.shared.emit(.registration, .photokit, [.operation: .id(record.id), .job: .correlated(job.localIdentifier), .reason: .tag(.alreadyRegistered)]); return false
            }
            guard let id = record.draft.sourceAssetID else { throw AppError.message("The source photo identifier is missing.") }
            let asset = try PhotosAlbumAccess.asset(id)
            let revision = String(asset.modificationDate?.timeIntervalSince1970 ?? asset.creationDate?.timeIntervalSince1970 ?? 0)
            guard revision == record.revision else { throw AppError.message("The photo changed after preparation. Its previous operation has been kept for checking.") }
            let resource = try PhotosAlbumAccess.resource(asset)
            let format = try PhotoProcessor.format(resource.uniformTypeIdentifier)
            guard format.mime == record.draft.mime else { throw AppError.message("The photo’s format changed after preparation.") }
            DevelopmentLog.shared.emit(.registration, .photokit, [.operation: .id(record.id), .cellular: .flag(cellular)])
            let destination = request(for: record.draft, cellular: cellular)
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetResourceUploadJobChangeRequest.creationRequestForJob(destination: destination, resource: resource)
            }
            for job in jobs(.process) where operation(job) == record.id {
                DevelopmentLog.shared.emit(.registration, .photokit, [.operation: .id(record.id), .job: .correlated(job.localIdentifier), .status: .tag(Self.stateTag(job.state))])
            }
            return true
        }
    }
    func acknowledge(_ event: TransferEvent) async throws {
        return try await DevelopmentLog.shared.trace(.acknowledgment, .photokit) {
            guard runsInExtension, let job = jobs(.acknowledge).first(where: { $0.localIdentifier == event.jobID }) else { return }
            DevelopmentLog.shared.emit(.acknowledgment, .photokit, [.operation: .id(event.operation), .job: .correlated(event.jobID)])
            try await PHPhotoLibrary.shared().performChanges { PHAssetResourceUploadJobChangeRequest(for: job)?.acknowledge() }
        }
    }
    func cancel(operation id: UUID) async throws {
        return try await DevelopmentLog.shared.trace(.jobCancel, .photokit) {
            guard runsInExtension else { return }
            for job in jobs(.process) where operation(job) == id {
                try await PHPhotoLibrary.shared().performChanges { PHAssetResourceUploadJobChangeRequest(for: job)?.cancel() }
            }
        }
    }
}
