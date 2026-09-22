import XCTest
import Supabase
@testable import PowderMeet

final class SocialRequestWriterTests: XCTestCase {
    func testFriendAcceptanceRequiresOneMatchingServerReceipt() async throws {
        let id = UUID(), receiver = UUID()
        for body in ["[]", "[{\"id\":\"\(UUID())\",\"status\":\"accepted\"}]",
                     "[{\"id\":\"\(id)\",\"status\":\"pending\"}]"] {
            let writer = writer(body: body)
            do {
                try await writer.acceptFriendship(id: id, receiverID: receiver)
                XCTFail("No-row and mismatched responses must not create a local friendship")
            } catch {}
        }
        let writer = writer(body: "[{\"id\":\"\(id)\",\"status\":\"accepted\"}]")
        try await writer.acceptFriendship(id: id, receiverID: receiver)
        let request = try XCTUnwrap(SocialRequestHTTP.lastRequest)
        XCTAssertEqual(request.httpMethod, "PATCH")
        let query = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertTrue(query.contains(.init(name: "status", value: "eq.pending")))
        XCTAssertTrue(query.contains(.init(name: "addressee_id", value: "eq.\(receiver)")))
        XCTAssertTrue(request.value(forHTTPHeaderField: "Prefer")?.contains("return=representation") == true)
    }

    func testMeetAcceptanceCannotSucceedAfterExpiryOrConcurrentCancellation() async throws {
        let id = UUID(), receiver = UUID(), now = Date(timeIntervalSince1970: 1_790_000_000)
        let writer = writer(body: "[]")
        do {
            try await writer.respondToMeet(id: id, receiverID: receiver, status: .accepted, now: now)
            XCTFail("A zero-row update is not accepted")
        } catch {}
        let request = try XCTUnwrap(SocialRequestHTTP.lastRequest)
        let query = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertTrue(query.contains(.init(name: "status", value: "eq.pending")))
        XCTAssertTrue(query.contains(.init(name: "receiver_id", value: "eq.\(receiver)")))
        XCTAssertTrue(query.contains(.init(name: "expires_at", value: "gt.\(ISO8601Parser.string(from: now))")))
    }

    func testBothMeetResponsesRequireConfirmedStateAndPropagateServerFailure() async throws {
        let id = UUID(), receiver = UUID()
        for status in [MeetRequestStatus.accepted, .declined] {
            try await writer(body: "[{\"id\":\"\(id)\",\"status\":\"\(status.rawValue)\"}]")
                .respondToMeet(id: id, receiverID: receiver, status: status)
        }
        do {
            try await writer(body: "{\"code\":\"42501\",\"message\":\"denied\"}", code: 403)
                .respondToMeet(id: id, receiverID: receiver, status: .accepted)
            XCTFail("Permission failure must propagate")
        } catch {}
    }

    private func writer(body: String, code: Int = 200) -> SocialRequestWriter {
        SocialRequestHTTP.responseBody = Data(body.utf8)
        SocialRequestHTTP.responseCode = code
        SocialRequestHTTP.lastRequest = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SocialRequestHTTP.self]
        let client = SupabaseClient(supabaseURL: URL(string: "https://social-tests.invalid")!,
            supabaseKey: "test-public-key", options: .init(global: .init(session: URLSession(configuration: config))))
        return SocialRequestWriter(client: client)
    }
}

private final class SocialRequestHTTP: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseBody = Data()
    nonisolated(unsafe) static var responseCode = 200
    nonisolated(unsafe) static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.responseCode,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
