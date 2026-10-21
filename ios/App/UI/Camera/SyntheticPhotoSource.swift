#if DEVELOPMENT
import CoreGraphics
import CyberSendFeatures
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Synthetic capture (M3, docs/architecture.md test strategy): a deterministic wall like
// JPEG that feeds the identical PhotoIngest pipeline the camera and library paths use.
// The simulator has no camera, so the XCUITest smoke set reaches capture through the
// "-CYBERSEND_UI_TEST_SEED" launch family and this Development only dialog row; Internal
// and Release compile this whole file out. The drawing is fully deterministic (fixed
// size, fixed colors, fixed geometry): four quadrant wall panels, a center crosshair,
// and three hold discs at fixed positions give UI tests predictable features to tag.

enum SyntheticPhotoSource {
    /// Working size of the generated wall image (portrait, phone like aspect).
    static let width = 1200
    static let height = 1600

    /// The deterministic wall JPEG, or nil when the bitmap context cannot be created.
    static func wallJPEG() -> Data? {
        guard let image = wallImage() else { return nil }
        return jpegData(image)
    }

    // MARK: - Drawing

    private static func wallImage() -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        let halfWidth = CGFloat(width) / 2
        let halfHeight = CGFloat(height) / 2
        let full = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))

        // Four wall panels in distinct colors so quadrants are trivially tellable apart.
        fill(context, CGRect(x: 0, y: halfHeight, width: halfWidth, height: halfHeight), red: 0.72, green: 0.71, blue: 0.68)
        fill(context, CGRect(x: halfWidth, y: halfHeight, width: halfWidth, height: halfHeight), red: 0.35, green: 0.42, blue: 0.55)
        fill(context, CGRect(x: 0, y: 0, width: halfWidth, height: halfHeight), red: 0.55, green: 0.48, blue: 0.40)
        fill(context, CGRect(x: halfWidth, y: 0, width: halfWidth, height: halfHeight), red: 0.22, green: 0.24, blue: 0.26)

        // Center crosshair (image coordinates, y down): the quadrant divider lines.
        stroke(context, [CGPoint(x: halfWidth, y: 0), CGPoint(x: halfWidth, y: CGFloat(height))])
        stroke(context, [CGPoint(x: 0, y: halfHeight), CGPoint(x: CGFloat(width), y: halfHeight)])

        // Three hold discs (start, intermediate, top) at fixed normalized positions:
        // (0.5, 0.82), (0.35, 0.5), (0.5, 0.16), each with a fixed radius.
        disc(context, center: CGPoint(x: halfWidth, y: 0.82 * CGFloat(height)), radius: 70, red: 0.18, green: 0.55, blue: 0.30)
        disc(context, center: CGPoint(x: 0.35 * CGFloat(width), y: halfHeight), radius: 58, red: 0.90, green: 0.55, blue: 0.15)
        disc(context, center: CGPoint(x: halfWidth, y: 0.16 * CGFloat(height)), radius: 66, red: 0.85, green: 0.22, blue: 0.28)

        // Thin border so the edges survive any future letterboxing preview.
        context.setStrokeColor(CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1))
        context.setLineWidth(8)
        context.stroke(full.insetBy(dx: 4, dy: 4))

        return context.makeImage()
    }

    private static func fill(_ context: CGContext, _ rect: CGRect, red: CGFloat, green: CGFloat, blue: CGFloat) {
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(rect)
    }

    private static func stroke(_ context: CGContext, _ points: [CGPoint]) {
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        context.setLineWidth(6)
        context.addLines(between: points)
        context.strokePath()
    }

    private static func disc(_ context: CGContext, center: CGPoint, radius: CGFloat, red: CGFloat, green: CGFloat, blue: CGFloat) {
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fillEllipse(in: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
    }

    // MARK: - Encoding

    private static func jpegData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: photoIngestJPEGQuality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
#endif
