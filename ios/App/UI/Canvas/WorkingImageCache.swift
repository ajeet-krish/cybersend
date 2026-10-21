import Foundation
import ImageIO
import UIKit

// One decode of the pixels-up working JPEG into a cached CGImage (M3, US-18). The canvas
// asks for a photo by file URL; the decode runs once off the main actor, lands in a small
// NSCache keyed by URL, and every later canvas for the same photo reuses the CGImage, so
// panning and zooming never decode again.

/// Reference box so the non-Sendable CGImage can travel from the decode queue to the
/// main actor inside Sendable values only.
final class CGImageBox: @unchecked Sendable {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}

enum WorkingImageCache {
    private static let cache: NSCacheBox = NSCacheBox()

    /// Loads the working copy's CGImage, from cache synchronously or by decoding on the
    /// shared utility queue. Completion always runs on the main actor, so the whole entry
    /// point is main actor bound like its view callers.
    @MainActor
    static func load(url: URL, completion: @escaping @MainActor (CGImage?) -> Void) {
        let key = url as NSURL
        if let cached = cache.storage.object(forKey: key) {
            completion(cached.image)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let box = decode(url).map(CGImageBox.init)
            if let box {
                cache.storage.setObject(box, forKey: key)
            }
            Task { @MainActor in
                completion(box?.image)
            }
        }
    }

    /// ImageIO decode with immediate caching so the CGImage is render ready.
    private static func decode(_ url: URL) -> CGImage? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
            return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
        }
    }
}

/// Sendable box around the NSCache (NSCache itself is thread safe; the box keeps the
/// Swift 6 strict concurrency checks satisfied without a lock).
private final class NSCacheBox: @unchecked Sendable {
    let storage = NSCache<NSURL, CGImageBox>()
}
