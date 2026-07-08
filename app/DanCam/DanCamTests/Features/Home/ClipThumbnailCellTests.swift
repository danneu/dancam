import Foundation
import Testing
import UIKit
@testable import DanCam

@MainActor
struct ClipThumbnailCellTests {
    @Test(.timeLimit(.minutes(1)))
    func repeatedSameIdentityConfigureStartsExactlyOneLoad() async throws {
        let probe = CellLoaderProbe()
        let loader = probe.loader()
        let cell = ClipThumbnailCell(style: .default, reuseIdentifier: "c")

        cell.configure(clip: clip(id: 7, etag: "7-100"), loader: loader)
        try await waitUntil { probe.callCount() == 1 }
        cell.configure(clip: clip(id: 7, etag: "7-100"), loader: loader)

        try await settle()
        #expect(probe.callCount() == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func differentIdentityCancelsFirstLoadAndStartsOneNewLoad() async throws {
        let probe = CellLoaderProbe()
        let loader = probe.loader()
        let cell = ClipThumbnailCell(style: .default, reuseIdentifier: "c")

        cell.configure(clip: clip(id: 7, etag: "7-100"), loader: loader)
        try await waitUntil { probe.callCount() == 1 }

        cell.configure(clip: clip(id: 8, etag: "8-100"), loader: loader)

        try await waitUntil { probe.wasCancelled(0) }
        try await waitUntil { probe.callCount() == 2 }
    }

    @Test(.timeLimit(.minutes(1)))
    func successfulLoadThenSameIdentityConfigureIsNoOp() async throws {
        let probe = CellLoaderProbe()
        let loader = probe.loader()
        let cell = ClipThumbnailCell(style: .default, reuseIdentifier: "c")

        cell.configure(clip: clip(id: 7, etag: "7-100"), loader: loader)
        try await waitUntil { probe.callCount() == 1 }

        await probe.release(0, image: ThumbnailImage(image: UIImage()))
        try await waitUntil { cell.displayedImageForTesting != nil }

        cell.configure(clip: clip(id: 7, etag: "7-100"), loader: loader)
        try await settle()
        #expect(probe.callCount() == 1)  // painted image keeps it from reloading
    }

    @Test(.timeLimit(.minutes(1)))
    func nilLoadThenSameIdentityConfigureRetries() async throws {
        let probe = CellLoaderProbe()
        let loader = probe.loader()
        let cell = ClipThumbnailCell(style: .default, reuseIdentifier: "c")

        cell.configure(clip: clip(id: 7, etag: "7-100"), loader: loader)
        try await waitUntil { probe.callCount() == 1 }

        await probe.release(0, image: nil)
        try await waitUntil { cell.isLoadingForTesting == false }  // completion ran, handle cleared, nothing painted

        cell.configure(clip: clip(id: 7, etag: "7-100"), loader: loader)
        try await waitUntil { probe.callCount() == 2 }  // a persistent miss retries once
    }

