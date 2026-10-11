import AppKit
import ImageIO
import SwiftUI

/// Downsampled photo thumbnails, decoded off the main thread and kept in a small in-memory cache.
@MainActor
enum PhotoThumbnails {
    struct Key: Hashable {
        let url: URL
        let pixels: Int
    }

    /// Sizes snap to a few buckets so tiles, rows and detail panes share cached decodes.
    static let buckets = [128, 256, 512, 1024, 2048]
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        cache.totalCostLimit = 192 * 1024 * 1024
        return cache
    }()

    private static func cacheKey(_ key: Key) -> NSString {
        "\(key.pixels)|\(key.url.absoluteString)" as NSString
    }

    static func bucket(for length: CGFloat) -> Int {
        let wanted = Int(length.rounded(.up))
        return buckets.first { $0 >= wanted } ?? buckets[buckets.count - 1]
    }

    static func cached(_ key: Key) -> NSImage? {
        cache.object(forKey: cacheKey(key))
    }

    /// Returns the cached thumbnail or decodes one in the background. `nil` means the file is unreadable.
    static func load(_ key: Key) async -> NSImage? {
        if let image = cached(key) { return image }
        let url = key.url
        let pixels = key.pixels
        let decoded = await Task.detached(priority: .userInitiated) { decode(url, maxPixels: pixels) }.value
        guard let decoded else { return nil }
        let image = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
        cache.setObject(image, forKey: cacheKey(key), cost: decoded.bytesPerRow * decoded.height)
        return image
    }

    /// Clears every thumbnail, for example after a photo file is replaced in place.
    static func removeAll() {
        cache.removeAllObjects()
    }

    nonisolated static func decode(_ url: URL, maxPixels: Int) -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary)
    }
}

/// A photo fitted into the space its caller gives it. Never decodes the original on the main thread.
struct PhotoView: View {
    let url: URL
    var faces: [CGRect] = []
    @Environment(\.displayScale) private var displayScale
    @State private var loaded: (key: PhotoThumbnails.Key, image: NSImage?)?

    var body: some View {
        GeometryReader { geometry in
            let key = PhotoThumbnails.Key(
                url: url,
                pixels: PhotoThumbnails.bucket(for: max(geometry.size.width, geometry.size.height) * displayScale)
            )
            content(for: key)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .task(id: key) {
                    guard PhotoThumbnails.cached(key) == nil else { return }
                    let image = await PhotoThumbnails.load(key)
                    if !Task.isCancelled { loaded = (key, image) }
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(url.lastPathComponent)
        .accessibilityAddTraits(.isImage)
    }

    @ViewBuilder private func content(for key: PhotoThumbnails.Key) -> some View {
        if let image = PhotoThumbnails.cached(key) ?? (loaded?.key == key ? loaded?.image : nil) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                .overlay { faceBoxes }
        } else if loaded?.key == key {
            ContentUnavailableView("Cannot read this photo", systemImage: "photo")
        } else {
            Rectangle().fill(StudioStyle.surface)
        }
    }

    private var faceBoxes: some View {
        GeometryReader { geometry in
            ForEach(Array(faces.enumerated()), id: \.offset) { index, face in
                RoundedRectangle(cornerRadius: 5).stroke(StudioStyle.accent, lineWidth: 2)
                    .overlay(alignment: .topLeading) {
                        Text("\(index + 1)").font(.caption.bold()).padding(3)
                            .foregroundStyle(.primary).background(StudioStyle.surface)
                    }
                    .frame(width: face.width * geometry.size.width, height: face.height * geometry.size.height)
                    .position(x: face.midX * geometry.size.width, y: (1 - face.midY) * geometry.size.height)
            }
        }
    }
}
