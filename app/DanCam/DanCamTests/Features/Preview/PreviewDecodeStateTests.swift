import Foundation
import Testing
@testable import DanCam

struct PreviewDecodeStateTests {
    @Test func newStreamAcceptsFramesWhoseSequenceRestartsAtZero() {
        var state = PreviewDecodeState()
        let firstFrame = PreviewFrame(sequence: 0, jpeg: Data("first".utf8))
        let restartedFrame = PreviewFrame(sequence: 0, jpeg: Data("restarted".utf8))

        state.enqueue(firstFrame)
        let firstDecode = state.startNextDecode()
        let firstRendered = state.finishDecode(generation: firstDecode?.generation ?? -1, sequence: firstFrame.sequence)

        #expect(firstDecode?.frame == firstFrame)
        #expect(firstRendered)
        #expect(state.latestRenderedSequence == 0)

        state.beginNewStream()
        state.enqueue(restartedFrame)
        let restartedDecode = state.startNextDecode()
        let restartedRendered = state.finishDecode(
            generation: restartedDecode?.generation ?? -1,
            sequence: restartedFrame.sequence
        )

        #expect(restartedDecode?.frame == restartedFrame)
        #expect(restartedRendered)
        #expect(state.latestRenderedSequence == 0)
    }

    @Test func staleDecodeFromPreviousStreamCannotRenderAfterRestart() {
        var state = PreviewDecodeState()
        let oldFrame = PreviewFrame(sequence: 4, jpeg: Data("old".utf8))
        let newFrame = PreviewFrame(sequence: 0, jpeg: Data("new".utf8))

        state.enqueue(oldFrame)
        let oldDecode = state.startNextDecode()
        state.beginNewStream()
        let oldRendered = state.finishDecode(generation: oldDecode?.generation ?? -1, sequence: oldFrame.sequence)

        #expect(oldRendered == false)
        #expect(state.latestRenderedSequence == -1)

        state.enqueue(newFrame)
        let newDecode = state.startNextDecode()
        let newRendered = state.finishDecode(generation: newDecode?.generation ?? -1, sequence: newFrame.sequence)

        #expect(newDecode?.frame == newFrame)
        #expect(newRendered)
        #expect(state.latestRenderedSequence == 0)
    }
}
