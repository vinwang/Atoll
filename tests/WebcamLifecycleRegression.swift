// Compile with WebcamManager.swift and the built Defaults module/object.
// Isolated defaults suite; this check never starts a camera while enabled.
import AppKit
import Defaults

private let regressionSuite = UserDefaults(suiteName: "Atoll.WebcamRegression.\(UUID())")!

extension Defaults.Keys {
    static let showMirror = Key<Bool>("showMirror", default: false, suite: regressionSuite)
    static let selectedCameraID = Key<String>("selectedCameraID", default: "", suite: regressionSuite)
}

@main
struct WebcamLifecycleRegression {
    static func drain() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    }

    static func main() {
        _ = NSApplication.shared
        let manager = WebcamManager.shared
        drain()
        assert(manager.availableCameras.isEmpty)
        assert(!manager.cameraAvailable)

        for _ in 0..<3 {
            Defaults[.showMirror] = true
            drain()
            Defaults[.showMirror] = false
            manager.checkCameraAvailability()
            manager.checkAndRequestVideoAuthorization()
            manager.startSession()
            drain()
            assert(manager.availableCameras.isEmpty)
            assert(!manager.cameraAvailable)
            assert(!manager.isSessionRunning)
            assert(manager.previewLayer == nil)
        }
        print("PASS: disabled startup, enable/disable cycles, disabled discovery and capture guards")
    }
}
