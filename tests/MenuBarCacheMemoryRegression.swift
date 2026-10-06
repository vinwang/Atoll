// Compile with MenuBarItemImageCache.swift and the two MenuBar/Models files.
import AppKit
import Combine

private var iconLoads = 0
func AppIconAsNSImage(for bundleID: String) -> NSImage? {
    iconLoads += 1
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.bitmapData!.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    let image = NSImage(size: NSSize(width: 1024, height: 1024))
    image.addRepresentation(bitmap)
    return image
}

@main struct MenuBarCacheMemoryRegression {
    @MainActor static func main() {
        _ = NSApplication.shared
        let item = ManagedMenuBarItem(
            identity: .init(bundleIdentifier: "example.app", title: "Example", ownerName: "Example"),
            windowID: 1, ownerPID: 1, frame: CGRect(x: 0, y: 0, width: 20, height: 20),
            displayName: "Example", bundleIdentifier: "example.app", ownerName: "Example", isOnScreen: true)
        let cache = MenuBarItemImageCache()
        cache.refresh(for: [item])
        let image = cache.image(for: item)!
        let bitmap = image.representations.first as! NSBitmapImageRep
        assert(image.representations.count == 1 && bitmap.pixelsWide == 48 && bitmap.pixelsHigh == 48)
        assert(image.size == NSSize(width: 24, height: 24))
        assert(bitmap.colorAt(x: 24, y: 24)!.alphaComponent > 0.9, "Rasterized icon must remain visible")
        var updates = 0
        let observation = cache.objectWillChange.sink { updates += 1 }
        for _ in 0..<100 {
            autoreleasepool { cache.refresh(for: [item]) }
        }
        assert(iconLoads == 1 && updates == 0, "Unchanged refresh must reuse icons without publishing")
        assert(cache.image(for: item) === image)
        cache.refresh(for: [])
        assert(cache.images.isEmpty && updates == 1, "Removed icons must be evicted")
        withExtendedLifetime(observation) {}
        print("PASS: one visible 48px icon, 100 refreshes with no reload/publication, removal evicts cache")
        print("Cached bitmap: \(bitmap.bytesPerRow * bitmap.pixelsHigh) bytes; source bitmap: 4194304 bytes")
    }
}
