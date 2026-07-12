import Foundation
import XCTest
@testable import MeetingScribe

final class OpenAIAnalysisProviderTests: XCTestCase {
    override func tearDown() {
        MockAnalysisURLProtocol.handler = nil
        super.tearDown()
    }

    func testProviderUsesResponsesStructuredOutputsWithoutServerStorage() async throws {
        let expected = sampleAnalysis()
        MockAnalysisURLProtocol.handler = { request in
            let body = try XCTUnwrap(MockAnalysisURLProtocol.bodyData(from: request))
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let text = try XCTUnwrap(json["text"] as? [String: Any])
            let format = try XCTUnwrap(text["format"] as? [String: Any])

            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            XCTAssertEqual(json["model"] as? String, "gpt-test")
            XCTAssertEqual(json["store"] as? Bool, false)
            XCTAssertEqual(format["type"] as? String, "json_schema")
            XCTAssertEqual(format["strict"] as? Bool, true)
            XCTAssertTrue((json["input"] as? String)?.contains("Transcript text") == true)

            return MockAnalysisResponse(statusCode: 200, data: try self.successResponse(expected))
        }

        let provider = OpenAIAnalysisProvider(
            apiKey: "test-key",
            model: "gpt-test",
            endpointURL: URL(string: "https://example.test/v1/responses")!,
            session: makeSession()
        )
        let result = try await provider.analyze(makeRequest())

        XCTAssertEqual(result, expected)
    }

