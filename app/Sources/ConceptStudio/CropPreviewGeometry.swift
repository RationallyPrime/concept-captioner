import SwiftUI

/// Top-left crop coordinates mapped into the actual aspect-fit image, excluding its letterbox area.
struct CropPreviewGeometry {
    let imageRect: CGRect
    let cropRect: CGRect

    init(imageSize: CGSize, availableSize: CGSize, crop: CGRect) {
        guard imageSize.width > 0, imageSize.height > 0,
              availableSize.width > 0, availableSize.height > 0 else {
            imageRect = .zero
            cropRect = .zero
            return
        }
        let scale = min(availableSize.width / imageSize.width, availableSize.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        imageRect = CGRect(
            x: (availableSize.width - size.width) / 2,
            y: (availableSize.height - size.height) / 2,
            width: size.width, height: size.height
        )
        cropRect = CGRect(
            x: imageRect.minX + crop.minX * size.width,
            y: imageRect.minY + crop.minY * size.height,
            width: crop.width * size.width, height: crop.height * size.height
        )
    }

    var excludedPixels: Path {
        Path { path in
            path.addRect(imageRect)
            path.addRect(cropRect)
        }
    }
}
