import CoreGraphics
import Foundation
import ImageIO

/// Lightweight per-page image stats read straight off the scanned TIFF, surfaced
/// in the `page_scanned` event so the manifest can answer "did the feeder pull a
/// real page?" — dimensions/DPI catch misfeeds, and mean luminance flags blank
/// pages (an empty ADF sheet or the blank back side of a simplex original).
struct ImageMetrics {
    let width: Int
    let height: Int
    let dpi: Int?
    /// Average pixel brightness, 0.0 (all black) .. 1.0 (all white). A blank scan
    /// sits very close to 1.0.
    let meanLuminance: Double
}

/// Compute metrics for the image at `url`, or nil if it can't be decoded.
/// Mean luminance is obtained by drawing the whole image into a 1×1 grayscale
/// context — Core Graphics downsamples it to a single averaged pixel for us.
func computeImageMetrics(url: URL) -> ImageMetrics? {
    guard
        let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        return nil
    }

    var dpi: Int?
    if
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let dpiValue = props[kCGImagePropertyDPIWidth] as? Double,
        dpiValue > 0
    {
        dpi = Int(dpiValue.rounded())
    }

    var pixel: UInt8 = 0
    let grayscale = CGColorSpaceCreateDeviceGray()
    guard
        let ctx = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 1,
            space: grayscale,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
    else {
        return nil
    }
    ctx.interpolationQuality = .medium
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))

    return ImageMetrics(
        width: image.width,
        height: image.height,
        dpi: dpi,
        meanLuminance: Double(pixel) / 255.0
    )
}
