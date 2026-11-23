import XCTest
import UIKit
import ImageIO
@testable import InProcess

@MainActor final class PublishingTests: XCTestCase {
    let owner = "0x1111111111111111111111111111111111111111"
    let collection = Destination(address: "0x2222222222222222222222222222222222222222", name: "Process", chain_id: 8453)

    func makeModel() throws -> (AppModel, StubAPI) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try DraftStore(directory: directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let api = StubAPI(owner: owner, collection: collection)
        let model = AppModel(api: api, sessions: MemorySessions(), drafts: store)
        model.identity = Identity(artistAddress: owner, profile: .init(username: "Local test"))
        model.destination = collection
        model.session = SavedSession(token: "test-only", email: "test@example.invalid", expiresAt: Date().addingTimeInterval(3600))
        let draft = Draft(owner: owner, destination: collection)
        try store.save(draft); model.draft = draft
        try model.acceptPhoto(photoData())
        return (model, api)
    }
    func photoData() -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 60, height: 40), format: format).jpegData(withCompressionQuality: 0.8) { ctx in
            UIColor.orange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        }
    }
    func testPublicationUsesAuthenticatedAccountAndConfirmedResult() async throws {
        #if targetEnvironment(simulator)
        XCTAssertTrue(PublishUITestService.isHostedUnitTest)
        XCTAssertThrowsError(try InProcessAPI(), "Hosted tests must reject live services before reading saved accounts.")
        #endif
        let (model, api) = try makeModel()
        await model.publish()
        XCTAssertEqual(model.draft?.stage, .published)
        XCTAssertEqual(api.creates, 1)
        XCTAssertEqual(api.uploads, 2)
        XCTAssertEqual(model.draft?.result?.tokenId, "7")
        await model.publish()
        XCTAssertEqual(api.creates, 1)
    }
    func testLostCreateResponseLocksRetryAcrossRestartAndReconciles() async throws {
        let (model, api) = try makeModel(); api.failCreate = true
        await model.publish()
        XCTAssertEqual(model.draft?.stage, .uncertain)
        XCTAssertFalse(model.canPublish)
        await model.publish(); XCTAssertEqual(api.creates, 1)
        let recovered = try XCTUnwrap(model.drafts.load())
        XCTAssertEqual(recovered.stage, .uncertain)
        api.reconciled = Publication(contractAddress: collection.address, tokenId: "7", hash: nil, chainId: 8453)
        await model.checkPublication()
        XCTAssertEqual(model.draft?.stage, .published)
        XCTAssertEqual(api.creates, 1)
    }
    func testSubmittingRestoresAsUncertainAndCannotBeDeleted() throws {
        let (model, _) = try makeModel()
        var draft = try XCTUnwrap(model.draft); draft.stage = .submitting
        try model.drafts.save(draft)
        XCTAssertEqual(try model.drafts.load()?.stage, .uncertain)
        XCTAssertThrowsError(try model.drafts.remove(draft))
    }
    func testFailedMetadataTransferReusesPhotoAndFreezesEdits() async throws {
        let (model, api) = try makeModel(); api.failMetadataOnce = true
        await model.publish()
        XCTAssertEqual(model.draft?.stage, .uploadingMetadata)
        XCTAssertEqual(api.creates, 0)
        model.edit(title: "Changed after upload")
        XCTAssertEqual(model.draft?.title, "")
        await model.publish()
        XCTAssertEqual(api.uploads, 3) // photo, failed metadata, resumed metadata
        XCTAssertEqual(api.creates, 1)
    }
    func testExpiredSessionAndWrongAccountNeverUpload() async throws {
        let (model, api) = try makeModel()
        model.session = SavedSession(token: "expired", email: "test@example.invalid", expiresAt: .distantPast)
        await model.publish(); XCTAssertEqual(api.uploads, 0); XCTAssertNil(model.identity)
        let (otherModel, otherAPI) = try makeModel()
        otherAPI.owner = "0x3333333333333333333333333333333333333333"
        await otherModel.publish(); XCTAssertEqual(otherAPI.uploads, 0); XCTAssertEqual(otherAPI.creates, 0)
    }
    func testMissingIndexedMomentDoesNotEnableRetry() async throws {
        let (model, api) = try makeModel(); api.failCreate = true
        await model.publish(); await model.checkPublication()
        XCTAssertEqual(model.draft?.stage, .uncertain); XCTAssertFalse(model.canPublish); XCTAssertEqual(api.creates, 1)
    }
    func testDefaultsUseExactUSDCUnitsAndOmitSupplyAndSplits() throws {
        let draft = Draft(owner: owner, destination: collection)
        let data = try JSONEncoder().encode(CreateMomentRequest(draft: draft, metadataURI: "https://example.invalid/metadata.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let token = try XCTUnwrap(object["token"] as? [String: Any])
        let sale = try XCTUnwrap(token["salesConfig"] as? [String: String])
        XCTAssertEqual(sale["pricePerToken"], "1000000"); XCTAssertEqual(sale["saleEnd"], "18446744073709551615")
        XCTAssertEqual(sale["currency"], "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913")
        XCTAssertNil(token["maxSupply"]); XCTAssertNil(object["splits"])
        let metadata = try JSONEncoder().encode(MomentMetadata(draft: draft, mediaURI: "https://example.invalid/photo.jpg"))
        XCTAssertTrue(String(decoding: metadata, as: UTF8.self).contains("\"name\":\"\""))
    }
    func testPhotoPreparationPreservesSupportedJPEGBytes() throws {
        let input = photoData()
        let prepared = try PhotoProcessor.prepare(input)
        XCTAssertEqual(prepared, input)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(prepared as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
        XCTAssertThrowsError(try PhotoProcessor.prepare(Data("not an image".utf8)))
    }
    func testPhotoPreparationPreservesOrientationAndLocation() throws {
        let image = try XCTUnwrap(UIImage(data: photoData())?.cgImage)
        let input = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(input, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6, kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 40.0]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let output = try PhotoProcessor.prepare(input as Data)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, 60)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, 40)
        XCTAssertEqual(properties[kCGImagePropertyOrientation as String] as? Int, 6)
        XCTAssertNotNil(properties[kCGImagePropertyGPSDictionary as String])
        XCTAssertEqual(output, input as Data)
    }
    // Media type evals (docs/media-type-evals.md): Simulator layer.
    func testMediaTypeFormatAcceptsOnlyVerifiedStillTypes() throws {
        let accepted = [("public.jpeg", "image/jpeg", "jpg"), ("public.png", "image/png", "png"),
                        ("public.heic", "image/heic", "heic"), ("public.heif", "image/heif", "heif")]
        for (identifier, mime, ext) in accepted {
            let format = try PhotoProcessor.format(identifier)
            XCTAssertEqual(format.mime, mime); XCTAssertEqual(format.ext, ext)
        }
        // Types the service's web client handles that this app must refuse, not convert.
        let refused = ["com.compuserve.gif", "org.webmproject.webp", "public.tiff", "public.svg-image",
                       "com.adobe.raw-image", "public.avif", "com.apple.quicktime-movie", "public.mpeg-4",
                       "public.mp3", "com.adobe.pdf", "public.plain-text", "org.khronos.glb", ""]
        for identifier in refused {
            XCTAssertThrowsError(try PhotoProcessor.format(identifier), identifier)
        }
    }
    func testMediaTypeRejectsGIFAndTIFFBytesWithoutConversion() throws {
        let image = try XCTUnwrap(UIImage(data: photoData())?.cgImage)
        func encode(_ type: String, frames: Int) throws -> Data {
            let output = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, type as CFString, frames, nil))
            for _ in 0..<frames { CGImageDestinationAddImage(destination, image, nil) }
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return output as Data
        }
        for (type, frames) in [("com.compuserve.gif", 1), ("com.compuserve.gif", 3), ("public.tiff", 1)] {
            let input = try encode(type, frames: frames)
            XCTAssertThrowsError(try PhotoProcessor.inspect(input), "\(type) x\(frames)")
            XCTAssertThrowsError(try PhotoProcessor.prepare(input), "\(type) x\(frames)")
        }
        // Supported bytes still pass through byte-identical in the same run.
        let jpeg = photoData()
        XCTAssertEqual(try PhotoProcessor.inspect(jpeg).data, jpeg)
        XCTAssertEqual(try PhotoProcessor.inspect(jpeg).mime, "image/jpeg")
    }
    func testMediaTypeHEIFIsAcceptedByTheAppButNotByTheEndpointGate() throws {
        // Characterizes the current mismatch recorded as MEDIA-HEIF; not a statement of intended behavior.
        XCTAssertEqual(try PhotoProcessor.format("public.heif").mime, "image/heif")
        func accepts(_ mime: String, _ ext: String) -> Bool {
            let url = URL(string: "https://zzgteesackezhtnuqfyw.supabase.co/storage/v1/object/in_process_files/\(UUID().uuidString)-photo.\(ext)")!
            var request = URLRequest(url: url); request.httpMethod = "POST"
            request.setValue(mime, forHTTPHeaderField: "Content-Type")
            request.setValue("k", forHTTPHeaderField: "apikey"); request.setValue("Bearer k", forHTTPHeaderField: "Authorization")
            request.setValue("false", forHTTPHeaderField: "x-upsert")
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            return PhotoKitTransfer.acceptsEndpointPreflight(upload: request, response: response)
        }
        XCTAssertTrue(accepts("image/heic", "heic"))
        XCTAssertFalse(accepts("image/heif", "heif"))
    }
}

