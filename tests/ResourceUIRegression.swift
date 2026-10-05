// Standalone check: compile with SettingsWindowController.swift,
// MenuBarItemImageCache.swift and the two MenuBar/Models files; link Sparkle.
import AppKit
import SwiftUI
import Sparkle

struct SettingsView: View {
    let updaterController: SPUStandardUpdaterController?
    var body: some View { Text("Settings lifecycle regression") }
}

final class ScreenCaptureVisibilityManager {
    static let shared = ScreenCaptureVisibilityManager()
    enum Scope { case panelsOnly }
    func register(_ window: NSWindow, scope: Scope) {}
    func unregister(_ window: NSWindow) {}
}

func AppIconAsNSImage(for bundleID: String) -> NSImage? { nil }

@main
struct ResourceUIRegression {
    @MainActor static func main() {
        _ = NSApplication.shared
        let controller = SettingsWindowController.shared
        assert(controller.window == nil, "Settings must not load at startup")
        for _ in 0..<20 {
            weak var content: NSView?
            autoreleasepool {
                controller.showWindow()
                content = controller.window?.contentView
                assert(content != nil)
                controller.close()
                assert(controller.window?.contentView == nil)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            assert(content == nil, "Closed settings content must be released")
        }
        let item = ManagedMenuBarItem(
            identity: .init(bundleIdentifier: "example.app", title: "Example", ownerName: "Example"),
            windowID: 1, ownerPID: 1, frame: CGRect(x: 0, y: 0, width: 20, height: 20),
            displayName: "Example", bundleIdentifier: "example.app", ownerName: "Example", isOnScreen: true
        )
        let cache = MenuBarItemImageCache()
        cache.refresh(for: [item])
        let original = cache.image(for: item)
        assert(original != nil)
        cache.refresh(for: [item])
        assert(cache.image(for: item) === original)
        cache.refresh(for: [])
        assert(cache.images.isEmpty)
        print("PASS: lazy settings, 20 release/reopen cycles, icon reuse and eviction")
    }
}
