import XCTest
@testable import ClaudeStatsCore

/// What ``ModelFamily/inferred(fromModelID:)`` decides, and what it costs.
///
/// Both halves matter here. The function is on the rebuild's hot path — one
/// call per event, on the main thread — so it is written as a UTF-8 scan rather
/// than the obvious `lowercased().contains(_:)`; the tests below pin that the
/// rewrite decides exactly what the obvious version did, and that it is still
/// the cheaper of the two.
final class ModelFamilyInferenceTests: XCTestCase {

    /// The implementation the byte scan replaced, kept as the oracle. Foundation
    /// shadows the stdlib's `contains` with a locale-aware `range(of:options:)`,
    /// so this is the locale-aware search, not a second byte comparison.
    private func lowercasingContains(_ modelID: String) -> ModelFamily? {
        let id = modelID.lowercased()
        return ModelFamily.allCases.first { id.contains($0.rawValue) }
    }

    /// IDs Claude Code has actually written, plus the shapes that probe the
    /// scan's edges: match at the start, at the end, empty, shorter than any
    /// family, repeated and near-miss prefixes.
    private static let probes = [
        "claude-sonnet-5", "claude-opus-5", "claude-haiku-4-5-20251001",
        "claude-fable-5-1", "claude-opus-4-8", "claude-sonnet-4-5-20250929",
        "<synthetic>", "claude-mystery-9", "",
        "CLAUDE-SONNET-5", "Claude-Opus-4-8", "HAIKU-4-5", "FaBlE", "SoNnEt",
        "sonnet", "opus", "haiku", "fable", "s", "x", "claude-",
        "sonne", "sonnnet", "ssonnet", "sssonnet", "sonnetsonnet",
        "claude-3-5-sonnet-20241022", "opus-and-sonnet", "-opus-",
        "clüde-sönnet-5", "🙂-opus-🙂",
    ]

    // MARK: - What it decides

    func testRealisticModelIDsMapToTheirFamily() {
        XCTAssertEqual(ModelFamily.inferred(fromModelID: "claude-sonnet-5"), .sonnet)
        XCTAssertEqual(ModelFamily.inferred(fromModelID: "claude-opus-4-8"), .opus)
        XCTAssertEqual(ModelFamily.inferred(fromModelID: "claude-haiku-4-5-20251001"), .haiku)
        XCTAssertEqual(ModelFamily.inferred(fromModelID: "claude-fable-5-1"), .fable)
    }

    func testCaseIsIgnored() {
        XCTAssertEqual(ModelFamily.inferred(fromModelID: "CLAUDE-SONNET-5"), .sonnet)
        XCTAssertEqual(ModelFamily.inferred(fromModelID: "Claude-Opus-4-8"), .opus)
        XCTAssertEqual(ModelFamily.inferred(fromModelID: "HaIkU"), .haiku)
    }

    func testUnrecognisedIDsInferNothing() {
        // `<synthetic>` is Claude Code's own placeholder and reaches this
        // function on every corpus; the rest stand in for a family shipped after
        // this version.
        XCTAssertNil(ModelFamily.inferred(fromModelID: "<synthetic>"))
        XCTAssertNil(ModelFamily.inferred(fromModelID: "claude-mystery-9"))
        XCTAssertNil(ModelFamily.inferred(fromModelID: ""))
        XCTAssertNil(ModelFamily.inferred(fromModelID: "son"))
    }

    func testAnIDNamingTwoFamiliesTakesTheFirstInDeclarationOrder() {
        // Not arbitrary: `allCases` order is the tie-break, and a scan that
        // returned the *earliest match in the string* instead would quietly
        // reclassify such an ID — and misprice it, since the families bill
        // differently.
        XCTAssertEqual(ModelFamily.allCases, [.sonnet, .opus, .haiku, .fable])
        XCTAssertEqual(ModelFamily.inferred(fromModelID: "opus-and-sonnet"), .sonnet)
        XCTAssertEqual(ModelFamily.inferred(fromModelID: "haiku-then-opus"), .opus)
    }

    /// The rewrite's actual risk: not that it is wrong on the four IDs above,
    /// but that it disagrees with the locale-aware search somewhere off the
    /// happy path. Non-ASCII probes are in the set for that reason — ASCII case
    /// folding is a narrower rule than `lowercased()`, and this is what says the
    /// difference cannot reach a model ID.
    func testInferenceAgreesWithTheSearchItReplacedOnEveryIDThatCanOccur() {
        for probe in Self.probes {
            XCTAssertEqual(
                ModelFamily.inferred(fromModelID: probe),
                lowercasingContains(probe),
                "byte scan disagrees with the locale-aware search for \(probe.debugDescription)"
            )
        }
    }

