import Foundation

protocol InProcessServing {
    func createArtistKey(name: String, bootstrap: APICredential) async throws -> String
    func artistKeys(token: APICredential) async throws -> [ArtistKeyRecord]
    func revokeArtistKey(id: String, token: APICredential) async throws
    func sendCode(email: String) async throws
    func login(email: String, code: String) async throws -> LoginResponse
    func identity(token: APICredential) async throws -> Identity
    func destination(token: APICredential) async throws -> Destination
    func upload(data: Data, object: String, contentType: String) async throws -> String
    func simulate(_ request: CreateMomentRequest, token: APICredential) async throws
    func create(_ request: CreateMomentRequest, token: APICredential) async throws -> Publication
    func reconcile(_ draft: Draft, token: APICredential) async throws -> Publication?
}

extension InProcessServing {
    func artistKeys(token: APICredential) async throws -> [ArtistKeyRecord] { throw CredentialSetupError.retry }
    func revokeArtistKey(id: String, token: APICredential) async throws { throw CredentialSetupError.retry }
    func createArtistKey(name: String, bootstrap: APICredential) async throws -> String {
        throw AppError.message("This service cannot create a sign-in key.")
    }
}

enum KeyIssuanceError: Error { case notCreated(Int), uncertain }
struct ArtistKeyRecord: Decodable, Equatable { let id: String; let name: String }

struct InProcessAPI: InProcessServing {
    // Auth headers and key-creation responses must never enter an on-disk
    // URL cache, cookie jar, or credential store. Keychain is the durable owner.
    static var credentialNetworkConfiguration: URLSessionConfiguration {
        let value = URLSessionConfiguration.ephemeral
        value.urlCache = nil; value.httpCookieStorage = nil; value.urlCredentialStorage = nil
        value.requestCachePolicy = .reloadIgnoringLocalCacheData
        return value
    }
    private static let liveSession = URLSession(configuration: credentialNetworkConfiguration)
    let session: URLSession
    let baseURL: URL
    let storageURL: URL
    let storageKey: String
    let bucket: String
    let networkPolicy: (() -> Bool)?

    // Explicitly isolated transport tests; never reads production configuration.
    init(testSession: URLSession, baseURL: URL) throws {
        guard baseURL.host?.hasSuffix(".invalid") == true else { throw AppError.message("Tests require an isolated service.") }
        self.session = testSession; self.baseURL = baseURL; self.storageURL = baseURL
        self.storageKey = "synthetic-public-only"; self.bucket = "fixture"; self.networkPolicy = nil
    }

