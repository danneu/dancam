import UIKit
@testable import DanCam

@MainActor
final class VideoSharePresentationSpy {
    private(set) var presentedURL: URL?
    private var completion: VideoSharePresentation.Completed?

    lazy var presentation = VideoSharePresentation { [weak self] url, _, ready, completed in
        self?.presentedURL = url
        self?.completion = completed
        ready()
    }

    func complete() {
        completion?()
        completion = nil
    }
}
