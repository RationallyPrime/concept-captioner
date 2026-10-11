import AVFoundation
import ConceptCore
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

struct VideoInfo: Equatable {
    let duration: Double
    let hasAudio: Bool
    let width: Int
    let height: Int
    let fps: Double
}

struct MediaFrame: Identifiable {
    var id: Double {
        seconds
    }

    let seconds: Double
    let image: CGImage
}

struct MediaSelection: Codable, Equatable {
    var originalName: String
    var crop: CGRect?
    var startSeconds: Double?
    var endSeconds: Double?
    var frameCount: Int?
    var videoWidth: Int?
    var videoHeight: Int?
}

struct VideoTimeline {
    let times: [CMTime]
    let end: CMTime

    var maximumTrainingFrames: Int {
        times.isEmpty ? 0 : min(MediaEditor.maximumVideoFrames, (times.count - 1) / 8 * 8 + 1)
    }

    func range(startFrame: Int, frameCount: Int) -> CMTimeRange? {
        guard startFrame >= 0, frameCount >= 9, frameCount % 8 == 1,
              frameCount <= MediaEditor.maximumVideoFrames, frameCount <= times.count,
              startFrame <= times.count - frameCount else { return nil }
        let start = times[startFrame]
        let finish = startFrame + frameCount < times.count ? times[startFrame + frameCount] : end
        guard finish > start else { return nil }
        return CMTimeRange(start: start, end: finish)
    }

    /// Pinned LTX preprocessing consumes uniform frame positions rather than the container's PTS.
    func isConstantRate(startFrame: Int, frameCount: Int) -> Bool {
        guard let range = range(startFrame: startFrame, frameCount: frameCount) else { return false }
        let selected = Array(times[startFrame ..< startFrame + frameCount]) + [range.end]
        let interval = range.duration.seconds / Double(frameCount)
        let tolerance = 1 / Double(selected.map(\.timescale).min() ?? 1)
        return zip(selected, selected.dropFirst()).allSatisfy {
            abs(($0.1 - $0.0).seconds - interval) <= tolerance
        }
    }
}

enum MediaEditor {
    /// Matches the current LTX trainer's approved-media bucket bound.
    static let maximumVideoFrames = 257
    static let convertibleImageSuffixes: Set<String> = [".heic", ".heif", ".tif", ".tiff"]

