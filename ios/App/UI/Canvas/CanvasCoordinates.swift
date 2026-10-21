import CoreGraphics
import CyberSendDomain
import Foundation

// CGPoint adapters over the pure Domain canvas geometry (M3, US-18, docs/decisions.md
// "canvas is UIScrollView plus CAShapeLayer, geometry pure in Domain"). The canvas hosts
// the photo in a UIScrollView at one point per image pixel when zoomScale is 1, so the
// content box of a view the size of the image is exactly the unit box (scale 1, no
// letterbox); every tap, drag, and hit test converts through contentView.convert first
// and then through these helpers, keeping the normalized 0..1 contract in one place.

enum CanvasCoordinates {
    /// The aspect fit box of the image inside the given view size. Used for the canvas
    /// fit (zoom to fit) and for coordinate round trips in UI tests.
    static func fitBox(imageSize: CGSize, viewSize: CGSize) -> CanvasContentBox {
        fitContentBox(
            imageWidth: Double(imageSize.width),
            imageHeight: Double(imageSize.height),
            viewWidth: Double(viewSize.width),
            viewHeight: Double(viewSize.height)
        )
    }

    /// The content box that maps normalized coordinates into content view points. The
    /// content view frame matches the image pixel size, so this is the unit box, but it
    /// goes through the Domain helper so degenerate sizes stay safe.
    static func contentBox(imageSize: CGSize, viewSize: CGSize) -> CanvasContentBox {
        fitBox(imageSize: imageSize, viewSize: viewSize)
    }

    /// Maps a normalized image point (0..1) to content view points under the box.
    static func canvasPoint(xNorm: Double, yNorm: Double, imageSize: CGSize, box: CanvasContentBox) -> CGPoint {
        let point = normToScreen(
            xNorm: xNorm,
            yNorm: yNorm,
            imageWidth: Double(imageSize.width),
            imageHeight: Double(imageSize.height),
            box: box
        )
        return CGPoint(x: point.x, y: point.y)
    }

    /// The exact inverse of canvasPoint: content view points back to normalized 0..1.
    static func normPoint(x: CGFloat, y: CGFloat, imageSize: CGSize, box: CanvasContentBox) -> CGPoint {
        let point = screenToNorm(
            x: Double(x),
            y: Double(y),
            imageWidth: Double(imageSize.width),
            imageHeight: Double(imageSize.height),
            box: box
        )
        return CGPoint(x: point.x, y: point.y)
    }

    /// Maps a hold radius (relative to image width) to content view points.
    static func canvasRadius(radiusNorm: Double, imageSize: CGSize, box: CanvasContentBox) -> CGFloat {
        CGFloat(normRadiusToScreen(radiusNorm: radiusNorm, imageWidth: Double(imageSize.width), box: box))
    }

    /// Nearest hold under the point, honoring the drag arbitration tolerance. The
    /// tolerance is passed in content view points (the caller scales the touch slop by
    /// the current zoom), so hit testing stays exact at any zoom level.
    static func hitTestHold(
        at point: CGPoint,
        tolerance: CGFloat,
        holds: [Hold],
        imageSize: CGSize,
        box: CanvasContentBox
    ) -> Hold? {
        guard let id = CyberSendDomain.hitTestHold(
            x: Double(point.x),
            y: Double(point.y),
            tolerance: Double(tolerance),
            holds: holds,
            imageWidth: Double(imageSize.width),
            imageHeight: Double(imageSize.height),
            box: box
        ) else {
            return nil
        }
        return holds.first(where: { $0.id == id })
    }
}
