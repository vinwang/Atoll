/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

actor ThumbnailService {
    static let shared = ThumbnailService()

    private let cache = NSCache<NSString, NSImage>()
    private var pendingRequests: [String: Task<NSImage?, Never>] = [:]
    private let thumbnailGenerator = QLThumbnailGenerator.shared

    private init() {
        cache.countLimit = 128
        cache.totalCostLimit = 8 * 1_024 * 1_024
    }
    
    func thumbnail(for url: URL, size: CGSize) async -> NSImage? {
        let cacheKey = "\(url.path)_\(size.width)x\(size.height)"
        
        if let cached = cache.object(forKey: cacheKey as NSString) {
            return cached
        }
        
        if let pending = pendingRequests[cacheKey] {
            return await pending.value
        }
        
        let task = Task<NSImage?, Never> {
            let thumbnail = await generateQuickLookThumbnail(for: url, size: size)
            if let thumbnail = thumbnail, !Task.isCancelled {
                let cost = thumbnail.representations.reduce(0) {
                    $0 + $1.pixelsWide * $1.pixelsHigh * 4
                }
                cache.setObject(thumbnail, forKey: cacheKey as NSString, cost: cost)
            }
            pendingRequests[cacheKey] = nil
            return thumbnail
        }
        
        pendingRequests[cacheKey] = task
        return await task.value
    }
    
    func clearCache() {
        cache.removeAllObjects()
        pendingRequests.values.forEach { $0.cancel() }
    }
    
    func clearCache(for url: URL) {
        // ponytail: invalidate the small cache as a whole; index keys by URL if reuse becomes costly.
        clearCache()
    }
    
    // MARK: - Private Methods
    
    private func generateQuickLookThumbnail(for url: URL, size: CGSize) async -> NSImage? {
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
        
        return await url.accessSecurityScopedResource { scopedURL in
            NSLog("🔐 ThumbnailService: obtaining security scope for \(scopedURL.path)")
            let request = QLThumbnailGenerator.Request(
                fileAt: scopedURL,
                size: size,
                scale: scale,
                representationTypes: .all
            )
            request.iconMode = true

            return await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
                thumbnailGenerator.generateBestRepresentation(for: request) { representation, error in
                    if let rep = representation {
                        NSLog("🔍 ThumbnailService: generated thumbnail for \(scopedURL.path)")
                        continuation.resume(returning: rep.nsImage)
                    } else {
                        if let err = error { 
                            NSLog("⚠️ ThumbnailService: thumbnail error for \(scopedURL.path): \(err.localizedDescription)") 
                        }
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }
}

// MARK: - Extensions

extension QLThumbnailRepresentation {
    var nsImage: NSImage {
        return NSImage(cgImage: self.cgImage, size: self.cgImage.size)
    }
}

extension CGImage {
    var size: NSSize {
        return NSSize(width: self.width, height: self.height)
    }
}
