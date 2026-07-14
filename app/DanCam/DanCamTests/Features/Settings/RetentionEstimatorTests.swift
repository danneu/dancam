import Testing
@testable import DanCam

struct RetentionEstimatorTests {
    @Test func rejectsIneligibleSamples() {
        var estimator = RetentionEstimator()
        for clip in [
            sample(bytes: 1_000, duration: 24_999),
            sample(bytes: 1_000, duration: 35_001),
            sample(bytes: 1_000, duration: nil),
            sample(bytes: 0, duration: 30_000),
        ] {
            estimator.observe(clip)
        }

        #expect(estimator.maxBytesPerSecond == nil)
    }

    @Test func normalizesDurationAndKeepsMaximumRate() {
        var estimator = RetentionEstimator()
        estimator.observe(sample(bytes: 25_000, duration: 25_000))
        estimator.observe(sample(bytes: 70_000, duration: 35_000))
        estimator.observe(sample(bytes: 30_000, duration: 30_000))

        #expect(estimator.maxBytesPerSecond == 2_000)
        #expect(estimator.estimatedDurationMs(capacityBytes: 7_200_000) == 3_600_000)
    }

    @Test func resetStartsANewEstimatorEpoch() {
        var estimator = RetentionEstimator()
        estimator.observe(sample(bytes: 60_000, duration: 30_000))
        estimator.reset()

        #expect(estimator.maxBytesPerSecond == nil)
        #expect(estimator.estimatedDurationMs(capacityBytes: 1_000_000) == nil)
    }

    @Test func deterministicMockSampleFormatsAsTwentyThreeHours() throws {
        var estimator = RetentionEstimator()
        estimator.observe(sample(bytes: 56_776, duration: 30_100))
        let duration = try #require(estimator.estimatedDurationMs(capacityBytes: 162_432_000))

        #expect(Formatters.estimatedFootage(duration).display == "About 23 hours")
    }

    @Test func zeroCapacityIsReadyAndHugeDurationsClamp() {
        var estimator = RetentionEstimator()
        estimator.observe(sample(bytes: 1, duration: 35_000))

        #expect(estimator.estimatedDurationMs(capacityBytes: 0) == 0)
        #expect(estimator.estimatedDurationMs(capacityBytes: .max) == .max)
    }

    private func sample(bytes: UInt64, duration: UInt64?) -> Clip {
        Clip(
            id: 1,
            startMs: nil,
            durMs: duration,
            bytes: bytes,
            locked: false,
            etag: "1-\(bytes)",
            timeApproximate: true
        )
    }
}