    /// The one input the two decide differently, pinned rather than left to be
    /// discovered: a family token carrying a combining mark. Foundation's search
    /// compares grapheme clusters, so `t` + U+0301 is not the `t` of `sonnet`
    /// and it matches nothing; the byte scan sees `sonnet`'s bytes and matches.
    ///
    /// Out of reach of a real model ID — Claude Code writes those as ASCII — and
    /// the looser answer is the more useful one of the two, but it is a genuine
    /// difference and belongs in the record.
    func testACombiningMarkIsTheOneDivergenceFromTheOldSearch() {
        let decorated = "sonnet\u{0301}"
        XCTAssertEqual(ModelFamily.inferred(fromModelID: decorated), .sonnet)
        XCTAssertNil(lowercasingContains(decorated))
    }

    // MARK: - What it costs

    /// `inferred(fromModelID:)` is called once per event per rebuild, from
    /// ``UsageEvent/estimatedCostUSD`` and from both folds in
    /// `LocalLogUsageStore` — on the main thread, so its cost is popover stall.
    ///
    /// The guard is differential rather than a nanosecond budget, for the same
    /// reason as `testCorpusScanStaysLinearInBridgingCost`: the regression it
    /// catches is a constant factor, and timing both implementations in one run
    /// takes the machine out of the comparison.
    ///
    /// **Release only, and that is not a convenience.** `-Onone` does not merely
    /// dilute the ratio here, it inverts it: the hand-written scan is Swift that
    /// wants optimising, while `lowercased().contains(_:)` is one call into
    /// system code that ships optimised regardless. Measured debug, the scan is
    /// ~3 600 ns/call against the old ~1 300 — 2.7x *slower*. A debug assertion
    /// would therefore have to be either false or vacuous.
    ///
    /// So it skips, and today it always skips: `swift test -c release` does
    /// not build this package, because `ClaudeStatsTests` uses `AppModel`'s
    /// preview helpers and those live under `#if DEBUG`. That predates this
    /// test and is nobody's emergency, but it does mean the ratio asserted
    /// below was taken with the standalone benchmark described in the commit
    /// rather than by this test — and that fixing the release build turns
    /// this on.
    func testInferenceCostsFarLessThanTheSearchItReplaced() throws {
        try XCTSkipIf(isDebugBuild, """
            measures nothing under -Onone, where the byte scan is the slower \
            of the two; needs `swift test -c release`, which does not \
            currently build — ClaudeStatsTests uses AppModel's `#if DEBUG` \
            preview helpers
            """)

        let ids = Self.probes
        let iterations = 20_000
        // Consumed and asserted on below: without a use for the results, the
        // optimiser is free to delete the very loops being timed.
        var matches = 0

        func best(_ body: (String) -> ModelFamily?) -> Duration {
            for id in ids { _ = body(id) }  // warm
            var best: Duration = .seconds(3600)
            for _ in 0..<5 {
                let start = ContinuousClock.now
                for index in 0..<iterations where body(ids[index % ids.count]) != nil {
                    matches += 1
                }
                best = min(best, ContinuousClock.now - start)
            }
            return best
        }

        let byteScan = best(ModelFamily.inferred(fromModelID:))
        let localeAware = best(lowercasingContains)

        func nanosecondsPerCall(_ duration: Duration) -> Double {
            let seconds = Double(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1e18
            return seconds / Double(iterations) * 1e9
        }
        print(String(
            format: "[perf] family inference %.0f ns/call (locale-aware search: %.0f ns/call)",
            nanosecondsPerCall(byteScan), nanosecondsPerCall(localeAware)
        ))
        XCTAssertGreaterThan(matches, 0, "the timed loops were optimised away")

        // Measured release: ~35 ns/call against ~1 200, a factor of ~34. The
        // threshold sits at 8 — far below what this change actually bought, and
        // far above the ratio of 1 that putting `lowercased().contains` back
        // would produce.
        XCTAssertLessThan(
            byteScan * 8, localeAware,
            """
            family inference took \(byteScan) for \(iterations) calls against \
            \(localeAware) for the locale-aware search it replaced — less than \
            8x apart, so it is paying for `lowercased()` and Foundation's \
            `range(of:)` again
            """
        )
    }
}

/// Whether this build is the unoptimised one. SwiftPM defines `DEBUG` for
/// `swift test` and not for `swift test -c release`, which is exactly the
/// distinction the cost test needs.
private let isDebugBuild: Bool = {
    #if DEBUG
    return true
    #else
    return false
    #endif
}()