    static func importableFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
            .filter {
                let suffix = Sources.suffix(of: $0.lastPathComponent).lowercased()
                return (Sources.mediaSuffixes.contains(suffix) || convertibleImageSuffixes.contains(suffix))
                    && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func normalizedImport(_ data: Data, name: String) throws -> (data: Data, name: String) {
        let suffix = Sources.suffix(of: name).lowercased()
        guard convertibleImageSuffixes.contains(suffix) else { return (data, name) }
        let image = try orientedImage(data)
        return try (png(image), Sources.stem(of: name) + ".png")
    }

    static func orientedImage(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: max(width, height),
              ] as CFDictionary) else {
            throw StudioError.message("This image cannot be decoded. Choose another copy.")
        }
        return image
    }

    /// Top-left normalized coordinates in the oriented training image.
    static func cropped(_ data: Data, rectangle: CGRect) throws -> Data {
        guard rectangle.minX >= 0, rectangle.minY >= 0, rectangle.maxX <= 1, rectangle.maxY <= 1,
              rectangle.width > 0, rectangle.height > 0 else {
            throw StudioError.message("Keep the crop inside the image and give it a positive size.")
        }
        let image = try orientedImage(data)
        let pixels = CGRect(
            x: rectangle.minX * Double(image.width), y: rectangle.minY * Double(image.height),
            width: rectangle.width * Double(image.width), height: rectangle.height * Double(image.height)
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let cropped = image.cropping(to: pixels) else { throw StudioError.message("This crop is too small.") }
        return try png(cropped)
    }

    static func suggestedCrop(face: CGRect) -> CGRect {
        let width = min(1, face.width * 3)
        let height = min(1, face.height * 3)
        return CGRect(
            x: max(0, min(1 - width, face.midX - width / 2)),
            y: max(0, min(1 - height, 1 - face.midY - height / 2)), width: width, height: height
        )
    }

    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw StudioError.message("The image could not be encoded.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination)
        else { throw StudioError.message("The image could not be saved.") }
        return data as Data
    }

    static func videoInfo(url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0,
              let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw StudioError.message("This clip has no readable video track.")
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let oriented = size.applying(transform)
        return try await VideoInfo(
            duration: duration, hasAudio: !asset.loadTracks(withMediaType: .audio).isEmpty,
            width: Int(abs(oriented.width)), height: Int(abs(oriented.height)),
            fps: Double(track.load(.nominalFrameRate))
        )
    }

    static func frame(url: URL, seconds: Double, pixels: Int = 1280) async throws -> MediaFrame {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixels, height: pixels)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let result = try await generator.image(at: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
        try Task.checkCancellation()
        return MediaFrame(seconds: result.actualTime.seconds, image: result.image)
    }

    static func frames(url: URL, count: Int = 5) async throws -> [MediaFrame] {
        let info = try await videoInfo(url: url)
        var result: [MediaFrame] = []
        for index in 0 ..< max(1, count) {
            try Task.checkCancellation()
            let time = max(0, info.duration - max(0.05, 1 / max(1, info.fps)))
                * Double(index) / Double(max(1, count - 1))
            try await result.append(frame(url: url, seconds: time))
        }
        return result
    }

    /// `AVAssetReader` reads synchronously and waits on CoreMedia's own workers. On the three-core CI runner,
    /// three concurrent reads held every cooperative thread and never returned, starving every other task.
    /// Keep the reads off Swift's cooperative executor, as `VisionInspector` does for Vision.
    private static let readerQueue = DispatchQueue(label: "ConceptStudio.MediaReader", qos: .userInitiated)

    /// Read compressed sample timestamps without decoding every frame into a pixel buffer.
    /// Nominal frame rate alone cannot count variable-rate video.
    static func videoTimeline(url: URL) async throws -> VideoTimeline {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw StudioError.message("This clip has no readable video track.")
        }
        let end = try await track.load(.timeRange).end
        let cancelled = Mutex(false)
        let times: [CMTime] = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                readerQueue.async {
                    continuation.resume(with: Result {
                        try frameTimes(asset: asset, track: track) {
                            if cancelled.withLock({ $0 }) { throw CancellationError() }
                        }
                    })
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
        try Task.checkCancellation()
        guard !times.isEmpty, zip(times, times.dropFirst()).allSatisfy({ $0.0 < $0.1 }) else {
            throw StudioError.message("This clip has ambiguous frame times. Choose another copy.")
        }
        return VideoTimeline(times: times, end: end)
    }

    /// Every sample's output presentation time in `track`, sorted. Blocks while reading; call it only on
    /// `readerQueue`.
    private static func frameTimes(
        asset: AVURLAsset, track: AVAssetTrack, checkCancellation: () throws -> Void
    ) throws -> [CMTime] {
        let reader = try AVAssetReader(asset: asset)
        let frames = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        frames.alwaysCopiesSampleData = false
        guard reader.canAdd(frames) else { throw StudioError.message("This clip's frame times cannot be read.") }
        reader.add(frames)
        guard reader.startReading() else { throw reader.error ?? StudioError.message("This clip cannot be read.") }
        defer { reader.cancelReading() }
        var times: [CMTime] = []
        while let sample = frames.copyNextSampleBuffer() {
            try checkCancellation()
            // Compressed readers also emit zero-sample decoder commands. Output PTS applies
            // the container's edit offset; raw PTS includes the encoder's reordering delay.
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let time = CMSampleBufferGetOutputPresentationTimeStamp(sample)
            guard time.isNumeric, time >= .zero else {
                throw StudioError.message("This clip has unreadable frame times. Choose another copy.")
            }
            times.append(time)
        }
        guard reader.status == .completed else {
            throw reader.error ?? StudioError.message("Reading this clip's frame times did not complete.")
        }
        return times.sorted { $0 < $1 }
    }

    /// Fit the full oriented frame into a 32-aligned canvas without cropping its edges.
    static func fittedVideoComposition(url: URL, longEdge: Int) async throws -> AVMutableVideoComposition {
        guard longEdge > 0, longEdge % 32 == 0 else {
            throw StudioError.message("Choose a video size divisible by 32.")
        }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw StudioError.message("This clip has no readable video track.")
        }
        let size = try await track.load(.naturalSize)
        let orientation = try await track.load(.preferredTransform)
        let oriented = CGRect(origin: .zero, size: size).applying(orientation)
        guard oriented.width > 0, oriented.height > 0 else {
            throw StudioError.message("This clip has no readable frame dimensions.")
        }
        let scale = min(1, CGFloat(longEdge) / max(oriented.width, oriented.height))
        let width = ceil(oriented.width * scale / 32) * 32
        let height = ceil(oriented.height * scale / 32) * 32
        let transform = orientation
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(
                translationX: (width - oriented.width * scale) / 2,
                y: (height - oriented.height * scale) / 2
            ))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = try await CMTimeRange(start: .zero, duration: asset.load(.duration))
        instruction.layerInstructions = [layer]
        instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: width, height: height)
        // This native property preserves source variable frame timing; frameDuration is only an empty-edit fallback.
        composition.sourceTrackIDForFrameTiming = track.trackID
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.instructions = [instruction]
        return composition
    }

    /// Export exactly N approved frames without retiming; N must match an LTX 8n+1 bucket.
    /// Re-encoding avoids keyframe-aligned passthrough extending the selected range.
    static func trim(
        url: URL, startFrame: Int, frameCount: Int, longEdge: Int, output: URL
    ) async throws -> (range: CMTimeRange, info: VideoInfo) {
        let timeline = try await videoTimeline(url: url)
        guard let range = timeline.range(startFrame: startFrame, frameCount: frameCount) else {
            throw StudioError.message("Choose an available segment of 8n+1 frames, "
                + "from 9 through \(maximumVideoFrames), such as 17 or 33 frames.")
        }
        guard timeline.isConstantRate(startFrame: startFrame, frameCount: frameCount) else {
            throw StudioError.message("This segment has variable frame timing that the LTX trainer cannot preserve. "
                +
                "Choose a constant-rate portion or import a constant-frame-rate copy; no clip was retimed or replaced.")
        }
        guard let export = AVAssetExportSession(
            asset: AVURLAsset(url: url),
            presetName: AVAssetExportPresetHighestQuality
        )
        else { throw StudioError.message("This clip cannot be exported to a training segment.") }
        export.timeRange = range
        export.videoComposition = try await fittedVideoComposition(url: url, longEdge: longEdge)
        do {
            try await export.export(to: output, as: .mp4)
            try Task.checkCancellation()
            let exported = try await videoTimeline(url: output)
            guard exported.times.count == frameCount else {
                throw StudioError.message("The exported clip did not contain exactly \(frameCount) frames. "
                    + "Choose another start frame or another clip; no target was replaced.")
            }
            for (index, time) in exported.times.enumerated() {
                let original = timeline.times[startFrame + index] - range.start
                guard abs(time.seconds - original.seconds) < 0.002 else {
                    throw StudioError.message("The exported clip changed frame timing. "
                        + "Choose another clip; no target was replaced.")
                }
            }
            return try await (range, videoInfo(url: output))
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }
}
