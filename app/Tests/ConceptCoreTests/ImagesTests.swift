// providerImage resize, re-encode, metadata stripping. See docs/CORE-SPEC.md, module `images`.
// Python counterpart: images.py (provider_image has no dedicated Python tests; the runner tests
// only check that an image is attached to every call).

import ConceptCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite("images")
struct ImagesTests {
    @Test("a small PNG comes back as PNG at its own size with no EXIF or TIFF metadata")
    func pngPassThrough() throws {
        let (data, mediaType) = try Images.providerImage(Fixtures.syntheticPNG(seed: 1), suffix: ".png")
        #expect(mediaType == "image/png")
        #expect(hasPNGSignature(data))
        let decoded = try decode(data)
        #expect(decoded.width == 256)
        #expect(decoded.height == 256)
        #expect(decoded.properties["{Exif}"] == nil)
        #expect(decoded.properties["{TIFF}"] == nil)
        #expect(decoded.properties[kCGImagePropertyOrientation as String] == nil)
    }

    @Test("the longer side is bounded to maxSide, keeping the aspect ratio")
    func boundsLongerSide() throws {
        let wide = Fixtures.syntheticPNG(seed: 2, size: CGSize(width: 4000, height: 1000))
        let (data, _) = try Images.providerImage(wide, suffix: ".png")
        let decoded = try decode(data)
        #expect(decoded.width == 3072)
        #expect(decoded.height == 768)

        let tall = Fixtures.syntheticPNG(seed: 2, size: CGSize(width: 300, height: 600))
        let (small, _) = try Images.providerImage(tall, suffix: ".png", maxSide: 100)
        let smallDecoded = try decode(small)
        #expect(smallDecoded.width == 50)
        #expect(smallDecoded.height == 100)
    }

    @Test("a .jpg or .jpeg suffix (any case) yields JPEG; anything else yields PNG")
    func suffixPicksFormat() throws {
        let source = Fixtures.syntheticPNG(seed: 3)
        for suffix in [".jpg", ".jpeg", ".JPG", ".Jpeg"] {
            let (data, mediaType) = try Images.providerImage(source, suffix: suffix)
            #expect(mediaType == "image/jpeg", "suffix \(suffix)")
            #expect(hasJPEGSignature(data), "suffix \(suffix)")
            let decoded = try decode(data)
            #expect(decoded.width == 256 && decoded.height == 256, "suffix \(suffix)")
        }
        for suffix in [".png", ".webp", ".tif", ""] {
            let (data, mediaType) = try Images.providerImage(source, suffix: suffix)
            #expect(mediaType == "image/png", "suffix '\(suffix)'")
            #expect(hasPNGSignature(data), "suffix '\(suffix)'")
        }
    }

    @Test("a JPEG result carries no EXIF/TIFF metadata either")
    func jpegHasNoMetadata() throws {
        let (data, _) = try Images.providerImage(Fixtures.syntheticPNG(seed: 3), suffix: ".jpg")
        let decoded = try decode(data)
        #expect(decoded.properties["{Exif}"] == nil)
        #expect(decoded.properties["{TIFF}"] == nil)
        #expect(decoded.properties[kCGImagePropertyOrientation as String] == nil)
    }

    @Test("over the byte cap, the image shrinks by 0.8 per side until it fits")
    func shrinksUnderByteCap() throws {
        let noisy = try noisyPNG(size: 512)
        #expect(noisy.count > 2000)
        let (data, mediaType) = try Images.providerImage(noisy, suffix: ".png", maxBytes: 2000)
        #expect(mediaType == "image/png")
        #expect(data.count <= 2000)
        let decoded = try decode(data)
        #expect(decoded.width < 512)
        #expect(decoded.height < 512)
        #expect(decoded.width == decoded.height)
        // Each iteration is `max(1, Int(side * 0.8))` from the previous size, as in Python.
        #expect(shrinkChain(from: 512).contains(decoded.width))
    }

