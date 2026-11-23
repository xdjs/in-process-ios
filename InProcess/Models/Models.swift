import Foundation

enum AppError: LocalizedError {
    case message(String)
    case sessionExpired
    var errorDescription: String? {
        switch self {
        case .message(let text): text
        case .sessionExpired: "Your sign-in is no longer valid. Sign in again; your draft is saved."
        }
    }
}

struct LoginResponse: Decodable { let token: String; let social_wallet: String }
struct Identity: Codable, Equatable {
    struct Profile: Codable, Equatable { var username: String? }
    let artistAddress: String
    let profile: Profile?
    var displayName: String { profile?.username.flatMap { $0.isEmpty ? nil : $0 } ?? String(artistAddress.prefix(8)) + "…" }
}
struct Destination: Codable, Equatable {
    let address: String
    let name: String
    let chain_id: Int
}
enum CredentialKind: String, Codable { case bearer, artistKey }
struct APICredential: Equatable {
    let kind: CredentialKind
    let secret: String
    func authorize(_ request: inout URLRequest) {
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "x-api-key")
        switch kind {
        case .bearer: request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        case .artistKey: request.setValue(secret, forHTTPHeaderField: "x-api-key")
        }
    }
}
struct SavedSession: Codable, Equatable {
    let token: String
    let email: String
    let expiresAt: Date
    // Missing kind decodes as the legacy JWT format. Never infer kind from a prefix.
    var kind: CredentialKind = .bearer
    var owner: String?
    var keyID: String?
    var keyLabel: String?
    var rejected = false
    var credential: APICredential { APICredential(kind: kind, secret: token) }
    func isValid(at date: Date) -> Bool { !rejected && !token.isEmpty && (kind == .artistKey || expiresAt > date) }
    var isExpired: Bool { !isValid(at: Date()) }
    init(token: String, email: String, expiresAt: Date, kind: CredentialKind = .bearer, owner: String? = nil, rejected: Bool = false, keyID: String? = nil, keyLabel: String? = nil) {
        self.token = token; self.email = email; self.expiresAt = expiresAt
        self.kind = kind; self.owner = owner; self.rejected = rejected
        self.keyID = keyID; self.keyLabel = keyLabel
    }
    enum CodingKeys: String, CodingKey { case token, email, expiresAt, kind, owner, rejected, keyID, keyLabel }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decode(String.self, forKey: .token); email = try c.decode(String.self, forKey: .email)
        expiresAt = try c.decode(Date.self, forKey: .expiresAt)
        kind = try c.decodeIfPresent(CredentialKind.self, forKey: .kind) ?? .bearer
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        keyID = try c.decodeIfPresent(String.self, forKey: .keyID)
        keyLabel = try c.decodeIfPresent(String.self, forKey: .keyLabel)
        rejected = try c.decodeIfPresent(Bool.self, forKey: .rejected) ?? false
    }
    static func expiration(token: String) -> Date {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return Date() }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = object["exp"] as? Double else { return Date() }
        // Used only for client expiry UX; the server verifies authenticity.
        return Date(timeIntervalSince1970: exp - 30)
    }
}

enum PublishStage: String, Codable {
    case draft, uploadingPhoto, uploadingMetadata, ready, submitting, uncertain, published
    var blocksEditing: Bool { self != .draft }
    var mayHavePublished: Bool { self == .submitting || self == .uncertain || self == .published }
}
struct Draft: Codable, Equatable {
    var id = UUID()
    var owner: String
    var destination: Destination
    var title = ""
    var description = ""
    var hasPhoto = false
    var stage: PublishStage = .draft
    var mediaURI: String?
    var metadataURI: String?
    var result: Publication?
    var createdAt = Date()
    // Optional fields keep existing saved drafts readable; missing means legacy JPEG.
    var sourceAssetID: String?
    var mediaMIME: String?
    var mediaExtension: String?
    var alterations: [String]?
    var mime: String { mediaMIME ?? "image/jpeg" }
    var photoFilename: String { "\(id.uuidString).\(mediaExtension ?? "jpg")" }
    var mediaObject: String { "\(id.uuidString.lowercased())-photo.\(mediaExtension ?? "jpg")" }
    var metadataObject: String { "\(id.uuidString.lowercased())-metadata.json" }
}

struct MomentMetadata: Encodable {
    let name: String
    let description: String
    let image: String
    let animation_url: String
    let external_url = ""
    let content: Content
    struct Content: Encodable { let mime: String; let uri: String }
    init(draft: Draft, mediaURI: String) {
        name = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        image = mediaURI
        animation_url = mediaURI
        content = Content(mime: draft.mime, uri: mediaURI)
    }
}

struct CreateMomentRequest: Encodable {
    struct Contract: Encodable { let address: String }
    struct Token: Encodable {
        let tokenMetadataURI: String
        let createReferral = "0x0000000000000000000000000000000000000000"
        let mintToCreatorCount = 1
        let salesConfig = SalesConfig()
    }
    struct SalesConfig: Encodable {
        let type = "erc20Mint"
        let pricePerToken = "1000000"
        let saleStart = "0"
        let saleEnd = "18446744073709551615"
        let currency = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
    }
    let account: String
    let contract: Contract
    let token: Token
    let chainId = 8453
    init(draft: Draft, metadataURI: String) throws {
        guard draft.destination.chain_id == 8453, Self.isAddress(draft.owner), Self.isAddress(draft.destination.address) else {
            throw AppError.message("This version supports existing collections on Base. Check your default collection on In Process.")
        }
        account = draft.owner
        contract = Contract(address: draft.destination.address)
        token = Token(tokenMetadataURI: metadataURI)
    }
    static func isAddress(_ value: String) -> Bool { value.range(of: "^0x[0-9a-fA-F]{40}$", options: .regularExpression) != nil }
}

struct Publication: Codable, Equatable {
    let contractAddress: String
    let tokenId: String
    let hash: String?
    let chainId: Int
    var websiteURL: URL {
        var url = URLComponents(string: "https://inprocess.world/create/success")!
        url.queryItems = [.init(name: "collection", value: contractAddress), .init(name: "tokenId", value: tokenId)]
        return url.url!
    }
    init(contractAddress: String, tokenId: String, hash: String?, chainId: Int) {
        self.contractAddress = contractAddress; self.tokenId = tokenId; self.hash = hash; self.chainId = chainId
    }
    enum CodingKeys: String, CodingKey { case contractAddress, tokenId, hash, chainId }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contractAddress = try c.decode(String.self, forKey: .contractAddress)
        if let value = try? c.decode(String.self, forKey: .tokenId) { tokenId = value }
        else { tokenId = String(try c.decode(UInt64.self, forKey: .tokenId)) }
        hash = try c.decodeIfPresent(String.self, forKey: .hash)
        chainId = try c.decode(Int.self, forKey: .chainId)
    }
}

struct TimelineResponse: Decodable {
    struct Moment: Decodable {
        let address: String
        let token_id: String
        let chain_id: Int
        let uri: String
        let creator: Creator?
        struct Creator: Decodable { let address: String }
    }
    struct Pagination: Decodable { let total_pages: Int }
    let moments: [Moment]
    let pagination: Pagination
}