final class MemorySessions: SessionStoring {
    var value: SavedSession?
    var saveFailure: Error?
    func load() throws -> SavedSession? { value }
    func save(_ session: SavedSession) throws { if let saveFailure { throw saveFailure }; value = session }
    func clear() throws { value = nil }
}

final class StubAPI: InProcessServing {
    var owner: String
    let collection: Destination
    var creates = 0; var uploads = 0
    var failCreate = false; var failMetadataOnce = false
    var reconciled: Publication?
    init(owner: String, collection: Destination) { self.owner = owner; self.collection = collection }
    func sendCode(email: String) async throws { }
    func login(email: String, code: String) async throws -> LoginResponse { throw AppError.message("Not used by publication tests") }
    func identity(token: APICredential) async throws -> Identity { Identity(artistAddress: owner, profile: .init(username: "Local test")) }
    func destination(token: APICredential) async throws -> Destination { collection }
    func upload(data: Data, object: String, contentType: String) async throws -> String {
        uploads += 1
        if contentType == "application/json" && failMetadataOnce { failMetadataOnce = false; throw URLError(.notConnectedToInternet) }
        return "https://example.invalid/\(object)"
    }
    func simulate(_ request: CreateMomentRequest, token: APICredential) async throws { }
    func create(_ request: CreateMomentRequest, token: APICredential) async throws -> Publication {
        creates += 1
        if failCreate { throw URLError(.timedOut) }
        return Publication(contractAddress: collection.address, tokenId: "7", hash: "0xtest", chainId: 8453)
    }
    func reconcile(_ draft: Draft, token: APICredential) async throws -> Publication? { reconciled }
}
