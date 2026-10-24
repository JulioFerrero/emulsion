import AVFoundation
import CoreMotion

/// Tracks how the phone is physically held, even with rotation lock on, so landscape shots come out landscape.
final class OrientationMonitor {
    private(set) var current: AVCaptureVideoOrientation = .portrait
    private let motion = CMMotionManager()

    func start() {
        guard motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }
        motion.accelerometerUpdateInterval = 0.2
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let g = data?.acceleration else { return }
            // Hysteresis keeps the orientation from flickering near 45 degrees.
            if abs(g.y) > abs(g.x) + 0.2 {
                self.current = g.y < 0 ? .portrait : .portraitUpsideDown
            } else if abs(g.x) > abs(g.y) + 0.2 {
                self.current = g.x < 0 ? .landscapeRight : .landscapeLeft
            }
        }
    }

    func stop() {
        motion.stopAccelerometerUpdates()
    }
}
