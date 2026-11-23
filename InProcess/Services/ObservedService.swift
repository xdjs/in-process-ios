import Foundation

/// Semantic stages are recorded even with isolated test adapters. The real API
/// separately logs transport status/duration, without serializing requests.
struct ObservedService: InProcessServing {
    let base: any InProcessServing
    let log: DevelopmentLog
    func artistKeys(token: APICredential) async throws -> [ArtistKeyRecord] {
        try await log.trace(.serviceStage, .auth, [.stage: .tag(.artistKeyList)]) { try await base.artistKeys(token: token) }
    }
    func revokeArtistKey(id: String, token: APICredential) async throws {
        try await log.trace(.serviceStage, .auth, [.stage: .tag(.artistKeyRevoke)]) { try await base.revokeArtistKey(id: id, token: token) }
    }
    func createArtistKey(name: String, bootstrap: APICredential) async throws -> String {
        try await log.trace(.serviceStage, .auth, [.stage: .tag(.artistKeyCreate)]) {
            try await base.createArtistKey(name: name, bootstrap: bootstrap)
        }
    }
    func sendCode(email: String) async throws {
        try await log.trace(.serviceStage, .auth, [.stage: .tag(.authCode)]) { try await base.sendCode(email: email) }
    }
    func login(email: String, code: String) async throws -> LoginResponse {
        try await log.trace(.serviceStage, .auth, [.stage: .tag(.authVerify)]) { try await base.login(email: email, code: code) }
    }
    func identity(token: APICredential) async throws -> Identity {
        try await log.trace(.serviceStage, .auth, [.stage: .tag(.identity)]) { try await base.identity(token: token) }
    }
    func destination(token: APICredential) async throws -> Destination {
        try await log.trace(.serviceStage, .auth, [.stage: .tag(.destination)]) { try await base.destination(token: token) }
    }
    func upload(data: Data, object: String, contentType: String) async throws -> String {
        try await log.trace(.serviceStage, .network, [.stage: .tag(contentType == "application/json" ? .metadataUpload : .mediaUpload),
            .operation: UUID(uuidString: String(object.prefix(36))).map(LogValue.id) ?? .tag(.unknown)]) {
            try await base.upload(data: data, object: object, contentType: contentType)
        }
    }
    func simulate(_ request: CreateMomentRequest, token: APICredential) async throws {
        try await log.trace(.serviceStage, .network, [.stage: .tag(.momentSimulate)]) { try await base.simulate(request, token: token) }
    }
    func create(_ request: CreateMomentRequest, token: APICredential) async throws -> Publication {
        try await log.trace(.serviceStage, .network, [.stage: .tag(.momentCreate)]) { try await base.create(request, token: token) }
    }
    func reconcile(_ draft: Draft, token: APICredential) async throws -> Publication? {
        try await log.trace(.serviceStage, .network, [.stage: .tag(.momentReconcile), .operation: .id(draft.id)]) {
            let result = try await base.reconcile(draft, token: token)
            log.emit(.reconciliation, .queue, [.operation: .id(draft.id), .available: .flag(result != nil)])
            return result
        }
    }
}
