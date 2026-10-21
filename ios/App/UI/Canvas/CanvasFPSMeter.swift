import Foundation
import QuartzCore
import UIKit

// DEVELOPMENT only canvas FPS meter (M3, US-18.3, docs/architecture.md test strategy:
// "DEVELOPMENT FPS HUD (CADisplayLink) plus a seeded 100 hold fixture"). A CADisplayLink
// counts frames on the main run loop and publishes a one second rolling sample; the HUD
// label lives in the tagging canvas corner and never intercepts touches. Internal and
// Release compile this whole file out, so the meter is unreachable in a shipped app.
//
// Usage: run a Development build with "-CYBERSEND_FPS_HUD" or the 100 hold seed
// "-CYBERSEND_UI_TEST_SEED_HOLDS 100", pan and zoom the canvas, and read the rolling
// average. The simulator is a documented proxy; dogfood on device for the real budget.
//
// The launch argument that turns the HUD on in a Development build.
let canvasFPSMeterArgument = "-CYBERSEND_FPS_HUD"

#if DEVELOPMENT
final class CanvasFPSMeter: NSObject {
    private var displayLink: CADisplayLink?
    private var frameCount = 0
    private var windowStart: CFTimeInterval = 0

    /// The latest one second rolling average, in frames per second.
    private(set) var fps: Double = 0

    /// Called on the main actor once per second with the rolling sample.
    var onSample: ((Double) -> Void)?

    func start() {
        guard displayLink == nil else { return }
        frameCount = 0
        windowStart = 0
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step() {
        frameCount += 1
        let now = CACurrentMediaTime()
        if windowStart == 0 {
            windowStart = now
            return
        }
        let elapsed = now - windowStart
        guard elapsed >= 1 else { return }
        fps = Double(frameCount) / elapsed
        frameCount = 0
        windowStart = now
        onSample?(fps)
    }
}

/// The HUD label pinned to the canvas corner. Plain UIKit so it composites with the
/// canvas without any SwiftUI state churn per frame.
final class CanvasFPSLabel: UILabel {
    override init(frame: CGRect) {
        super.init(frame: frame)
        font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        textColor = .white
        backgroundColor = UIColor.black.withAlphaComponent(0.65)
        textAlignment = .center
        layer.cornerRadius = 6
        layer.masksToBounds = true
        isUserInteractionEnabled = false
        accessibilityIdentifier = "tagging.fps"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(fps: Double, holdCount: Int) {
        text = String(format: "%.1f fps, %d holds", fps, holdCount)
        sizeToFit()
        bounds = bounds.insetBy(dx: -8, dy: -4)
    }
}
#endif
