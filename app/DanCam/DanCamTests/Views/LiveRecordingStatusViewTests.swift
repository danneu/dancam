import Testing
import UIKit
@testable import DanCam

@MainActor
struct LiveRecordingStatusViewTests {
    @Test func configurePendingResetsGrayFrozenBadgeToRed() {
        let clock = ContinuousClock()
        let view = LiveRecordingStatusView()
        let frozen = LiveSegment(
            sessionId: 7,
            id: 43,
            elapsed: .frozen(durMs: 1_000)
        )

        view.configure(status: .live(frozen), now: clock.now)
        #expect(colorMatches(view.recBadgeForTesting.dotColorForTesting, .systemGray))

        view.configure(status: .pending, now: clock.now)

        #expect(colorMatches(view.recBadgeForTesting.dotColorForTesting, .systemRed))
        #expect(view.elapsedTextForTesting == "00:00")
        #expect(view.accessibilityLabel == "Starting recording")
    }

    @Test func timerStartsOnlyForTickingLiveStatusWhileInAWindow() throws {
        let clock = ContinuousClock()
        let now = clock.now
        let ticking = LiveSegment(
            sessionId: 7,
            id: 43,
            elapsed: .ticking(seedDurMs: 1_000, anchor: now)
        )
        let frozen = LiveSegment(
            sessionId: 7,
            id: 43,
            elapsed: .frozen(durMs: 1_000)
        )
        let view = LiveRecordingStatusView()

        view.configure(status: .live(ticking), now: now)
        #expect(view.isTickTimerRunningForTesting == false)

        let window = try embed(view)
        defer { window.isHidden = true }

        #expect(view.isTickTimerRunningForTesting)

        view.configure(status: .live(frozen), now: now)
        #expect(view.isTickTimerRunningForTesting == false)

        view.configure(status: .pending, now: now)
        #expect(view.isTickTimerRunningForTesting == false)

        view.configure(status: .live(ticking), now: now)
        #expect(view.isTickTimerRunningForTesting)

        view.removeFromSuperview()
        #expect(view.isTickTimerRunningForTesting == false)
    }

    private func embed(_ view: UIView) throws -> UIWindow {
        let windowScene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIViewController()
        view.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(view)

        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.view.topAnchor),
        ])

        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 120)
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    private func colorMatches(_ color: UIColor?, _ expected: UIColor) -> Bool {
        colorComponents(color) == colorComponents(expected)
    }

    private func colorComponents(_ color: UIColor?) -> [Int]? {
        guard let color else { return nil }

        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }

        return [red, green, blue, alpha].map { Int(($0 * 1_000).rounded()) }
    }
}
