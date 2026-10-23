import CoreMotion
import CyberSendFeatures
import Foundation

// Device motion for the level badge. CoreMotion is iOS only, so this lives in the app target
// rather than the package; the roll math itself is in CaptureLevel and unit tested there.
//
// The monitor publishes nothing when the hardware cannot provide device motion (the simulator,
// or a device with a broken gyro). The recorder screen then says the level hint is unavailable
// instead of showing a stuck green badge.

@MainActor
final class MotionLevelMonitor: ObservableObject {
    @Published private(set) var level: CaptureLevel?
    @Published private(set) var isAvailable: Bool

    private let manager = CMMotionManager()

    init() {
        isAvailable = manager.isDeviceMotionAvailable
    }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 0.1
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            let gravity = motion.gravity
            let level = CaptureLevel(
                gravity: GravityVector(x: gravity.x, y: gravity.y, z: gravity.z)
            )
            Task { @MainActor in
                self?.level = level
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        level = nil
    }
}