    @Test("a cap that even a 1x1 image cannot meet is a ConfigurationError")
    func impossibleByteCap() throws {
        #expect(throws: ConfigurationError("image could not be encoded below the byte cap")) {
            try Images.providerImage(
                Fixtures.syntheticPNG(seed: 1, size: CGSize(width: 8, height: 8)),
                suffix: ".png",
                maxBytes: 1
            )
        }
    }

    @Test("non-positive limits are a ConfigurationError before any decoding")
    func rejectsNonPositiveLimits() {
        let source = Fixtures.syntheticPNG(seed: 1)
        #expect(throws: ConfigurationError("image limits must be positive")) {
            try Images.providerImage(source, suffix: ".png", maxBytes: 0)
        }
        #expect(throws: ConfigurationError("image limits must be positive")) {
            try Images.providerImage(source, suffix: ".png", maxBytes: -1)
        }
        #expect(throws: ConfigurationError("image limits must be positive")) {
            try Images.providerImage(source, suffix: ".png", maxSide: 0)
        }
        #expect(throws: ConfigurationError("image limits must be positive")) {
            try Images.providerImage(Data(), suffix: ".png", maxBytes: 0)
        }
    }

    @Test("undecodable data is a ConfigurationError")
    func rejectsUndecodableData() {
        var state: UInt32 = 0xDEAD_BEEF
        var noise = [UInt8](repeating: 0, count: 4096)
        for index in noise.indices {
            state = state &* 1_664_525 &+ 1_013_904_223
            noise[index] = UInt8(truncatingIfNeeded: state >> 24)
        }
        #expect(throws: ConfigurationError.self) {
            try Images.providerImage(Data(noise), suffix: ".png")
        }
        #expect(throws: ConfigurationError.self) {
            try Images.providerImage(Data(), suffix: ".jpg")
        }
        #expect(throws: ConfigurationError.self) {
            try Images.providerImage(Data("not an image".utf8), suffix: ".png")
        }
    }

    @Test("EXIF orientation 6 is applied to the pixels and the tag does not survive")
    func appliesExifOrientation() throws {
        let oriented = try orientedJPEG(width: 256, height: 128, orientation: 6)
        let before = try decode(oriented)
        #expect(before.width == 256 && before.height == 128, "fixture stores the unrotated pixels")
        #expect(before.properties[kCGImagePropertyOrientation as String] as? Int == 6, "fixture carries the tag")

        for suffix in [".jpg", ".png"] {
            let (data, _) = try Images.providerImage(oriented, suffix: suffix)
            let after = try decode(data)
            #expect(after.width == 128, "suffix \(suffix)")
            #expect(after.height == 256, "suffix \(suffix)")
            #expect(after.properties[kCGImagePropertyOrientation as String] == nil, "suffix \(suffix)")
            #expect(after.properties["{TIFF}"] == nil, "suffix \(suffix)")
            #expect(after.properties["{Exif}"] == nil, "suffix \(suffix)")
        }
    }

    @Test("orientation and the side bound compose: the bound applies to the rotated image")
    func orientationThenBound() throws {
        let oriented = try orientedJPEG(width: 400, height: 100, orientation: 6)
        let (data, _) = try Images.providerImage(oriented, suffix: ".png", maxSide: 200)
        let after = try decode(data)
        #expect(after.width == 50)
        #expect(after.height == 200)
    }

    @Test("a PNG with alpha keeps its alpha channel; a JPEG drops it")
    func alphaHandling() throws {
        let source = try transparentPNG(size: 64)
        #expect(try decode(source).image.alphaInfo != .none)

        let (png, _) = try Images.providerImage(source, suffix: ".png")
        let pngAlpha = try decode(png).image.alphaInfo
        #expect(pngAlpha != .none && pngAlpha != .noneSkipLast && pngAlpha != .noneSkipFirst)

        let (jpeg, _) = try Images.providerImage(source, suffix: ".jpg")
        let jpegAlpha = try decode(jpeg).image.alphaInfo
        #expect(jpegAlpha == .none || jpegAlpha == .noneSkipLast || jpegAlpha == .noneSkipFirst)
    }

    @Test("the shrink path keeps the output decodable and the colour space attached")
    func shrunkOutputKeepsColorSpace() throws {
        let noisy = try noisyPNG(size: 128)
        let (data, _) = try Images.providerImage(noisy, suffix: ".jpg", maxBytes: 3000)
        let decoded = try decode(data)
        #expect(data.count <= 3000)
        #expect(decoded.width < 128)
        #expect(decoded.image.colorSpace != nil)
        #expect(decoded.image.colorSpace?.model == .rgb)
    }

    @Test("the ICC profile is kept in both formats, through the shrink loop as well")
    func keepsICCProfile() throws {
        let source = try displayP3PNG(size: 96)
        #expect(try decode(source).properties[kCGImagePropertyProfileName as String] as? String == "Display P3")

        for (suffix, maxBytes) in [(".png", Int.max), (".jpg", Int.max), (".png", 6000), (".jpg", 4000)] {
            let (data, _) = try Images.providerImage(source, suffix: suffix, maxBytes: maxBytes)
            let decoded = try decode(data)
            let profile = decoded.properties[kCGImagePropertyProfileName as String] as? String
            #expect(profile == "Display P3", "suffix \(suffix), maxBytes \(maxBytes)")
            #expect(decoded.properties["{Exif}"] == nil, "suffix \(suffix), maxBytes \(maxBytes)")
            if maxBytes < Int.max {
                #expect(data.count <= maxBytes && decoded.width < 96, "suffix \(suffix), maxBytes \(maxBytes)")
            }
        }
    }

    @Test("the bytes carry no Exif/text chunks (PNG) or Exif/XMP/IPTC segments (JPEG)")
    func bytesCarryNoMetadataSegments() throws {
        let source = try displayP3PNG(size: 32)
        let (png, _) = try Images.providerImage(source, suffix: ".png")
        let chunks = pngChunkTypes(png)
        #expect(chunks.first == "IHDR" && chunks.last == "IEND")
        #expect(chunks.contains("iCCP"), "\(chunks)")
        for dropped in ["eXIf", "tEXt", "zTXt", "iTXt", "tIME"] {
            #expect(!chunks.contains(dropped), "\(chunks)")
        }

        let (jpeg, _) = try Images.providerImage(source, suffix: ".jpg")
        let markers = jpegMarkers(jpeg)
        #expect(markers.contains(0xE2), "ICC APP2 stays: \(markers)")
        #expect(markers.contains(0xDA), "start of scan reached: \(markers)")
        for dropped: UInt8 in [0xE1, 0xED, 0xFE] {
            #expect(!markers.contains(dropped), "\(markers)")
        }
        #expect(try decode(jpeg).width == 32)
    }
}

