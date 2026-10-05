// Compile with CGSSpace.swift and NotchSpaceManager.swift; stubs never change real Spaces.
import AppKit

private var calls: [String] = []

@_silgen_name("_CGSDefaultConnection")
func testConnection() -> UInt { 1 }
@_silgen_name("CGSSpaceCreate")
func testCreate(_ cid: UInt, _ flag: Int, _ options: NSDictionary?) -> UInt64 { 42 }
@_silgen_name("CGSSpaceSetAbsoluteLevel")
func testLevel(_ cid: UInt, _ space: UInt64, _ level: Int) {}
@_silgen_name("CGSShowSpaces")
func testShow(_ cid: UInt, _ spaces: NSArray) {}
@_silgen_name("CGSHideSpaces")
func testHide(_ cid: UInt, _ spaces: NSArray) { calls.append("hide") }
@_silgen_name("CGSSpaceDestroy")
func testDestroy(_ cid: UInt, _ space: UInt64) { calls.append("destroy") }
@_silgen_name("CGSRemoveWindowsFromSpaces")
func testRemove(_ cid: UInt, _ windows: NSArray, _ spaces: NSArray) { calls.append("remove") }
@_silgen_name("CGSAddWindowsToSpaces")
func testAdd(_ cid: UInt, _ windows: NSArray, _ spaces: NSArray) { calls.append("add") }

@main struct CGSSpaceLifecycleRegression {
    static func main() {
        assert(!NotchSpaceManager.isInitialized, "Inspecting initialization must not create a Space")
        var space: CGSSpace? = CGSSpace()
        space!.close()
        assert(calls == ["remove", "add", "hide", "destroy"], "Detach before destroying the owned Space")
        let closedCalls = calls
        space!.close()
        space!.windows = []
        space = nil
        assert(calls == closedCalls, "Repeated close, membership changes and deinit must not touch a closed Space")

        calls = []
        var borrowed: CGSSpace? = CGSSpace(id: 99)
        borrowed!.close()
        borrowed = nil
        assert(calls == ["remove", "add", "hide"], "Never destroy a borrowed Space")

        calls = []
        var automatic: CGSSpace? = CGSSpace()
        assert(automatic != nil)
        automatic = nil
        assert(calls == ["remove", "add", "hide", "destroy"], "Deinit must still clean up an owned Space")
        calls = []
        let manager = NotchSpaceManager.shared
        assert(NotchSpaceManager.isInitialized)
        manager.notchSpace.close()
        assert(calls == ["remove", "add", "hide", "destroy"], "The retained singleton supports explicit cleanup")
        print("PASS: explicit Space cleanup is ordered, idempotent and preserves borrowed Spaces")
    }
}
