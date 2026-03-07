import CoreGraphics
import Testing
@testable import PeekabooAutomationKit

@Suite("Gesture Playback Plan Tests")
struct GesturePlaybackPlanTests {
    @Test("Interpolates path at uniform time slices")
    func interpolatesPathAtUniformTimeSlices() {
        let plan = GesturePlaybackPlan(
            sourcePoints: [
                CGPoint(x: 0, y: 0),
                CGPoint(x: 0, y: 100),
                CGPoint(x: 100, y: 100),
            ],
            duration: 1_000,
            targetFrameIntervalMilliseconds: 250,
            maximumSegmentLength: 1_000,
            maximumSamples: 16)

        #expect(plan.samples.count == 4)
        #expect(plan.samples[0] == CGPoint(x: 0, y: 50))
        #expect(plan.samples[1] == CGPoint(x: 0, y: 100))
        #expect(plan.samples[2] == CGPoint(x: 50, y: 100))
        #expect(plan.samples[3] == CGPoint(x: 100, y: 100))
    }

    @Test("Increases density for long segments")
    func increasesDensityForLongSegments() {
        let plan = GesturePlaybackPlan(
            sourcePoints: [
                CGPoint(x: 0, y: 0),
                CGPoint(x: 300, y: 0),
            ],
            duration: 16,
            targetFrameIntervalMilliseconds: 16,
            maximumSegmentLength: 60,
            maximumSamples: 16)

        #expect(plan.samples.count == 5)
        #expect(plan.samples.last == CGPoint(x: 300, y: 0))
    }

    @Test("Collapses zero-duration playback to final point")
    func collapsesZeroDurationPlaybackToFinalPoint() {
        let plan = GesturePlaybackPlan(
            sourcePoints: [
                CGPoint(x: 10, y: 20),
                CGPoint(x: 30, y: 40),
            ],
            duration: 0)

        #expect(plan.samples == [CGPoint(x: 30, y: 40)])
        #expect(plan.scheduledOffsetNanoseconds(for: 0) == 0)
    }
}
