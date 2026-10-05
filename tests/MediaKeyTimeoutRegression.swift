// Compile with MediaKeyInterceptor.swift. The OSD stub never touches system processes.
import AppKit

enum AppRuntimeEnvironment {
    static let isUITesting = true
}

enum SystemOSDManager {
    static var restorations = 0
    static func enableSystemHUD() { restorations += 1 }
    static func suppressNativeOSDNow() {}
}

final class MediaKeyDelegateSpy: MediaKeyInterceptorDelegate {
    var commands = 0
    func mediaKeyInterceptor(_ interceptor: MediaKeyInterceptor, didReceiveVolumeCommand direction: MediaKeyDirection,
                             step: MediaKeyStep, isRepeat: Bool, modifiers: NSEvent.ModifierFlags) { commands += 1 }
    func mediaKeyInterceptor(_ interceptor: MediaKeyInterceptor, didReceiveBrightnessCommand direction: MediaKeyDirection,
                             step: MediaKeyStep, isRepeat: Bool, modifiers: NSEvent.ModifierFlags) { commands += 1 }
    func mediaKeyInterceptorDidToggleMute(_ interceptor: MediaKeyInterceptor) { commands += 1 }
}

@main struct MediaKeyTimeoutRegression {
    @MainActor static func main() async {
        _ = NSApplication.shared
        let interceptor = MediaKeyInterceptor.shared
        let delegate = MediaKeyDelegateSpy()
        interceptor.delegate = delegate
        let enabled = MediaKeyConfiguration(interceptVolume: true, interceptBrightness: true,
                                            interceptCommandModifiedBrightness: true)
        interceptor.configuration = enabled
        let key = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [],
                                    timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                    data1: 0xA00, data2: 0)!.cgEvent!
        assert(interceptor.handleEvent(cgEvent: key, type: key.type) == nil, "Normal key must be intercepted")
        assert(interceptor.handleEvent(cgEvent: key, type: .tapDisabledByTimeout) != nil)
        assert(SystemOSDManager.restorations == 1, "Timeout must restore native HUD")
        assert(!interceptor.isInterceptionAvailable)
        assert(interceptor.handleEvent(cgEvent: key, type: key.type) != nil, "Keys must pass through after timeout")
        interceptor.stop()
        assert(!interceptor.start(), "Observer restarts must not clear the timeout latch")
        interceptor.configuration = .disabled
        interceptor.configuration = enabled
        _ = interceptor.handleEvent(cgEvent: key, type: .tapDisabledByUserInput)
        assert(interceptor.handleEvent(cgEvent: key, type: key.type) != nil, "Settings must not re-enable a timed-out tap")
        try? await Task.sleep(for: .milliseconds(100))
        assert(delegate.commands == 0, "Queued hardware commands must be dropped after timeout")
        print("PASS: timed-out tap passes keys through, restores native HUD and drops queued commands")
    }
}