// MARK: - Test support

private struct Decoded {
    let width: Int
    let height: Int
    let properties: [String: Any]
    let image: CGImage
}

/// Plain decode of index 0 without any transform, plus the container's properties.
private func decode(_ data: Data) throws -> Decoded {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        throw ConfigurationError("test: output did not decode")
    }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
    return Decoded(width: image.width, height: image.height, properties: properties, image: image)
}

private func hasPNGSignature(_ data: Data) -> Bool {
    data.count > 8 && Array(data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
}

private func hasJPEGSignature(_ data: Data) -> Bool {
    data.count > 2 && Array(data.prefix(2)) == [0xFF, 0xD8]
}

/// The side lengths `providerImage` can produce from `start` by repeated `max(1, Int(side * 0.8))`.
private func shrinkChain(from start: Int) -> [Int] {
    var chain = [start]
    while let last = chain.last, last > 1 {
        chain.append(max(1, Int(Double(last) * 0.8)))
    }
    return chain
}

/// Deterministic per-pixel noise: a PNG that barely compresses, so the byte cap bites.
private func noisyPNG(size: Int) throws -> Data {
    var state: UInt32 = 0x1234_5678
    var pixels = [UInt8](repeating: 255, count: size * size * 4)
    for offset in stride(from: 0, to: pixels.count, by: 4) {
        for channel in 0 ..< 3 {
            state = state &* 1_664_525 &+ 1_013_904_223
            pixels[offset + channel] = UInt8(truncatingIfNeeded: state >> 24)
        }
    }
    return try encodeRGBA(pixels, size: size)
}

/// An RGBA PNG whose left half is fully transparent and right half opaque.
private func transparentPNG(size: Int) throws -> Data {
    var pixels = [UInt8](repeating: 0, count: size * size * 4)
    for row in 0 ..< size {
        for column in size / 2 ..< size {
            let offset = (row * size + column) * 4
            pixels[offset] = 200
            pixels[offset + 1] = 80
            pixels[offset + 2] = 40
            pixels[offset + 3] = 255
        }
    }
    return try encodeRGBA(pixels, size: size)
}

private func encodeRGBA(
    _ pixels: [UInt8],
    size: Int,
    space: CGColorSpace = CGColorSpaceCreateDeviceRGB()
) throws -> Data {
    var pixels = pixels
    let image: CGImage? = pixels.withUnsafeMutableBytes { buffer in
        CGContext(
            data: buffer.baseAddress,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage()
    }
    guard let image else { throw ConfigurationError("test: could not build the RGBA fixture") }
    return Fixtures.encodePNG(image)
}

/// A noisy opaque PNG tagged with the Display P3 profile (an `iCCP` chunk).
private func displayP3PNG(size: Int) throws -> Data {
    guard let space = CGColorSpace(name: CGColorSpace.displayP3) else {
        throw ConfigurationError("test: no Display P3 colour space")
    }
    var state: UInt32 = 0x0BAD_CAFE
    var pixels = [UInt8](repeating: 255, count: size * size * 4)
    for offset in stride(from: 0, to: pixels.count, by: 4) {
        for channel in 0 ..< 3 {
            state = state &* 1_664_525 &+ 1_013_904_223
            pixels[offset + channel] = UInt8(truncatingIfNeeded: state >> 24)
        }
    }
    return try encodeRGBA(pixels, size: size, space: space)
}

/// Chunk type names in file order.
private func pngChunkTypes(_ data: Data) -> [String] {
    let bytes = [UInt8](data)
    var types: [String] = []
    var index = 8
    while index + 12 <= bytes.count {
        let length = Int(bytes[index]) << 24 | Int(bytes[index + 1]) << 16 | Int(bytes[index + 2]) << 8 |
            Int(bytes[index + 3])
        types.append(String(bytes: bytes[(index + 4) ..< (index + 8)], encoding: .ascii) ?? "?")
        index += 12 + length
    }
    return types
}

/// Marker bytes of the segments before and including the start of scan.
private func jpegMarkers(_ data: Data) -> [UInt8] {
    let bytes = [UInt8](data)
    var markers: [UInt8] = []
    var index = 2
    while index + 4 <= bytes.count, bytes[index] == 0xFF {
        let marker = bytes[index + 1]
        markers.append(marker)
        if marker == 0xDA { break }
        index += 2 + (Int(bytes[index + 2]) << 8 | Int(bytes[index + 3]))
    }
    return markers
}

/// A `width` x `height` synthetic image written as JPEG with the given EXIF orientation tag
/// (the pixels are stored unrotated; viewers rotate on display).
private func orientedJPEG(width: Int, height: Int, orientation: Int) throws -> Data {
    let unrotated = try decode(Fixtures.syntheticPNG(seed: 4, size: CGSize(width: width, height: height))).image
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw ConfigurationError("test: CGImageDestination")
    }
    let properties = [kCGImagePropertyOrientation: orientation] as CFDictionary
    CGImageDestinationAddImage(destination, unrotated, properties)
    guard CGImageDestinationFinalize(destination) else {
        throw ConfigurationError("test: could not write the oriented JPEG")
    }
    return output as Data
}
