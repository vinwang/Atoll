// Read-only compatibility probe. Compile with MenuBar/Core/{MenuBarItemScanner,
// MenuBarWindowBridge,MenuBarWindowInfo,MenuBarOverflowBoundary}.swift and
// MenuBar/Models/*.swift.
import AppKit

enum Logger {
    enum Category { case debug }
    static func log(_ message: String, category: Category) {}
}

@main struct MenuBarDiscoveryProbe {
    @MainActor static func main() async {
        _ = NSApplication.shared
        let identity = MenuBarItemIdentity(bundleIdentifier: "test.app", title: "Test", ownerName: "Test")
        let window = ManagedMenuBarItem(identity: identity, windowID: 1, ownerPID: 1,
            frame: CGRect(x: 100, y: 0, width: 24, height: 24), displayName: "Test",
            bundleIdentifier: "test.app", ownerName: "Test", isOnScreen: true)
        let axOnly = ManagedMenuBarItem(
            identity: .init(bundleIdentifier: "test.other", title: "Other", ownerName: "Other"),
            windowID: 0, ownerPID: 2, frame: window.frame, displayName: "Other",
            bundleIdentifier: "test.other", ownerName: "Other", isOnScreen: true)
        assert(MenuBarItemScanner.merged([window], [window, axOnly]) == [window, axOnly])
        assert(MenuBarItemScanner.merged([], [axOnly]) == [axOnly])
        print("PASS: partial CG scan retains AX-only items without duplicates")
        let items = await MenuBarItemScanner().scan()
        print("Discovered: \(items.count), real window IDs: \(items.filter { $0.windowID != kCGNullWindowID }.count)")
        print("Displays: \(NSScreen.screens.count), Accessibility: \(AXIsProcessTrusted())")
    }
}
