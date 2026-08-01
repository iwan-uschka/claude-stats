import CoreGraphics
import XCTest
@testable import ClaudeStatsCore

/// Covers the SVG path parser that turns `assets/claude-mark.svg` into the glyph
/// drawn in the menu bar, plus the fitting transform used to place it.
final class SVGPathParserTests: XCTestCase {
    private func path(_ data: String) throws -> CGPath {
        try SVGPathParser.cgPath(from: data)
    }

    private func assertRect(
        _ actual: CGRect,
        _ expected: CGRect,
        accuracy: CGFloat = 0.001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, "minX", file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, "minY", file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, "width", file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, "height", file: file, line: line)
    }

    // MARK: - Commands

    func testAbsoluteMoveLineAndClose() throws {
        let path = try path("M0 0 L10 0 L10 10 Z")
        assertRect(path.boundingBoxOfPath, CGRect(x: 0, y: 0, width: 10, height: 10))
        // `Z` returns the current point to the subpath start.
        XCTAssertEqual(path.currentPoint, .zero)
    }

    func testRelativeCommandsAccumulateFromTheCurrentPoint() throws {
        let path = try path("M5 5 l10 0 l0 10 z")
        assertRect(path.boundingBoxOfPath, CGRect(x: 5, y: 5, width: 10, height: 10))
    }

    func testHorizontalAndVerticalLines() throws {
        let absolute = try path("M0 0 H10 V10 H0 z")
        assertRect(absolute.boundingBoxOfPath, CGRect(x: 0, y: 0, width: 10, height: 10))

        let relative = try path("M2 2 h4 v4 h-4 z")
        assertRect(relative.boundingBoxOfPath, CGRect(x: 2, y: 2, width: 4, height: 4))
    }

    func testImplicitRepeatedArgumentsAfterMoveToBecomeLineTos() throws {
        let explicit = try path("M0 0 L10 0 L10 10 z")
        let implicit = try path("M0 0 10 0 10 10 z")
        assertRect(implicit.boundingBoxOfPath, explicit.boundingBoxOfPath)
    }

    func testImplicitRepeatedCurveArguments() throws {
        let explicit = try path("M0 0 C0 5 5 5 5 0 C5 -5 10 -5 10 0")
        let implicit = try path("M0 0 C0 5 5 5 5 0 5 -5 10 -5 10 0")
        assertRect(implicit.boundingBoxOfPath, explicit.boundingBoxOfPath)
        XCTAssertEqual(implicit.currentPoint, explicit.currentPoint)
    }

    func testCubicAndSmoothCubic() throws {
        let path = try path("M0 0 C0 5 5 5 5 0 S10 -5 10 0")
        // The reflected control point mirrors the previous one, so the second
        // half of the S-curve bulges the opposite way.
        assertRect(path.boundingBoxOfPath, CGRect(x: 0, y: -3.75, width: 10, height: 7.5))
        XCTAssertEqual(path.currentPoint.x, 10, accuracy: 0.001)
        XCTAssertEqual(path.currentPoint.y, 0, accuracy: 0.001)
    }

    func testQuadraticAndSmoothQuadratic() throws {
        let path = try path("M0 0 Q5 10 10 0 T20 0")
        assertRect(path.boundingBoxOfPath, CGRect(x: 0, y: -5, width: 20, height: 10))
        XCTAssertEqual(path.currentPoint.x, 20, accuracy: 0.001)
    }

    func testSmoothCurveWithoutAPrecedingCurveUsesTheCurrentPoint() throws {
        // No previous control point to reflect: the anchor is reused, which is
        // the spec's behaviour and must not crash or produce a NaN geometry.
        let path = try path("M0 0 S5 5 10 0")
        XCTAssertFalse(path.isEmpty)
        XCTAssertTrue(path.boundingBoxOfPath.isFinite())
    }

    // MARK: - Arcs

    func testArcSweepDirection() throws {
        // Half-circle from (0,10) to (20,10) with r=10. In SVG's y-down space,
        // sweep=1 bulges toward negative y, sweep=0 toward positive y.
        let sweep = try path("M0 10 A10 10 0 0 1 20 10")
        assertRect(
            sweep.boundingBoxOfPath,
            CGRect(x: 0, y: 0, width: 20, height: 10),
            accuracy: 0.02
        )

        let counterSweep = try path("M0 10 A10 10 0 0 0 20 10")
        assertRect(
            counterSweep.boundingBoxOfPath,
            CGRect(x: 0, y: 10, width: 20, height: 10),
            accuracy: 0.02
        )
    }

    func testArcFlagsMayBeConcatenatedWithoutSeparators() throws {
        // `a5 5 0 015 5` packs large-arc=0, sweep=1 and the endpoint together —
        // exactly how the Claude mark's single arc is written. A naive number
        // scanner would read "01" as the number 1 and lose an argument.
        let packed = try path("M0 0a5 5 0 015 5")
        XCTAssertEqual(packed.currentPoint.x, 5, accuracy: 0.001)
        XCTAssertEqual(packed.currentPoint.y, 5, accuracy: 0.001)

        // Same arc written with every argument separated must be identical.
        let spaced = try path("M0 0 a5 5 0 0 1 5 5")
        assertRect(packed.boundingBoxOfPath, spaced.boundingBoxOfPath)
    }

    func testArcWithZeroRadiusDegradesToALine() throws {
        let arc = try path("M0 0 A0 0 0 0 1 10 10")
        let line = try path("M0 0 L10 10")
        assertRect(arc.boundingBoxOfPath, line.boundingBoxOfPath)
    }

    func testArcRadiiAreScaledUpWhenTooSmallForTheChord() throws {
        // r=1 cannot span a chord of 20; the spec says scale the radii up, which
        // must still land exactly on the endpoint.
        let path = try path("M0 0 A1 1 0 0 1 20 0")
        XCTAssertEqual(path.currentPoint.x, 20, accuracy: 0.001)
        XCTAssertEqual(path.currentPoint.y, 0, accuracy: 0.001)
    }

    func testArcToTheCurrentPointIsSkipped() throws {
        let path = try path("M4 4 A5 5 0 0 1 4 4")
        XCTAssertEqual(path.currentPoint.x, 4, accuracy: 0.001)
        XCTAssertEqual(path.currentPoint.y, 4, accuracy: 0.001)
    }

    // MARK: - Numbers and separators

    func testCommaAndSignSeparatedNumbers() throws {
        let commas = try path("M0,0L10,0L10,10Z")
        assertRect(commas.boundingBoxOfPath, CGRect(x: 0, y: 0, width: 10, height: 10))

        // Implicit separator: a leading '-' terminates the previous number.
        let signs = try path("M0 0l10-10")
        assertRect(signs.boundingBoxOfPath, CGRect(x: 0, y: -10, width: 10, height: 10))
    }

    func testLeadingDotNumbers() throws {
        let path = try path("M.5.5l.25.25")
        assertRect(path.boundingBoxOfPath, CGRect(x: 0.5, y: 0.5, width: 0.25, height: 0.25))
    }

    func testExponentNotation() throws {
        let path = try path("M1e1 1e1 l1E0 1e+0")
        assertRect(path.boundingBoxOfPath, CGRect(x: 10, y: 10, width: 1, height: 1))
    }

    func testEmptyPathDataProducesAnEmptyPath() throws {
        XCTAssertTrue(try path("").isEmpty)
        XCTAssertTrue(try path("   \n ").isEmpty)
    }

    // MARK: - Errors

    func testPathMustStartWithAMoveTo() {
        XCTAssertThrowsError(try path("L10 10")) { error in
            // Offset points at the offending command letter itself (index 0),
            // not one character past it.
            XCTAssertEqual(
                error as? SVGPathParseError,
                .missingInitialMoveTo(offset: 0)
            )
        }
    }

    func testTruncatedCommandThrows() {
        XCTAssertThrowsError(try path("M0 0 L")) { error in
            guard case .missingNumber(let command, _) = error as? SVGPathParseError else {
                return XCTFail("expected missingNumber, got \(error)")
            }
            XCTAssertEqual(command, "L")
        }
    }

    func testUnknownLeadingCharacterThrows() {
        XCTAssertThrowsError(try path("x10 10")) { error in
            XCTAssertEqual(
                error as? SVGPathParseError,
                .unexpectedCharacter("x", offset: 0)
            )
        }
    }

    func testArcRejectsNonBinaryFlags() {
        XCTAssertThrowsError(try path("M0 0 a5 5 0 2 1 5 5")) { error in
            guard case .invalidFlag(let command, _) = error as? SVGPathParseError else {
                return XCTFail("expected invalidFlag, got \(error)")
            }
            XCTAssertEqual(command, "a")
        }
    }

    // MARK: - The generated Claude mark

    func testClaudeMarkParses() {
        XCTAssertNotNil(
            ClaudeMark.cgPath,
            "the generated mark data must parse — regenerate it from assets/claude-mark.svg"
        )
        XCTAssertNoThrow(try SVGPathParser.cgPath(from: ClaudeMark.pathData))
    }

    func testClaudeMarkFillsItsViewBox() throws {
        let bounds = try XCTUnwrap(ClaudeMark.cgPath).boundingBoxOfPath
        // The mark is authored edge-to-edge in a 24×24 box; a mismatch means the
        // path data or the viewBox drifted out of sync.
        assertRect(bounds, ClaudeMark.viewBox, accuracy: 0.01)
    }

    func testClaudeMarkPathIsClosedAndNonTrivial() throws {
        let path = try XCTUnwrap(ClaudeMark.cgPath)
        var elementCount = 0
        path.applyWithBlock { _ in elementCount += 1 }
        XCTAssertGreaterThan(elementCount, 100, "the mark should be a detailed outline")
    }

    // MARK: - Fitting transform

    func testFittingPreservesAspectRatioAndCentres() throws {
        let fitted = try XCTUnwrap(
            ClaudeMark.path(fitting: CGRect(x: 0, y: 0, width: 100, height: 50))
        )
        // Square mark in a 2:1 box → 50×50, horizontally centred.
        assertRect(
            fitted.boundingBoxOfPath,
            CGRect(x: 25, y: 0, width: 50, height: 50),
            accuracy: 0.01
        )
    }

    func testFittingHonoursTheRectOrigin() throws {
        let fitted = try XCTUnwrap(
            ClaudeMark.path(fitting: CGRect(x: 10, y: 4, width: 14, height: 14))
        )
        assertRect(
            fitted.boundingBoxOfPath,
            CGRect(x: 10, y: 4, width: 14, height: 14),
            accuracy: 0.01
        )
    }

    func testFittingADegenerateRectYieldsNoPath() {
        // A zero-sized frame would otherwise scale the mark to a single point;
        // returning nil lets callers skip drawing entirely.
        XCTAssertNil(ClaudeMark.path(fitting: .zero))
        XCTAssertNil(ClaudeMark.path(fitting: CGRect(x: 0, y: 0, width: 0, height: 14)))
        XCTAssertNil(ClaudeMark.path(fitting: CGRect(x: 4, y: 4, width: 14, height: 0)))
    }

    func testFittingATinyRectStillProducesFiniteGeometry() throws {
        let fitted = try XCTUnwrap(
            ClaudeMark.path(fitting: CGRect(x: 0, y: 0, width: 1, height: 1))
        )
        XCTAssertTrue(fitted.boundingBoxOfPath.isFinite())
        XCTAssertFalse(fitted.isEmpty)
    }
}

private extension CGRect {
    func isFinite() -> Bool {
        minX.isFinite && minY.isFinite && width.isFinite && height.isFinite
    }
}
