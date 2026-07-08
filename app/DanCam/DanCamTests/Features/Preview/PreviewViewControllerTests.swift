import Foundation
import Testing
import UIKit
@testable import DanCam

@MainActor
struct PreviewViewControllerTests {
    @Test func phasePresentationFollowsPreviewState() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        let frame = PreviewFrame(sequence: 0, jpeg: Data("jpeg".utf8))

        controller.applyForTesting(PreviewFeature.State(phase: .streaming(frame)))

        #expect(controller.placeholderStateForTesting == .hidden)
        #expect(controller.statusCaptionForTesting == "Live")

        controller.applyForTesting(PreviewFeature.State(phase: .connecting))

        #expect(controller.placeholderStateForTesting == .spinner)
        #expect(controller.statusCaptionForTesting == "Connecting")
        #expect(controller.displayedImageForTesting == nil)

        controller.applyForTesting(PreviewFeature.State(phase: .failed("HTTP 503")))

        #expect(controller.placeholderStateForTesting == .glyph)
        #expect(controller.statusCaptionForTesting == "Preview offline")
        #expect(controller.displayedImageForTesting == nil)

        controller.applyForTesting(PreviewFeature.State(phase: .idle))

        #expect(controller.placeholderStateForTesting == .glyph)
        #expect(controller.statusCaptionForTesting == nil)
        #expect(controller.displayedImageForTesting == nil)

        controller.applyForTesting(PreviewFeature.State(phase: .stopped))

        #expect(controller.placeholderStateForTesting == .glyph)
        #expect(controller.statusCaptionForTesting == nil)
        #expect(controller.displayedImageForTesting == nil)
    }

    @Test func nonStreamingPresentationClearsDisplayedImage() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        let image = testImage()

        controller.seedDisplayedImageForTesting(image)
        controller.applyForTesting(PreviewFeature.State(phase: .stopped))

        #expect(controller.displayedImageForTesting == nil)

        controller.seedDisplayedImageForTesting(image)
        controller.applyForTesting(PreviewFeature.State(phase: .failed("HTTP 503")))

        #expect(controller.displayedImageForTesting == nil)
    }

    private func makeController() -> PreviewViewController {
        PreviewViewController(dependencies: AppDependencies(
            health: HealthClient(fetch: { fatalError("Health should not be called.") })
        ))
    }

    private func testImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        return renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }
}
