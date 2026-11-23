import XCTest
@testable import InProcess

final class CredentialTransportTests: XCTestCase {
    func api() throws -> InProcessAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CredentialURLProtocol.self]
        return try InProcessAPI(testSession: URLSession(configuration: configuration), baseURL: URL(string: "https://auth.fixture.invalid/api")!)
    }
    override func tearDown() { CredentialURLProtocol.response = nil; super.tearDown() }
    func testCredentialTransportDisablesCachesCookiesAndCredentialPersistence() {
        let configuration = InProcessAPI.credentialNetworkConfiguration
        XCTAssertNil(configuration.urlCache); XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }
    func testOnlyExplicitCredentialHeaderIsSent() async throws {
        for kind in [CredentialKind.bearer, .artistKey] {
            let credential = APICredential(kind: kind, secret: "synthetic-only")
            CredentialURLProtocol.response = { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), kind == .bearer ? "Bearer synthetic-only" : nil)
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), kind == .artistKey ? "synthetic-only" : nil)
                return (200, Data("{\"artistAddress\":\"0x1111111111111111111111111111111111111111\",\"profile\":{\"username\":\"Fixture\"}}".utf8))
            }
            _ = try await api().identity(token: credential)
        }
        var request = URLRequest(url: URL(string: "https://fixture.invalid")!)
        request.setValue("Bearer old", forHTTPHeaderField: "Authorization")
        APICredential(kind: .artistKey, secret: "new").authorize(&request)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }
    func testKeyCreationContractAndAmbiguousVsDefiniteErrors() async throws {
        for status in [200, 400, 401, 403, 429, 500, 503] {
            CredentialURLProtocol.response = { request in
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.url?.path, "/api/artists/api-keys")
                let body: Data
                if let data = request.httpBody { body = data }
                else if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 1024); var result = Data()
                    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; result.append(contentsOf: buffer.prefix(count)) }
                    body = result
                } else { body = Data() }
                let object = try JSONSerialization.jsonObject(with: body) as? [String: String]
                XCTAssertEqual(object, ["key_name": "Fixture installation"])
                return (status, Data("{\"key\":\"art_sk_synthetic_no_authority\"}".utf8))
            }
            do {
                _ = try await api().createArtistKey(name: "Fixture installation", bootstrap: .init(kind: .bearer, secret: "synthetic"))
                XCTAssertEqual(status, 200)
            } catch KeyIssuanceError.notCreated(let code) { XCTAssertEqual(code, status); XCTAssertLessThan(code, 500) }
            catch KeyIssuanceError.uncertain { XCTAssertGreaterThanOrEqual(status, 500) }
        }
    }
    func testInvalidKeyIsDistinctFromRateLimitAndServerFailure() async throws {
        for status in [401, 403, 429, 500, 503] {
            CredentialURLProtocol.response = { _ in (status, Data()) }
            do { _ = try await api().identity(token: .init(kind: .artistKey, secret: "synthetic")); XCTFail() }
            catch AppError.sessionExpired { XCTAssertTrue([401, 403].contains(status)) }
            catch { XCTAssertTrue([429, 500, 503].contains(status)) }
        }
    }
    func testMalformedSuccessIsAmbiguousAndRevocationUsesExactID() async throws {
        CredentialURLProtocol.response = { _ in (200, Data("{\"apiKey\":\"wrong-contract\"}".utf8)) }
        do { _ = try await api().createArtistKey(name: "Fixture", bootstrap: .init(kind: .bearer, secret: "synthetic")); XCTFail() }
        catch KeyIssuanceError.uncertain {} catch { XCTFail("Unexpected classification") }
        let id = UUID().uuidString
        CredentialURLProtocol.response = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems, [.init(name: "keyId", value: id)])
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, Data("{}".utf8))
        }
        try await api().revokeArtistKey(id: id, token: .init(kind: .artistKey, secret: "synthetic"))
    }
}

private final class CredentialURLProtocol: URLProtocol {
    static var response: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let response = Self.response else { throw URLError(.unsupportedURL) }
            let (status, data) = try response(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
