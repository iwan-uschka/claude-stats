import Foundation
import XCTest
@testable import ClaudeStatsCore

// MARK: - Error assertions

extension XCTestCase {
    /// Asserts the async body throws a specific ``ClaudeStatsError``.
    func assertThrows(
        _ expected: ClaudeStatsError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> some Any
    ) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected), but nothing was thrown", file: file, line: line)
        } catch let error as ClaudeStatsError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }

    /// Asserts ``ClaudeStatsError/unexpectedQuotaResponse(_:)`` regardless of its
    /// message, and returns that message for further inspection.
    @discardableResult
    func assertThrowsUnexpectedQuotaResponse(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> some Any
    ) async -> String? {
        do {
            _ = try await body()
            XCTFail("expected unexpectedQuotaResponse, but nothing was thrown", file: file, line: line)
            return nil
        } catch let ClaudeStatsError.unexpectedQuotaResponse(message) {
            return message
        } catch {
            XCTFail("expected unexpectedQuotaResponse, got \(error)", file: file, line: line)
            return nil
        }
    }
}

// MARK: - Stub quota sources

/// Stub ``QuotaProviding`` that returns a fixed snapshot or a fixed error, and
/// records whether it was asked. Used to pin ``CompositeQuotaProvider``'s
/// fallback ordering without any I/O.
final class StubQuotaProvider: QuotaProviding, @unchecked Sendable {
    private let result: Result<QuotaSnapshot, Error>
    private let lock = NSLock()
    private var _callCount = 0

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }

    var wasCalled: Bool { callCount > 0 }

    init(snapshot: QuotaSnapshot) { result = .success(snapshot) }
    init(error: Error) { result = .failure(error) }

    func currentSnapshot() async throws -> QuotaSnapshot {
        lock.lock()
        _callCount += 1
        lock.unlock()
        return try result.get()
    }
}

/// Stub ``OAuthTokenProviding`` — no file or Keychain access.
struct StubTokenStore: OAuthTokenProviding {
    var token: String?

    init(token: String? = "test-token-not-a-real-credential") { self.token = token }

    func accessToken() throws -> String {
        guard let token else { throw ClaudeStatsError.missingCredentials }
        return token
    }
}

// MARK: - Snapshot builders

extension QuotaSnapshot {
    static func fixture(
        fiveHour: Double = 50,
        sevenDay: Double = 20,
        confidence: QuotaConfidence,
        capturedAt: Date
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            fiveHour: QuotaWindow(percentUsed: fiveHour),
            sevenDay: QuotaWindow(percentUsed: sevenDay),
            confidence: confidence,
            capturedAt: capturedAt
        )
    }
}

// MARK: - URLProtocol network stub

/// `URLProtocol` subclass that answers every request from an injected handler, so
/// ``OAuthUsageClient`` can be exercised end-to-end with zero real network I/O.
///
/// Use ``makeSession()`` to get a `URLSession` wired to this class.
final class StubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var recordedRequests: [URLRequest] = []

    /// Installs the response handler and clears recorded requests.
    static func setHandler(_ handler: Handler?) {
        lock.lock(); defer { lock.unlock() }
        Self.handler = handler
        recordedRequests = []
    }

    static func reset() { setHandler(nil) }

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recordedRequests
    }

    /// Convenience handler returning a JSON body with a given status code.
    static func respond(statusCode: Int, body: String) {
        setHandler { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(body.utf8))
        }
    }

    /// Convenience handler that fails the transport, as when offline.
    static func failTransport(with error: Error) {
        setHandler { _ in throw error }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    // MARK: URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recordedRequests.append(request)
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
