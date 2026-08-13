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

