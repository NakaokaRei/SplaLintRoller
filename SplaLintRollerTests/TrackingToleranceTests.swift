import CoreGraphics
import Testing
@testable import SplaLintRoller

struct TrackingToleranceTests {
    private let box = CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2)

    @Test func moderateConfidenceCanContinueButLowConfidenceCannotPaint() {
        #expect(TrackingTolerance.isUsable(confidence: 0.5, screenRect: box))
        #expect(!TrackingTolerance.isUsable(confidence: 0.3, screenRect: box))
        #expect(!TrackingTolerance.isUsable(confidence: .nan, screenRect: box))
    }

    @Test func touchingScreenEdgeDoesNotImmediatelyLoseTracking() {
        let touching = CGRect(x: 0, y: 0.2, width: 0.2, height: 0.2)
        let slightClipping = CGRect(x: -0.02, y: 0.2, width: 0.2, height: 0.2)
        #expect(TrackingTolerance.isUsable(confidence: 0.7, screenRect: touching))
        #expect(TrackingTolerance.isUsable(confidence: 0.7, screenRect: slightClipping))
    }

    @Test func offscreenContactAndMostlyHiddenBoxAreRejected() {
        let hiddenContact = CGRect(x: 0.2, y: 0.9, width: 0.2, height: 0.2)
        let mostlyHidden = CGRect(x: -0.12, y: 0.2, width: 0.2, height: 0.2)
        #expect(!TrackingTolerance.isUsable(confidence: 0.9, screenRect: hiddenContact))
        #expect(!TrackingTolerance.isUsable(confidence: 0.9, screenRect: mostlyHidden))
        #expect(!TrackingTolerance.isUsable(confidence: 0.9, screenRect: .null))
    }

    @Test func briefBadIntervalKeepsSequenceAliveButLongLossExpires() {
        var tolerance = TrackingTolerance()
        tolerance.begin(at: 0)
        #expect(!tolerance.hasExpired(at: 0.5))
        #expect(!tolerance.hasExpired(at: 0.7))
        #expect(tolerance.hasExpired(at: 0.8))
        // Checking a bad sample must not extend the deadline.
        #expect(tolerance.lastGoodTime == 0)
    }

    @Test func validSampleWithinGraceExtendsTracking() {
        var tolerance = TrackingTolerance()
        tolerance.begin(at: 0)
        tolerance.accept(at: 0.6)
        #expect(!tolerance.hasExpired(at: 1.2))
        #expect(tolerance.hasExpired(at: 1.4))
        tolerance.reset()
        #expect(tolerance.lastGoodTime == nil)
    }

    @Test func slightlyDelayedResultsAreAllowedButStaleOrFutureResultsAreRejected() {
        #expect(TrackingTolerance.isFresh(sampleTime: 1, currentTime: 1.4))
        #expect(!TrackingTolerance.isFresh(sampleTime: 1, currentTime: 1.6))
        #expect(!TrackingTolerance.isFresh(sampleTime: 2, currentTime: 1))
        #expect(!TrackingTolerance.isFresh(sampleTime: 1, currentTime: .nan))
    }

    @Test func gracePeriodNeverConnectsInkAcrossUncertainSamples() {
        var stroke = StrokeBuilder()
        _ = stroke.append(.zero, at: 0)
        _ = stroke.append(SIMD3(0.05, 0, 0), at: 0.1)
        // This is the operation performed immediately on entry to the grace period.
        stroke.breakStroke()
        guard case .accepted(let segments) = stroke.append(SIMD3(0.3, 0, 0), at: 0.6) else {
            Issue.record("A stable sample starts a new stroke after uncertainty")
            return
        }
        #expect(segments.isEmpty)
    }
}
