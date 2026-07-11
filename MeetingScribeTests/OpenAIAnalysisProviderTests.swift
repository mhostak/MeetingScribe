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

            return (200, try self.successResponse(expected))
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
        MockAnalysisURLProtocol.handler = { _ in
            (401, Data(#"{"error":{"message":"Invalid API key"}}"#.utf8))
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
    }

    func testProviderSurfacesStructuredRefusal() async {
        MockAnalysisURLProtocol.handler = { _ in
            (
                200,
                Data(#"{"status":"completed","output":[{"content":[{"type":"refusal","refusal":"Cannot analyze"}]}]}"#.utf8)
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
            (200, Data(#"{"status":"incomplete","output":[]}"#.utf8))
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

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockAnalysisURLProtocol.self]
        return URLSession(configuration: configuration)
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

private final class MockAnalysisURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

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
            let (statusCode, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
