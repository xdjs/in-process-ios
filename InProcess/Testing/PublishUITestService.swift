#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import CoreFoundation

/// Only selected by an explicit XCUITest launch argument. Never delegates to live services.
@MainActor @Observable
final class PublishUITestService: InProcessServing {
    nonisolated static var isHostedUnitTest: Bool {
        NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
    static let person = Identity(artistAddress: "0x1111111111111111111111111111111111111111",
                                 profile: .init(username: "UI Test Artist"))
    static let collection = Destination(address: "0x2222222222222222222222222222222222222222",
                                        name: "UI Test Collection", chain_id: 8453)
    private(set) var createCount = 0
    private(set) var uploadCount = 0
    private(set) var waitingForRelease = false
    @ObservationIgnored private var completion: CheckedContinuation<Publication, Error>?
    @ObservationIgnored private let releaseName: String

    init(runID: UUID) {
        releaseName = "com.xdjs.InProcess.ui-test.publish.\(runID.uuidString)"
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(), { _, observer, _, _, _ in
                guard let observer else { return }
                let service = Unmanaged<PublishUITestService>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in service.releaseCreate() }
            }, releaseName as CFString, nil, .deliverImmediately)
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                                Unmanaged.passUnretained(self).toOpaque())
    }

    static func makeModel(runID: UUID? = nil) throws -> AppModel {
        let configuredID = ProcessInfo.processInfo.environment["INPROCESS_UI_TEST_RUN_ID"].flatMap(UUID.init(uuidString:))
        guard let runID = runID ?? configuredID else {
            throw AppError.message("Missing publishing UI test run ID; live services remain disabled.")
        }
        let service = PublishUITestService(runID: runID)
        // Never instantiate KeychainSessionStore or the default Application Support draft store.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PublishUITests", isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
        let model = AppModel(api: service, sessions: PublishUITestSessions(), drafts: try DraftStore(directory: directory))
        model.didRestore = true
        model.route = .manual
        model.session = SavedSession(token: "ui-test-only", email: "ui-test@example.invalid",
                                     expiresAt: Date().addingTimeInterval(3600))
        model.identity = person
        model.destination = collection
        model.draft = Draft(owner: person.artistAddress, destination: collection)
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 120)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 120))
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 80, y: 30, width: 80, height: 60))
        }
        guard let data = photo.jpegData(compressionQuality: 0.9) else {
            throw AppError.message("Could not prepare synthetic UI test photo.")
        }
        try model.acceptPhoto(data)
        return model
    }

    func sendCode(email: String) async throws { throw unexpectedCall() }
    func login(email: String, code: String) async throws -> LoginResponse { throw unexpectedCall() }
    func identity(token: APICredential) async throws -> Identity { Self.person }
    func destination(token: APICredential) async throws -> Destination { Self.collection }
    func upload(data: Data, object: String, contentType: String) async throws -> String {
        uploadCount += 1
        return "https://ui-test.example.invalid/\(object)"
    }
    func simulate(_ request: CreateMomentRequest, token: APICredential) async throws {}
    func create(_ request: CreateMomentRequest, token: APICredential) async throws -> Publication {
        createCount += 1
        guard createCount == 1 else { throw AppError.message("Duplicate UI test create call.") }
        return try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            waitingForRelease = true
        }
    }
    func reconcile(_ draft: Draft, token: APICredential) async throws -> Publication? { throw unexpectedCall() }

    private func releaseCreate() {
        guard let completion else { return }
        self.completion = nil
        waitingForRelease = false
        completion.resume(returning: Publication(contractAddress: Self.collection.address,
            tokenId: "1", hash: "0xuitest", chainId: 8453))
    }
    private func unexpectedCall() -> AppError { .message("Unexpected call to the isolated UI test service.") }
}

private final class PublishUITestSessions: SessionStoring {
    private var session: SavedSession?
    func load() throws -> SavedSession? { session }
    func save(_ session: SavedSession) throws { self.session = session }
    func clear() throws { session = nil }
}

/// Read-only test telemetry; the actual screens and Publish button remain RootView's.
struct PublishUITestStatus: View {
    let service: PublishUITestService
    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text("Isolated UI test").accessibilityIdentifier("uiTestMode")
            Text("Creates: \(service.createCount)")
                .accessibilityIdentifier("uiTestCreateCount").accessibilityValue(String(service.createCount))
            Text("Uploads: \(service.uploadCount)")
                .accessibilityIdentifier("uiTestUploadCount").accessibilityValue(String(service.uploadCount))
            Text(service.waitingForRelease ? "Create held" : "Create idle")
                .accessibilityIdentifier("uiTestCreateWaiting").accessibilityValue(String(service.waitingForRelease))
        }
        .font(.caption2).padding(4).background(.background)
        .allowsHitTesting(false)
    }
}
#endif