    func testProviderSurfacesAPIErrorMessage() async {
        let attempts = LockedCounter()
        MockAnalysisURLProtocol.handler = { _ in
            _ = attempts.increment()
            return MockAnalysisResponse(
                statusCode: 401,
                data: Data(#"{"error":{"message":"Invalid API key"}}"#.utf8)
            )
        }
        let provider = OpenAIAnalysisProvider(
            apiKey: "bad-key",
            endpointURL: URL(string: "https://example.test/v1/responses")!,
            session: makeSession()
        )

        do {
            _ = try await provider.analyze(makeRequest())
            XCTFail("Expected API error.")
        } catch {
            XCTAssertEqual(
                error as? AnalysisError,
                .apiError(statusCode: 401, message: "Invalid API key")
            )
        }
        XCTAssertEqual(attempts.value, 1)
    }

    func testProviderSurfacesStructuredRefusal() async {
        MockAnalysisURLProtocol.handler = { _ in
            MockAnalysisResponse(
                statusCode: 200,
                data: Data(#"{"status":"completed","output":[{"content":[{"type":"refusal","refusal":"Cannot analyze"}]}]}"#.utf8)
            )
        }
        let provider = OpenAIAnalysisProvider(
            apiKey: "test-key",
            endpointURL: URL(string: "https://example.test/v1/responses")!,
            session: makeSession()
        )

        do {
            _ = try await provider.analyze(makeRequest())
            XCTFail("Expected refusal.")
        } catch {
            XCTAssertEqual(error as? AnalysisError, .refusal("Cannot analyze"))
        }
    }

    func testProviderRejectsIncompleteResponse() async {
        MockAnalysisURLProtocol.handler = { _ in
            MockAnalysisResponse(
                statusCode: 200,
                data: Data(#"{"status":"incomplete","output":[]}"#.utf8)
            )
        }
        let provider = OpenAIAnalysisProvider(
            apiKey: "test-key",
            endpointURL: URL(string: "https://example.test/v1/responses")!,
            session: makeSession()
        )

        do {
            _ = try await provider.analyze(makeRequest())
            XCTFail("Expected incomplete response error.")
        } catch {
            XCTAssertEqual(error as? AnalysisError, .incompleteResponse(status: "incomplete"))
        }
    }

    func testProviderRetriesRateLimitUsingRetryAfterThenSucceeds() async throws {
        let expected = sampleAnalysis()
        let attempts = LockedCounter()
        let delays = LockedDelayRecorder()
        MockAnalysisURLProtocol.handler = { _ in
            if attempts.increment() == 1 {
                return MockAnalysisResponse(
                    statusCode: 429,
                    headers: ["Retry-After": "2"],
                    data: Data(#"{"error":{"message":"Slow down"}}"#.utf8)
                )
            }
            return MockAnalysisResponse(statusCode: 200, data: try self.successResponse(expected))
        }
        let provider = makeProvider(
            retryPolicy: AnalysisRetryPolicy(
                maxAttempts: 3,
                baseDelaySeconds: 1,
                maximumDelaySeconds: 8,
                jitterRatio: 0
            ),
            sleep: { delays.record($0) }
        )

        let result = try await provider.analyze(makeRequest())

        XCTAssertEqual(result, expected)
        XCTAssertEqual(attempts.value, 2)
        XCTAssertEqual(delays.values, [2])
    }

    func testProviderRetriesServerErrorsWithBoundedExponentialBackoff() async {
        let attempts = LockedCounter()
        let delays = LockedDelayRecorder()
        MockAnalysisURLProtocol.handler = { _ in
            _ = attempts.increment()
            return MockAnalysisResponse(
                statusCode: 503,
                data: Data(#"{"error":{"message":"Temporarily unavailable"}}"#.utf8)
            )
        }
        let provider = makeProvider(
            retryPolicy: AnalysisRetryPolicy(
                maxAttempts: 3,
                baseDelaySeconds: 0.5,
                maximumDelaySeconds: 4,
                jitterRatio: 0
            ),
            sleep: { delays.record($0) }
        )

        do {
            _ = try await provider.analyze(makeRequest())
            XCTFail("Expected the final server error.")
        } catch {
            XCTAssertEqual(
                error as? AnalysisError,
                .serverError(statusCode: 503, message: "Temporarily unavailable")
            )
        }
        XCTAssertEqual(attempts.value, 3)
        XCTAssertEqual(delays.values, [0.5, 1])
    }

    func testProviderRetriesWhitelistedNetworkErrorThenSucceeds() async throws {
        let expected = sampleAnalysis()
        let attempts = LockedCounter()
        let delays = LockedDelayRecorder()
        MockAnalysisURLProtocol.handler = { _ in
            if attempts.increment() == 1 {
                throw URLError(.timedOut)
            }
            return MockAnalysisResponse(statusCode: 200, data: try self.successResponse(expected))
        }
        let provider = makeProvider(
            retryPolicy: AnalysisRetryPolicy(
                maxAttempts: 2,
                baseDelaySeconds: 0.25,
                maximumDelaySeconds: 2,
                jitterRatio: 0
            ),
            sleep: { delays.record($0) }
        )

        let result = try await provider.analyze(makeRequest())

        XCTAssertEqual(result, expected)
        XCTAssertEqual(attempts.value, 2)
        XCTAssertEqual(delays.values, [0.25])
    }

    func testProviderMapsNetworkErrorToTypedErrorWhenRetriesAreExhausted() async {
        MockAnalysisURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let provider = makeProvider(
            retryPolicy: AnalysisRetryPolicy(maxAttempts: 1),
            sleep: { _ in XCTFail("A single-attempt policy must not sleep.") }
        )

        do {
            _ = try await provider.analyze(makeRequest())
            XCTFail("Expected a typed network error.")
        } catch {
            guard case let .network(code, _) = error as? AnalysisError else {
                return XCTFail("Expected AnalysisError.network, received \(error)")
            }
            XCTAssertEqual(code, .notConnectedToInternet)
        }
    }

    func testProviderAddsDeterministicJitterWithinConfiguredBound() async throws {
        let expected = sampleAnalysis()
        let attempts = LockedCounter()
        let delays = LockedDelayRecorder()
        MockAnalysisURLProtocol.handler = { _ in
            if attempts.increment() == 1 {
                return MockAnalysisResponse(
                    statusCode: 500,
                    data: Data(#"{"error":{"message":"Retry me"}}"#.utf8)
                )
            }
            return MockAnalysisResponse(statusCode: 200, data: try self.successResponse(expected))
        }
        let provider = makeProvider(
            retryPolicy: AnalysisRetryPolicy(
                maxAttempts: 2,
                baseDelaySeconds: 2,
                maximumDelaySeconds: 8,
                jitterRatio: 0.5
            ),
            sleep: { delays.record($0) },
            jitter: { 0.5 }
        )

        _ = try await provider.analyze(makeRequest())

        XCTAssertEqual(delays.values, [2.5])
    }

    func testProviderDoesNotRetryWhenRetryAfterExceedsLocalDelayLimit() async {
        let attempts = LockedCounter()
        MockAnalysisURLProtocol.handler = { _ in
            _ = attempts.increment()
            return MockAnalysisResponse(
                statusCode: 429,
                headers: ["Retry-After": "60"],
                data: Data(#"{"error":{"message":"Quota window"}}"#.utf8)
            )
        }
        let provider = makeProvider(
            retryPolicy: AnalysisRetryPolicy(
                maxAttempts: 3,
                baseDelaySeconds: 1,
                maximumDelaySeconds: 8,
                jitterRatio: 0
            ),
            sleep: { _ in XCTFail("An excessive Retry-After must not be shortened.") }
        )

        do {
            _ = try await provider.analyze(makeRequest())
            XCTFail("Expected a typed rate-limit error.")
        } catch {
            XCTAssertEqual(
                error as? AnalysisError,
                .rateLimited(message: "Quota window", retryAfterSeconds: 60)
            )
        }
        XCTAssertEqual(attempts.value, 1)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockAnalysisURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeProvider(
        retryPolicy: AnalysisRetryPolicy,
        sleep: @escaping @Sendable (Double) async throws -> Void,
        jitter: @escaping @Sendable () -> Double = { 0 }
    ) -> OpenAIAnalysisProvider {
        OpenAIAnalysisProvider(
            apiKey: "test-key",
            model: "gpt-test",
            endpointURL: URL(string: "https://example.test/v1/responses")!,
            session: makeSession(),
            retryPolicy: retryPolicy,
            sleep: sleep,
            jitter: jitter
        )
    }

    private func makeRequest() -> AnalysisRequest {
        AnalysisRequest(
            mode: .transcript,
            meetingTitle: "Test",
            recordingID: "session-1",
            preferredLanguage: "sk",
            content: "Transcript text"
        )
    }

    private func sampleAnalysis() -> MeetingAnalysis {
        MeetingAnalysis(
            summary: "Súhrn",
            decisions: [],
            actionItems: [],
            openQuestions: [],
            risksAndBlockers: [],
            nextMeetingTopics: []
        )
    }

    private func successResponse(_ analysis: MeetingAnalysis) throws -> Data {
        let analysisData = try JSONEncoder().encode(analysis)
        let analysisJSON = try XCTUnwrap(String(data: analysisData, encoding: .utf8))
        return try JSONSerialization.data(withJSONObject: [
            "status": "completed",
            "output": [
                [
                    "type": "message",
                    "content": [
                        ["type": "output_text", "text": analysisJSON],
                    ],
                ],
            ],
        ])
    }
}

private struct MockAnalysisResponse {
    let statusCode: Int
    var headers: [String: String] = [:]
    let data: Data
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

private final class LockedDelayRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    var values: [Double] { lock.withLock { storage } }

    func record(_ delay: Double) {
        lock.withLock { storage.append(delay) }
    }
}

private final class MockAnalysisURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> MockAnalysisResponse)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let result = try handler(request)
            var headers = result.headers
            headers["Content-Type"] = "application/json"
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: result.statusCode,
                httpVersion: nil,
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
