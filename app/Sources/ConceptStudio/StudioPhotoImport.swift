import ConceptCore
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// PhotosPicker's temporary video is copied while its transfer is valid; its owner removes
/// that copy after import or cancellation. Still images keep their existing normalization path.
final class PickedPhoto: Transferable, Sendable {
    enum Content {
        case image(Data)
        case video(URL)
    }

    let content: Content
    let suggestedName: String?

    private init(content: Content, suggestedName: String?) {
        self.content = content
        self.suggestedName = suggestedName
    }

    deinit {
        if case let .video(file) = content {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
    }

    static func copyVideo(from source: URL) throws -> PickedPhoto {
        guard Sources.isVideo(Sources.suffix(of: source.lastPathComponent)) else {
            throw StudioError.message("This clip format is not supported. Export an MP4 or MOV file from Photos.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConceptStudio-Photos-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let target = directory.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: target)
            return PickedPhoto(content: .video(target), suggestedName: source.lastPathComponent)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            try PickedPhoto.copyVideo(from: received.file)
        }
        FileRepresentation(importedContentType: .image) { received in
            try PickedPhoto(
                content: .image(Data(contentsOf: received.file)), suggestedName: received.file.lastPathComponent
            )
        }
        DataRepresentation(importedContentType: .image) { data in
            PickedPhoto(content: .image(data), suggestedName: nil)
        }
    }
}

/// Readable, stable names for media imported from Apple Photos: the suggested name (or image
/// capture date) plus a short content hash, so importing the same sample yields the same name.
enum PhotoImportName {
    static func make(suggested: String?, captured: Date?, hash: String, suffix: String) -> String {
        let stem: String = if let readable = suggested.flatMap(readableStem) {
            readable
        } else if let captured {
            "photo-" + dateStem(captured)
        } else {
            Sources.isVideo("." + suffix) ? "clip" : "photo"
        }
        return "\(stem)-\(hash.prefix(8)).\(suffix)"
    }

    /// The photo's bytes in a format the captioning pipeline reads, with the matching suffix.
    /// PNG, JPEG and WebP pass through; anything else (HEIC, TIFF, ...) is converted to JPEG.
    static func readable(_ data: Data) throws -> (Data, String) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source).map({ UTType($0 as String) }) ?? nil else {
            throw StudioError.message("This photo could not be read. Export it from Photos and import the file.")
        }
        if let suffix = type.preferredFilenameExtension?.lowercased(),
           Sources.imageSuffixes.contains("." + suffix) {
            return (data, suffix == "jpeg" ? "jpg" : suffix)
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw StudioError.message("This photo could not be converted to JPEG.") }
        CGImageDestinationAddImageFromSource(
            destination, source, 0, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw StudioError.message("This photo could not be converted to JPEG.")
        }
        return (output as Data, "jpg")
    }

    static func captureDate(_ data: Data) -> Date? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        guard let text = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
            ?? tiff?[kCGImagePropertyTIFFDateTime] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }

    static func dateStem(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// A safe stem from a suggested file name, or nil when it carries no meaning (blank or a UUID).
    static func readableStem(_ name: String) -> String? {
        let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(stem.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        guard !cleaned.isEmpty, UUID(uuidString: cleaned) == nil else { return nil }
        return String(cleaned.prefix(60))
    }
}
