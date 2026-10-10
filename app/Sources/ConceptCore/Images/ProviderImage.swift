// Build the image bytes that leave the machine: resized under provider limits and re-encoded
// without metadata. Python counterpart: images.py.
//
// Re-encoding drops EXIF/IPTC/XMP: the destination is given no properties dictionary (PNG) or
// only the JPEG quality, so the source's metadata never reaches the output. ImageIO still
// writes a small Exif block of its own (pixel dimensions, colour space) and, for JPEG, a
// Photoshop APP13 segment; Pillow writes neither, so those segments are removed from the
// encoded bytes afterwards. The ICC profile travels with the `CGImage`'s colour space (PNG
// `iCCP`, JPEG APP2) and is kept, as Python keeps `icc_profile`. The resize exists because
// providers reject large images and charge more tokens for them.
//
// Accepted differences from the Python code (the output is not byte-compared):
// - ImageIO's resampler instead of LANCZOS.
// - A PNG keeps its alpha channel; Python flattens non-RGB/L modes to RGB. Every provider
//   accepts RGBA PNG. A JPEG destination drops alpha itself.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum Images {
    public static let defaultMaxBytes = 8 * 1024 * 1024
    public static let defaultMaxSide = 3072

    /// Returns bytes ready for a provider and their media type ("image/png" or "image/jpeg").
    ///
    /// EXIF orientation is applied and the longer side bounded to `maxSide` in one ImageIO
    /// thumbnail pass; the result is re-encoded as PNG, or as JPEG (quality 0.95) when `suffix`
    /// is `.jpg`/`.jpeg` in any case, then shrunk by 0.8 per side until it fits `maxBytes`.
    /// Throws `ConfigurationError` for non-positive limits, undecodable data, or when a 1x1
    /// image is still over the byte cap.
    public static func providerImage(
        _ data: Data,
        suffix: String,
        maxBytes: Int = defaultMaxBytes,
        maxSide: Int = defaultMaxSide
    ) throws -> (data: Data, mediaType: String) {
        guard maxBytes > 0, maxSide > 0 else {
            throw ConfigurationError("image limits must be positive")
        }
        let format = Format(suffix: suffix)
        var image = try decode(data, maxSide: maxSide)
        while true {
            let encoded = try stripMetadata(encode(image, as: format), format: format)
            if encoded.count <= maxBytes {
                return (encoded, format.mediaType)
            }
            let (width, height) = (image.width, image.height)
            if width == 1, height == 1 {
                throw ConfigurationError("image could not be encoded below the byte cap")
            }
            image = try resize(
                image,
                width: max(1, Int(Double(width) * 0.8)),
                height: max(1, Int(Double(height) * 0.8))
            )
        }
    }

    // MARK: - Output format

    private enum Format {
        case png
        case jpeg

        init(suffix: String) {
            let lowered = suffix.lowercased()
            self = lowered == ".jpg" || lowered == ".jpeg" ? .jpeg : .png
        }

        var mediaType: String {
            switch self {
            case .png: "image/png"
            case .jpeg: "image/jpeg"
            }
        }

        var typeIdentifier: CFString {
            switch self {
            case .png: UTType.png.identifier as CFString
            case .jpeg: UTType.jpeg.identifier as CFString
            }
        }

        /// PNG gets no properties at all; JPEG only its quality. No metadata dictionary either way.
        var destinationProperties: CFDictionary? {
            switch self {
            case .png: nil
            case .jpeg: [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary
            }
        }
    }

    // MARK: - Decode, encode, resize

    /// Decode index 0 with the EXIF orientation applied and the longer side bounded to `maxSide`.
    /// ImageIO never upscales here: a smaller image comes back at its own size.
    private static func decode(_ data: Data, maxSide: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else {
            throw ConfigurationError("image data could not be decoded")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCache: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ConfigurationError("image data could not be decoded")
        }
        return image
    }

    private static func encode(_ image: CGImage, as format: Format) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, format.typeIdentifier, 1, nil) else {
            throw ConfigurationError("image could not be encoded as \(format.mediaType)")
        }
        CGImageDestinationAddImage(destination, image, format.destinationProperties)
        guard CGImageDestinationFinalize(destination) else {
            throw ConfigurationError("image could not be encoded as \(format.mediaType)")
        }
        return output as Data
    }

    private static func resize(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard let context = bitmapContext(like: image, width: width, height: height) else {
            throw ConfigurationError("image could not be resized to \(width)x\(height)")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else {
            throw ConfigurationError("image could not be resized to \(width)x\(height)")
        }
        return resized
    }

    /// An 8-bit context in the image's own colour space where CoreGraphics supports it (so the
    /// ICC profile survives a shrink), falling back to sRGB. Grey stays grey; anything with
    /// alpha keeps it; everything else becomes RGB.
    private static func bitmapContext(like image: CGImage, width: Int, height: Int) -> CGContext? {
        let hasAlpha = switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
        let space = image.colorSpace
        if let space, space.model == .monochrome, !hasAlpha,
           let grey = makeContext(width: width, height: height, space: space, alpha: .none) {
            return grey
        }
        let alpha: CGImageAlphaInfo = hasAlpha ? .premultipliedLast : .noneSkipLast
        if let space, space.model == .rgb,
           let own = makeContext(width: width, height: height, space: space, alpha: alpha) {
            return own
        }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return makeContext(width: width, height: height, space: srgb, alpha: alpha)
    }

    private static func makeContext(
        width: Int,
        height: Int,
        space: CGColorSpace,
        alpha: CGImageAlphaInfo
    ) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: alpha.rawValue
        )
    }

    // MARK: - Metadata stripping

    /// Remove the metadata segments ImageIO writes on its own. Anything structurally
    /// unexpected returns the bytes unchanged: the encoder produced them, so they decode.
    private static func stripMetadata(_ data: Data, format: Format) -> Data {
        switch format {
        case .png: stripPNGChunks(data)
        case .jpeg: stripJPEGSegments(data)
        }
    }

    /// Exif and textual chunks. `iCCP`, `sRGB`, `gAMA`, `cHRM` and `pHYs` stay.
    private static let droppedPNGChunks: Set<[UInt8]> = Set(["eXIf", "tEXt", "zTXt", "iTXt", "tIME"]
        .map { Array($0.utf8) })

    private static func stripPNGChunks(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        let signatureLength = 8
        guard bytes.count > signatureLength else { return data }
        var output = Data(bytes[0 ..< signatureLength])
        var index = signatureLength
        while index + 12 <= bytes.count {
            let length = bigEndian32(bytes, at: index)
            let end = index + 12 + length
            guard end <= bytes.count else { return data }
            let type = Array(bytes[(index + 4) ..< (index + 8)])
            if !droppedPNGChunks.contains(type) {
                output.append(contentsOf: bytes[index ..< end])
            }
            index = end
        }
        return index == bytes.count ? output : data
    }

    /// APP1 (Exif, XMP), APP13 (Photoshop/IPTC) and COM. APP0 (JFIF), APP2 (ICC profile) and
    /// APP14 (Adobe colour transform) stay; so does everything from the start of scan on.
    private static let droppedJPEGMarkers: Set<UInt8> = [0xE1, 0xED, 0xFE]

    private static func stripJPEGSegments(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return data }
        var output = Data(bytes[0 ..< 2])
        var index = 2
        while index + 4 <= bytes.count, bytes[index] == 0xFF {
            let marker = bytes[index + 1]
            if marker == 0xDA { // start of scan: entropy-coded data follows, copy the rest
                output.append(contentsOf: bytes[index...])
                return output
            }
            if marker == 0xFF { // fill byte
                index += 1
                continue
            }
            if isStandaloneJPEGMarker(marker) {
                output.append(contentsOf: bytes[index ..< (index + 2)])
                index += 2
                continue
            }
            let length = bigEndian16(bytes, at: index + 2)
            let end = index + 2 + length
            guard length >= 2, end <= bytes.count else { return data }
            if !droppedJPEGMarkers.contains(marker) {
                output.append(contentsOf: bytes[index ..< end])
            }
            index = end
        }
        return data
    }

    /// TEM, RSTn, SOI, EOI carry no length field.
    private static func isStandaloneJPEGMarker(_ marker: UInt8) -> Bool {
        marker == 0x01 || (0xD0 ... 0xD9).contains(marker)
    }

    private static func bigEndian32(_ bytes: [UInt8], at index: Int) -> Int {
        Int(bytes[index]) << 24 | Int(bytes[index + 1]) << 16 | Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
    }

    private static func bigEndian16(_ bytes: [UInt8], at index: Int) -> Int {
        Int(bytes[index]) << 8 | Int(bytes[index + 1])
    }
}