    init(session: URLSession? = nil, networkPolicy: (() -> Bool)? = nil) throws {
        // Fail closed if the UI fixture is accidentally wired to the live service.
        guard !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--ui-test-") }) else {
            throw AppError.message("Live services are disabled during the publishing UI test.")
        }
        guard NSClassFromString("XCTestCase") == nil,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            throw AppError.message("Live services are disabled in every unit-test host, including physical devices.")
        }
        guard !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--album-wake-probe") }) else {
            throw AppError.message("Live services are disabled during the non-publishing wake diagnostic.")
        }
        #if DEBUG
        guard try !AlbumWakeProbeStorage.isArmed() else { throw AppError.message("Live services are disabled while the wake diagnostic is armed.") }
        #endif
        guard let file = Bundle.main.url(forResource: "ServiceConfig", withExtension: "plist"),
              let config = NSDictionary(contentsOf: file),
              let urlString = config["StorageURL"] as? String,
              let storageURL = URL(string: urlString), storageURL.scheme == "https",
              let key = config["StoragePublicKey"] as? String,
              let bucket = config["StorageBucket"] as? String else {
            throw AppError.message("The In Process service configuration is missing.")
        }
        self.networkPolicy = networkPolicy
        self.session = session ?? Self.liveSession; baseURL = URL(string: "https://api.inprocess.world/api")!
        self.storageURL = storageURL; storageKey = key; self.bucket = bucket
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil, token: APICredential? = nil, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        restrictNetwork(&request)
        request.httpMethod = method; request.httpBody = body
        request.timeoutInterval = method == "GET" ? 30 : 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        token?.authorize(&request)
        return request
    }

    private func restrictNetwork(_ request: inout URLRequest) {
        request.allowsCellularAccess = networkPolicy?() ?? true
        request.allowsExpensiveNetworkAccess = request.allowsCellularAccess
    }
    func loggedData(for request: URLRequest, stage: LogTag) async throws -> (Data, URLResponse) {
        let span = DevelopmentLog.shared.begin(.network, .network, [.stage: .tag(stage), .cellular: .flag(request.allowsCellularAccess)])
        do {
            let result = try await session.data(for: request)
            let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
            span.end((200..<300).contains(status) ? .succeeded : .failed, [.httpStatus: .number(status), .stage: .tag(stage)])
            return result
        } catch { span.fail(error); throw error }
    }
    private func send(_ request: URLRequest, stage: LogTag) async throws -> Data {
        let (data, response) = try await loggedData(for: request, stage: stage)
        guard let http = response as? HTTPURLResponse else { throw AppError.message("The service returned an unreadable response.") }
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401: throw AppError.sessionExpired
            case 403 where stage == .identity || stage == .destination: throw AppError.sessionExpired
            case 403: throw AppError.message("This account is not allowed to perform that action. Your draft is saved.")
            case 402: throw AppError.message("In Process could not cover this upload. Your draft is saved. Please try again later.")
            case 429: throw AppError.message("Too many requests. Wait a minute before trying again.")
            case 400, 422: throw AppError.message("The service could not accept this request. Check your details and try again.")
            default: throw AppError.message("In Process is unavailable (\(http.statusCode)). Your draft is saved.")
            }
        }
        return data
    }
    private func body(_ object: [String: String]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    func artistKeys(token: APICredential) async throws -> [ArtistKeyRecord] {
        struct Response: Decodable { let keys: [ArtistKeyRecord] }
        return try JSONDecoder().decode(Response.self, from: await send(request("artists/api-keys", token: token), stage: .artistKeyList)).keys
    }
    func revokeArtistKey(id: String, token: APICredential) async throws {
        guard UUID(uuidString: id) != nil else { throw CredentialSetupError.mismatch }
        _ = try await send(request("artists/api-keys", method: "DELETE", token: token, query: [.init(name: "keyId", value: id)]), stage: .artistKeyRevoke)
    }
    func createArtistKey(name: String, bootstrap: APICredential) async throws -> String {
        guard bootstrap.kind == .bearer else { throw KeyIssuanceError.notCreated(400) }
        let request = request("artists/api-keys", method: "POST", body: try body(["key_name": name]), token: bootstrap)
        let (data, response) = try await loggedData(for: request, stage: .artistKeyCreate)
        guard let http = response as? HTTPURLResponse else { throw KeyIssuanceError.uncertain }
        if [400, 401, 403, 422, 429].contains(http.statusCode) { throw KeyIssuanceError.notCreated(http.statusCode) }
        struct Response: Decodable { let key: String }
        guard (200..<300).contains(http.statusCode), let value = try? JSONDecoder().decode(Response.self, from: data),
              value.key.hasPrefix("art_sk_"), value.key.count > 16 else { throw KeyIssuanceError.uncertain }
        return value.key
    }
    func sendCode(email: String) async throws { _ = try await send(request("oauth/code", method: "POST", body: body(["email": email])), stage: .authCode) }
    func login(email: String, code: String) async throws -> LoginResponse {
        do {
            return try JSONDecoder().decode(LoginResponse.self, from: await send(request("oauth/login", method: "POST", body: body(["email": email, "code": code])), stage: .authVerify))
        } catch AppError.sessionExpired { throw AppError.message("That code is incorrect or expired. Try again or request a new code.") }
    }
    func identity(token: APICredential) async throws -> Identity {
        try JSONDecoder().decode(Identity.self, from: await send(request("oauth", token: token), stage: .identity))
    }
    func destination(token: APICredential) async throws -> Destination {
        try JSONDecoder().decode(Destination.self, from: await send(request("collections/default", token: token), stage: .destination))
    }

    func upload(data: Data, object: String, contentType: String) async throws -> String {
        let publicURL = storageURL.appendingPathComponent("storage/v1/object/public/\(bucket)/\(object)")
        // Stable, unique paths make an interrupted transfer recoverable without
        // overwriting an object. Read and compare bytes before attempting a retry.
        if try await existingObject(publicURL, equals: data) { return publicURL.absoluteString }
        var request = URLRequest(url: storageURL.appendingPathComponent("storage/v1/object/\(bucket)/\(object)"))
        restrictNetwork(&request)
        request.httpMethod = "POST"; request.httpBody = data; request.timeoutInterval = 120
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(storageKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(storageKey)", forHTTPHeaderField: "Authorization")
        request.setValue("false", forHTTPHeaderField: "x-upsert")
        let (_, response) = try await loggedData(for: request, stage: contentType == "application/json" ? .metadataUpload : .mediaUpload)
        guard let http = response as? HTTPURLResponse else { throw AppError.message("The upload response was interrupted. Your draft is saved.") }
        if (200..<300).contains(http.statusCode) { return publicURL.absoluteString }
        if [400, 409].contains(http.statusCode), try await existingObject(publicURL, equals: data) { return publicURL.absoluteString }
        throw AppError.message("Photo storage is unavailable (\(http.statusCode)). Your draft is saved. No funding is needed in this app.")
    }
    func existingObject(_ url: URL, equals expected: Data) async throws -> Bool {
        var request = URLRequest(url: url); restrictNetwork(&request); request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await loggedData(for: request, stage: .objectReadback)
        guard let http = response as? HTTPURLResponse else { throw AppError.message("Could not check the saved upload.") }
        if http.statusCode == 200 {
            guard data == expected else { throw AppError.message("The saved upload does not match this draft. Publication has been stopped.") }
            return true
        }
        // Supabase public object reads use 400 for a missing object as well as 404.
        if http.statusCode == 404 { return false }
        if http.statusCode == 400,
           let error = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           ["not_found", "Object not found"].contains(error["error"] as? String ?? "") { return false }
        throw AppError.message("Could not check photo storage (\(http.statusCode)). Try again later.")
    }
    func simulate(_ value: CreateMomentRequest, token: APICredential) async throws {
        struct Response: Decodable { struct Simulation: Decodable { let success: Bool }; let contractSimulation: Simulation }
        let data = try await send(request("moment/create/simulate", method: "POST", body: JSONEncoder().encode(value), token: token), stage: .momentSimulate)
        guard try JSONDecoder().decode(Response.self, from: data).contractSimulation.success else {
            throw AppError.message("In Process could not prepare this Moment. Your draft is saved.")
        }
    }
    func create(_ value: CreateMomentRequest, token: APICredential) async throws -> Publication {
        // Deliberately one request. There is no documented server idempotency key.
        let data = try await send(request("moment/create", method: "POST", body: JSONEncoder().encode(value), token: token), stage: .momentCreate)
        return try JSONDecoder().decode(Publication.self, from: data)
    }
    func reconcile(_ draft: Draft, token: APICredential) async throws -> Publication? {
        guard let uri = draft.metadataURI else { return nil }
        for page in 1...10 {
            let query: [URLQueryItem] = [.init(name: "artist", value: draft.owner), .init(name: "collection", value: draft.destination.address),
                .init(name: "chain_id", value: "8453"), .init(name: "limit", value: "100"), .init(name: "page", value: String(page)), .init(name: "hidden", value: "true")]
            let data = try await send(request("timeline", token: token, query: query), stage: .momentReconcile)
            let response = try JSONDecoder().decode(TimelineResponse.self, from: data)
            if let found = response.moments.first(where: {
                $0.uri == uri && $0.address.lowercased() == draft.destination.address.lowercased() &&
                $0.chain_id == 8453 && $0.creator?.address.lowercased() == draft.owner.lowercased()
            }) {
                return Publication(contractAddress: found.address, tokenId: found.token_id, hash: nil, chainId: found.chain_id)
            }
            if page >= response.pagination.total_pages { break }
        }
        // Absence is not proof of failure: indexing may be delayed. Never resubmit.
        return nil
    }
}