    @Test(.timeLimit(.minutes(1)))
    func staleCompletionOfSupersededLoadDoesNotNullTheNewHandle() async throws {
        let probe = CellLoaderProbe()
        let loader = probe.loader()
        let cell = ClipThumbnailCell(style: .default, reuseIdentifier: "c")

        cell.configure(clip: clip(id: 7, etag: "7-100"), loader: loader)  // load 0 (identity A)
        try await waitUntil { probe.callCount() == 1 }
        cell.configure(clip: clip(id: 8, etag: "8-100"), loader: loader)  // cancels 0, load 1 (identity B)
        try await waitUntil { probe.callCount() == 2 }

        // Load 0 resolves *after* load 1 is installed: its stale completion must not null load 1.
        await probe.release(0, image: ThumbnailImage(image: UIImage()))
        try await settle()
        #expect(cell.isLoadingForTesting == true)  // load 1's handle intact

        cell.configure(clip: clip(id: 8, etag: "8-100"), loader: loader)  // still parked -> no-op
        try await settle()
        #expect(probe.callCount() == 2)  // no third load
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelLoadThenRetryStaleCompletionDoesNotNullTheRetryHandle() async throws {
        let probe = CellLoaderProbe()
        let loader = probe.loader()
        let cell = ClipThumbnailCell(style: .default, reuseIdentifier: "c")

        cell.configure(clip: clip(id: 7, etag: "7-100"), loader: loader)  // load 0
        try await waitUntil { probe.callCount() == 1 }

        cell.cancelLoad()  // advances the token, keeps identity A
        try await waitUntil { probe.wasCancelled(0) }

        cell.configure(clip: clip(id: 7, etag: "7-100"), loader: loader)  // same-identity retry, load 1
        try await waitUntil { probe.callCount() == 2 }

        // Load 0 (still identity A) resolves after load 1: it may paint, but must not null load 1.
        await probe.release(0, image: ThumbnailImage(image: UIImage()))
        try await waitUntil { cell.displayedImageForTesting != nil }
        #expect(cell.isLoadingForTesting == true)  // load 1's handle intact

        cell.configure(clip: clip(id: 7, etag: "7-100"), loader: loader)  // still parked -> no-op
        try await settle()
        #expect(probe.callCount() == 2)  // no third load
    }

    @Test func configureUsesTimeOfDayAndDurationSubtitle() throws {
        let cell = ClipThumbnailCell(style: .default, reuseIdentifier: "c")
        let clip = clip(
            id: 7,
            startMs: 1_767_225_600_000,
            durMs: 30_000,
            bytes: 1_234_567,
            etag: "7-100",
            timeApproximate: false
        )

        cell.configure(clip: clip, loader: .noop)

        let subtitle = try #require(cell.subtitleTextForTesting)
        #expect(subtitle.range(of: #"^\d{2}:\d{2}:\d{2} · 00:30$"#, options: .regularExpression) != nil)
        #expect(subtitle.contains("2026") == false)
        #expect(subtitle.contains(Formatters.byteSize(clip.bytes)) == false)
    }

    @Test func configureOmitsEmptySubtitleFromAccessibilityLabel() {
        let cell = ClipThumbnailCell(style: .default, reuseIdentifier: "c")

        cell.configure(
            clip: clip(id: 8, startMs: nil, durMs: nil, bytes: 1, etag: "8-100", timeApproximate: false),
            loader: .noop
        )

        #expect(cell.subtitleTextForTesting?.isEmpty == true)
        #expect(cell.accessibilityLabel == "seg_00008.ts")
    }

    // MARK: - Helpers

    private func clip(id: Int, etag: String) -> Clip {
        clip(id: id, startMs: nil, durMs: 30_000, bytes: 1, etag: etag, timeApproximate: false)
    }

    private func clip(
        id: Int,
        startMs: UInt64?,
        durMs: UInt64?,
        bytes: UInt64,
        etag: String,
        timeApproximate: Bool
    ) -> Clip {
        Clip(
            id: id,
            startMs: startMs,
            durMs: durMs,
            bytes: bytes,
            locked: false,
            etag: etag,
            timeApproximate: timeApproximate
        )
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(40))
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for condition.")
    }
}

/// A `ThumbnailLoader` whose `thumbnail` closure records each call, parks until the test
/// releases it, and reports observed cancellation -- so the tests can drive the cell's
/// single-task state machine deterministically. Prefetch is inert (unused here).
private final class CellLoaderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var signals: [AsyncSignal] = []
    private var results: [ThumbnailImage?] = []
    private var cancelled: [Bool] = []

    func loader() -> ThumbnailLoader {
        ThumbnailLoader(
            thumbnail: { [self] _ in
                let index = beginCall()
                let signal = signal(at: index)
                await withTaskCancellationHandler {
                    await signal.wait()
                } onCancel: {
                    markCancelled(at: index)
                }
                return result(at: index)
            },
            prefetch: { _ in .inert }
        )
    }

    func callCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return signals.count
    }

    func wasCancelled(_ index: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled.indices.contains(index) && cancelled[index]
    }

    func release(_ index: Int, image: ThumbnailImage?) async {
        let signal = storeResult(index, image)
        await signal.signal()
    }

    private func storeResult(_ index: Int, _ image: ThumbnailImage?) -> AsyncSignal {
        lock.lock(); defer { lock.unlock() }
        results[index] = image
        return signals[index]
    }

    private func beginCall() -> Int {
        lock.lock(); defer { lock.unlock() }
        signals.append(AsyncSignal())
        results.append(nil)
        cancelled.append(false)
        return signals.count - 1
    }

    private func signal(at index: Int) -> AsyncSignal {
        lock.lock(); defer { lock.unlock() }
        return signals[index]
    }

    private func markCancelled(at index: Int) {
        lock.lock(); defer { lock.unlock() }
        cancelled[index] = true
    }

    private func result(at index: Int) -> ThumbnailImage? {
        lock.lock(); defer { lock.unlock() }
        return results[index]
    }
}
