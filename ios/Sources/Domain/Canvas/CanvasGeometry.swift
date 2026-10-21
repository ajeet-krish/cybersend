import Foundation

// Canvas coordinate geometry (M3, US-18): pure helpers over the normalized 0..1 contract
// (docs/decisions.md "2026-10-20, Phase 2 (M3): canvas is UIScrollView plus CAShapeLayer,
// geometry pure in Domain"). The canvas maps the pixels up working copy into its bounds
// with an aspect fit, so one content box carries the scale plus the letterbox offsets.
// Holds travel normalized; only distances, radii, and tap points live in screen points.

/// A 2D point in screen coordinates (canvas local points), plain Doubles so the Domain
/// layer stays zero dependency beyond Foundation.
public struct CanvasPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// How the image content sits inside the canvas view: a single aspect fit scale plus the
/// letterbox offsets that center it. Degenerate inputs (zero or negative sizes) produce
/// the empty box, and every mapping helper degenerates to the origin under it instead of
/// producing NaN or dividing by zero.
public struct CanvasContentBox: Equatable, Sendable {
    /// Image pixels to screen points.
    public let scale: Double
    /// Left letterbox inset in screen points.
    public let offsetX: Double
    /// Top letterbox inset in screen points.
    public let offsetY: Double

    public init(scale: Double, offsetX: Double, offsetY: Double) {
        self.scale = scale
        self.offsetX = offsetX
        self.offsetY = offsetY
    }

    /// True when the box carries no usable mapping (zero scale).
    public var isEmpty: Bool { scale <= 0 }
}

/// The box returned for degenerate image or view sizes.
public let canvasEmptyContentBox = CanvasContentBox(scale: 0, offsetX: 0, offsetY: 0)

/// Aspect fit of the image inside the view, centered on both axes. The scale binds to
/// whichever axis is tighter and the offsets are the resulting letterbox bars.
public func fitContentBox(
    imageWidth: Double,
    imageHeight: Double,
    viewWidth: Double,
    viewHeight: Double
) -> CanvasContentBox {
    guard imageWidth > 0, imageHeight > 0, viewWidth > 0, viewHeight > 0 else {
        return canvasEmptyContentBox
    }
    let scale = min(viewWidth / imageWidth, viewHeight / imageHeight)
    let offsetX = (viewWidth - imageWidth * scale) / 2
    let offsetY = (viewHeight - imageHeight * scale) / 2
    return CanvasContentBox(scale: scale, offsetX: offsetX, offsetY: offsetY)
}

/// Maps a normalized image point (0..1) to screen points under the box.
public func normToScreen(
    xNorm: Double,
    yNorm: Double,
    imageWidth: Double,
    imageHeight: Double,
    box: CanvasContentBox
) -> CanvasPoint {
    guard !box.isEmpty, imageWidth > 0, imageHeight > 0 else {
        return CanvasPoint(x: box.offsetX, y: box.offsetY)
    }
    return CanvasPoint(
        x: xNorm * imageWidth * box.scale + box.offsetX,
        y: yNorm * imageHeight * box.scale + box.offsetY
    )
}

/// The exact inverse of normToScreen: screen points back to normalized 0..1. The pair
/// round trips to floating point precision (the tap accuracy guarantee behind US-18.4).
public func screenToNorm(
    x: Double,
    y: Double,
    imageWidth: Double,
    imageHeight: Double,
    box: CanvasContentBox
) -> CanvasPoint {
    guard !box.isEmpty, imageWidth > 0, imageHeight > 0 else {
        return CanvasPoint(x: 0, y: 0)
    }
    return CanvasPoint(
        x: (x - box.offsetX) / (imageWidth * box.scale),
        y: (y - box.offsetY) / (imageHeight * box.scale)
    )
}

/// Maps a hold radius (radius_norm is relative to image width) to screen points. Radius
/// has no offset: it scales with the content only.
public func normRadiusToScreen(
    radiusNorm: Double,
    imageWidth: Double,
    box: CanvasContentBox
) -> Double {
    guard !box.isEmpty, imageWidth > 0 else { return 0 }
    return radiusNorm * imageWidth * box.scale
}

/// Nearest hold hit test for tap selection and drag arbitration (a touch that lands on a
/// hold makes the hold drag win over the scroll pan). A hold is a candidate when the tap
/// lands within its drawn circle plus the tolerance slack in screen points, so tapping
/// anywhere on a hold selects it and sloppy taps still land. The nearest candidate wins;
/// equidistant candidates break the tie toward the smaller radius, then toward the
/// smaller id so the result is fully deterministic.
public func hitTestHold(
    x: Double,
    y: Double,
    tolerance: Double,
    holds: [Hold],
    imageWidth: Double,
    imageHeight: Double,
    box: CanvasContentBox
) -> String? {
    let slack = max(0, tolerance)
    var best: (id: String, distance: Double, radiusNorm: Double)?
    for hold in holds {
        let center = normToScreen(
            xNorm: hold.xNorm,
            yNorm: hold.yNorm,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            box: box
        )
        let radius = normRadiusToScreen(radiusNorm: hold.radiusNorm, imageWidth: imageWidth, box: box)
        let distance = hypot(x - center.x, y - center.y)
        guard distance <= radius + slack else { continue }
        if let current = best {
            if current.distance < distance { continue }
            if current.distance == distance {
                if current.radiusNorm < hold.radiusNorm { continue }
                if current.radiusNorm == hold.radiusNorm && current.id <= hold.id { continue }
            }
        }
        best = (hold.id, distance, hold.radiusNorm)
    }
    return best?.id
}
