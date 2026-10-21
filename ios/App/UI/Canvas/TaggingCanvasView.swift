import CoreText
import CyberSendDomain
import SwiftUI
import UIKit

// Tagging canvas (M3, US-18, docs/decisions.md "canvas is UIScrollView plus CAShapeLayer,
// geometry pure in Domain"): a UIScrollView hosts a UIImageView of the pixels-up working
// copy (one point per image pixel at zoomScale 1) plus a hold overlay of CAShapeLayers,
// one CGPath subpath per hold. Viewport pan and pinch are pure Core Animation transforms
// of the content layer tree, so gesture frames never touch Swift state or the store, and
// the overlay composites hundreds of vector shapes cheaply (>= 55 fps at 100 holds gate).
//
// Gesture arbitration (docs/architecture.md M3): single tap places a hold on empty space
// or selects a hold under the touch (single tap requires double tap to fail, so a double
// tap toggles fit and 2x without a stray placement); hold drag wins over the scroll pan
// when the touch begins on a hold (scroll pan requires the hold pan to fail, and the
// hold pan's shouldBegin hit test decides in one call); long press on a hold asks the
// screen to confirm a delete. Every coordinate goes through contentView.convert and then
// the pure Domain geometry (CanvasCoordinates), so tap placement error stays at floating
// point round trip level (US-18.4, at most 3 px at 1x).
//
// Rendering (US-19.3, colorblind safe and grayscale readable): start is a square orange
// #E69F00 with an S, intermediate is a circle sky blue #56B4E9 with an I, top is a
// triangle bluish green #009E73 with a T, and unassigned is a hollow diamond. Every
// shape gets a 1.5 pt black outline over a white halo so it stays readable on any photo,
// and the letters keep the roles tellable without color.

struct TaggingCanvasView: UIViewRepresentable {
    /// The accessibility identifier the underlying scroll view exposes to XCUITest
    /// ("tagging.canvas" on the tagging screen, "fall.canvas" in the fall hold sheet).
    var identifier: String = "tagging.canvas"
    var image: CGImage?
    var holds: [Hold] = []
    var selectedHoldId: String? = nil
    /// True for the fall hold picker: taps on holds select and save, taps on empty space
    /// do nothing, and drag and delete are off.
    var isReadOnly: Bool = false
    /// DEVELOPMENT only HUD switch (the CADisplayLink meter in CanvasFPSMeter.swift).
    var showsFPSMeter: Bool = false

    var onPlaceHold: (CGPoint) -> Void = { _ in }
    var onSelectHold: (String?) -> Void = { _ in }
    var onMoveHold: (String, CGPoint) -> Void = { _, _ in }
    var onRequestDeleteHold: (String) -> Void = { _ in }

    func makeUIView(context: Context) -> TaggingCanvasScrollView {
        let view = TaggingCanvasScrollView(frame: .zero)
        view.accessibilityIdentifier = identifier
        return view
    }

    func updateUIView(_ view: TaggingCanvasScrollView, context: Context) {
        view.onPlaceHold = onPlaceHold
        view.onSelectHold = onSelectHold
        view.onMoveHold = onMoveHold
        view.onRequestDeleteHold = onRequestDeleteHold
        view.apply(image: image, holds: holds, selectedHoldId: selectedHoldId, readOnly: isReadOnly)
        view.setFPSMeterVisible(showsFPSMeter)
    }
}

/// The scroll view that hosts the photo and the hold overlay and owns the gestures. One
/// instance per canvas; SwiftUI only pushes state snapshots into apply.
final class TaggingCanvasScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    /// Touch slop in viewport points: a tap or drag start within this distance of a hold
    /// center (plus the hold radius) counts as touching the hold.
    static let tapTolerance: CGFloat = 14

    var onPlaceHold: ((CGPoint) -> Void)?
    var onSelectHold: ((String?) -> Void)?
    var onMoveHold: ((String, CGPoint) -> Void)?
    var onRequestDeleteHold: ((String) -> Void)?

    private let contentView = UIView()
    private let imageView = UIImageView()
    private let fillLayers = (0..<4).map { _ in CAShapeLayer() }
    private let letterLayers = (0..<3).map { _ in CAShapeLayer() }
    private let haloLayer = CAShapeLayer()
    private let outlineLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()

    private var singleTap: UITapGestureRecognizer!
    private var doubleTap: UITapGestureRecognizer!
    private var holdPan: UIPanGestureRecognizer!
    private var longPress: UILongPressGestureRecognizer!

    private var holds: [Hold] = []
    private var selectedHoldId: String?
    private var readOnly = false
    private var loadedImage: CGImage?
    private var imageSize = CGSize.zero
    private var needsInitialFit = true
    private var lastFitScale: CGFloat = 1

    private var draggedHoldId: String?
    private var dragOffset = CGPoint.zero
    /// Live position of the dragged hold during a drag, so gesture frames redraw the
    /// overlay without touching the store; cleared when the drag ends and commits.
    private var dragOverride: (id: String, point: CGPoint)?

    #if DEVELOPMENT
    private var fpsMeter: CanvasFPSMeter?
    private var fpsLabel: CanvasFPSLabel?
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configure() {
        backgroundColor = .clear
        minimumZoomScale = 0.05
        maximumZoomScale = 4
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        delegate = self

        contentView.backgroundColor = .clear
        imageView.contentMode = .scaleToFill
        addSubview(contentView)
        contentView.addSubview(imageView)
        for layer in overlayLayers {
            contentView.layer.addSublayer(layer)
        }

        isAccessibilityElement = true
        accessibilityTraits = .image

        installGestures()
    }

    private var overlayLayers: [CAShapeLayer] {
        fillLayers + letterLayers + [haloLayer, outlineLayer, selectionLayer]
    }

    private func installGestures() {
        singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        // A single tap waits for the double tap to fail, so the double tap zoom toggle
        // never leaves a stray hold behind (docs/architecture.md M3 gesture risks).
        singleTap.require(toFail: doubleTap)

        holdPan = UIPanGestureRecognizer(target: self, action: #selector(handleHoldPan))
        holdPan.delegate = self
        longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        longPress.minimumPressDuration = 0.55
        longPress.delegate = self

        addGestureRecognizer(singleTap)
        addGestureRecognizer(doubleTap)
        addGestureRecognizer(holdPan)
        addGestureRecognizer(longPress)
        // The scroll pan waits for the hold pan: the hold pan's shouldBegin hit test
        // makes a touch that starts on a hold drag the hold, and any other touch fails
        // the hold pan immediately so scrolling is unaffected.
        panGestureRecognizer.require(toFail: holdPan)
    }

    // MARK: - State (SwiftUI pushes snapshots here)

    /// Applies one SwiftUI state snapshot: image, holds, selection, and mode. The image
    /// installs once (identity compare); the overlay rebuilds from the new hold list.
    func apply(image: CGImage?, holds: [Hold], selectedHoldId: String?, readOnly: Bool) {
        self.readOnly = readOnly
        if image !== loadedImage {
            loadedImage = image
            install(image: image)
        }
        self.holds = holds
        self.selectedHoldId = selectedHoldId
        if let override = dragOverride, !holds.contains(where: { $0.id == override.id }) {
            dragOverride = nil
        }
        rebuildOverlay()
        accessibilityLabel = "Wall photo with \(holds.count) tagged holds"
    }

    private func install(image: CGImage?) {
        guard let image else {
            imageView.image = nil
            imageSize = .zero
            return
        }
        imageView.image = UIImage(cgImage: image)
        imageSize = CGSize(width: image.width, height: image.height)
        contentView.frame = CGRect(origin: .zero, size: imageSize)
        imageView.frame = contentView.bounds
        for layer in overlayLayers {
            layer.frame = contentView.bounds
            layer.contentsScale = UIScreen.main.scale
        }
        configureOverlayLayers()
        needsInitialFit = true
        setNeedsLayout()
    }

    private func configureOverlayLayers() {
        for (index, layer) in fillLayers.enumerated() {
            layer.fillColor = index < 3 ? Self.roleFillColors[index] : UIColor.clear.cgColor
            layer.strokeColor = nil
        }
        for layer in letterLayers {
            layer.fillColor = UIColor.black.cgColor
            layer.strokeColor = nil
        }
        haloLayer.fillColor = nil
        haloLayer.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
        haloLayer.lineWidth = 4
        haloLayer.lineJoin = .round
        outlineLayer.fillColor = nil
        outlineLayer.strokeColor = UIColor.black.cgColor
        outlineLayer.lineWidth = 1.5
        outlineLayer.lineJoin = .round
        selectionLayer.fillColor = UIColor.systemBlue.cgColor
        selectionLayer.strokeColor = UIColor.systemBlue.cgColor
        selectionLayer.lineWidth = 2
    }

    // MARK: - Layout and zoom

    override func layoutSubviews() {
        super.layoutSubviews()
        if imageSize.width > 0, bounds.width > 0, bounds.height > 0 {
            let fit = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
            if abs(fit - lastFitScale) > 0.000_1 {
                let wasAtFit = needsInitialFit || zoomScale <= lastFitScale * 1.02
                lastFitScale = fit
                minimumZoomScale = fit
                maximumZoomScale = max(1, fit * 4)
                if wasAtFit {
                    zoomScale = fit
                }
            }
            needsInitialFit = false
        }
        centerContent()
        positionFPSLabel()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        contentView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
    }

    /// Letterbox centering while zoomed (the shorter axis centers in its gap).
    private func centerContent() {
        let size = bounds.size
        let frame = contentView.frame
        let insetX = max(0, (size.width - frame.width) / 2)
        let insetY = max(0, (size.height - frame.height) / 2)
        contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        #if DEVELOPMENT
        if window == nil {
            fpsMeter?.stop()
        } else if fpsMeter != nil {
            fpsMeter?.start()
        }
        #endif
    }

    // MARK: - Gesture arbitration

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer == holdPan {
            guard !readOnly,
                  let hold = holdUnder(gestureRecognizer.location(in: contentView))
            else {
                return false
            }
            let touch = gestureRecognizer.location(in: contentView)
            let center = contentCenter(of: hold, box: currentBox())
            draggedHoldId = hold.id
            dragOffset = CGPoint(x: center.x - touch.x, y: center.y - touch.y)
            return true
        }
        if gestureRecognizer == longPress {
            guard !readOnly,
                  let hold = holdUnder(gestureRecognizer.location(in: contentView))
            else {
                return false
            }
            return true
        }
        return true
    }

    @objc private func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: contentView)
        if let hold = holdUnder(point) {
            onSelectHold?(hold.id)
            return
        }
        guard !readOnly else { return }
        onPlaceHold?(clampedNorm(at: point))
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: contentView)
        let fit = minimumZoomScale
        if zoomScale > fit * 1.25 {
            setZoomScale(fit, animated: true)
        } else {
            let target = min(fit * 2, maximumZoomScale)
            guard target > fit else { return }
            let visible = CGSize(width: bounds.width / target, height: bounds.height / target)
            let rect = CGRect(
                x: point.x - visible.width / 2,
                y: point.y - visible.height / 2,
                width: visible.width,
                height: visible.height
            )
            zoom(to: rect, animated: true)
        }
    }

    @objc private func handleHoldPan(_ recognizer: UIPanGestureRecognizer) {
        guard let holdId = draggedHoldId, holds.contains(where: { $0.id == holdId }) else { return }
        let touch = recognizer.location(in: contentView)
        let target = clampedContentPoint(CGPoint(x: touch.x + dragOffset.x, y: touch.y + dragOffset.y))
        switch recognizer.state {
        case .changed:
            dragOverride = (holdId, target)
            rebuildOverlay()
        case .ended, .cancelled, .failed:
            dragOverride = nil
            draggedHoldId = nil
            rebuildOverlay()
            onMoveHold?(holdId, clampedNorm(at: target))
        default:
            break
        }
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        // Cancel the in-flight tap so releasing after the long press never places or
        // selects a hold on top of the delete confirmation.
        singleTap.isEnabled = false
        singleTap.isEnabled = true
        if let hold = holdUnder(recognizer.location(in: contentView)) {
            onRequestDeleteHold?(hold.id)
        }
    }

    /// Nearest hold under a content point, with the touch slop scaled by the zoom so the
    /// tolerance is constant in the user's fingertips (viewport points).
    private func holdUnder(_ point: CGPoint) -> Hold? {
        let tolerance = Self.tapTolerance / max(zoomScale, 0.000_1)
        return CanvasCoordinates.hitTestHold(
            at: point,
            tolerance: tolerance,
            holds: displayedHolds,
            imageSize: imageSize,
            box: currentBox()
        )
    }

    // MARK: - Coordinates

    private func currentBox() -> CanvasContentBox {
        CanvasCoordinates.contentBox(imageSize: imageSize, viewSize: contentView.bounds.size)
    }

    private func contentCenter(of hold: Hold, box: CanvasContentBox) -> CGPoint {
        if let override = dragOverride, override.id == hold.id {
            return override.point
        }
        return CanvasCoordinates.canvasPoint(
            xNorm: hold.xNorm,
            yNorm: hold.yNorm,
            imageSize: imageSize,
            box: box
        )
    }

    private func clampedNorm(at point: CGPoint) -> CGPoint {
        let norm = CanvasCoordinates.normPoint(x: point.x, y: point.y, imageSize: imageSize, box: currentBox())
        return CGPoint(x: min(max(norm.x, 0), 1), y: min(max(norm.y, 0), 1))
    }

    private func clampedContentPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), imageSize.width),
            y: min(max(point.y, 0), imageSize.height)
        )
    }

    /// The holds as rendered, with the live drag position applied to the dragged hold.
    private var displayedHolds: [Hold] {
        guard let override = dragOverride else { return holds }
        return holds.map { hold in
            guard hold.id == override.id else { return hold }
            let norm = CanvasCoordinates.normPoint(
                x: override.point.x,
                y: override.point.y,
                imageSize: imageSize,
                box: currentBox()
            )
            var moved = hold
            moved.xNorm = min(max(norm.x, 0), 1)
            moved.yNorm = min(max(norm.y, 0), 1)
            return moved
        }
    }

    // MARK: - Overlay rendering

    private func rebuildOverlay() {
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let box = currentBox()
        var fills = Array(repeating: UIBezierPath(), count: 4)
        var letters = Array(repeating: UIBezierPath(), count: 3)
        let outline = UIBezierPath()
        for hold in displayedHolds {
            let center = contentCenter(of: hold, box: box)
            let radius = CanvasCoordinates.canvasRadius(
                radiusNorm: hold.radiusNorm,
                imageSize: imageSize,
                box: box
            )
            let shape = Self.shapePath(role: hold.role, center: center, radius: radius)
            if let role = hold.role {
                let index = Self.roleIndex(role)
                fills[index].append(shape)
                if let glyph = Self.glyphPaths[index] {
                    var transform = CGAffineTransform(scaleX: radius * 1.1, y: radius * 1.1)
                        .translatedBy(x: center.x, y: center.y)
                    if let moved = glyph.copy(using: &transform) {
                        letters[index].append(UIBezierPath(cgPath: moved))
                    }
                }
            }
            outline.append(shape)
        }
        for index in 0..<4 {
            fillLayers[index].path = fills[index].cgPath
        }
        for index in 0..<3 {
            letterLayers[index].path = letters[index].cgPath
        }
        haloLayer.path = outline.cgPath
        outlineLayer.path = outline.cgPath
        selectionLayer.path = selectionPath(box: box).cgPath
        #if DEVELOPMENT
        if let fpsLabel, let fps = fpsMeter?.fps {
            fpsLabel.update(fps: fps, holdCount: holds.count)
        }
        #endif
    }

    private func selectionPath(box: CanvasContentBox) -> UIBezierPath {
        let path = UIBezierPath()
        guard
            let selected = displayedHolds.first(where: { $0.id == selectedHoldId })
        else {
            return path
        }
        let center = contentCenter(of: selected, box: box)
        let radius = CanvasCoordinates.canvasRadius(
            radiusNorm: selected.radiusNorm,
            imageSize: imageSize,
            box: box
        )
        let ring = radius + 7
        path.append(UIBezierPath(ovalIn: CGRect(
            x: center.x - ring,
            y: center.y - ring,
            width: ring * 2,
            height: ring * 2
        )))
        let handle: CGFloat = 5
        for signX: CGFloat in [-1, 1] {
            for signY: CGFloat in [-1, 1] {
                path.append(UIBezierPath(rect: CGRect(
                    x: center.x + signX * ring - handle,
                    y: center.y + signY * ring - handle,
                    width: handle * 2,
                    height: handle * 2
                )))
            }
        }
        return path
    }

    // MARK: - Shape and letter geometry

    private static func roleIndex(_ role: HoldRole) -> Int {
        switch role {
        case .start: return 0
        case .intermediate: return 1
        case .top: return 2
        }
    }

    private static let roleFillColors: [CGColor] = [
        CGColor(red: 0.902, green: 0.624, blue: 0, alpha: 1),
        CGColor(red: 0.337, green: 0.706, blue: 0.914, alpha: 1),
        CGColor(red: 0, green: 0.62, blue: 0.451, alpha: 1),
    ]

    /// One unit height glyph outline per role letter, centered at the origin, scaled and
    /// translated per hold into the letter path (no CATextLayer churn at 100 holds).
    private static let glyphPaths: [CGPath?] = ["S", "I", "T"].map { unitGlyph($0) }

    private static func unitGlyph(_ character: Character) -> CGPath? {
        var characters = Array(String(character).utf16)
        guard characters.count == 1 else { return nil }
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 100, nil)
        var glyph: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(font, &characters, &glyph, 1),
              let path = CTFontCreatePathForGlyph(font, glyph, nil)
        else {
            return nil
        }
        let bounds = path.boundingBoxOfPath
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        // Scale to unit height, flip Core Text's y-up into UIKit's y-down, and center.
        let scale = 1 / bounds.height
        var transform = CGAffineTransform(
            a: scale,
            b: 0,
            c: 0,
            d: -scale,
            tx: -bounds.midX * scale,
            ty: bounds.midY * scale
        )
        return path.copy(using: &transform)
    }

    /// The hold silhouette: square for start, circle for intermediate, triangle for top,
    /// hollow diamond for unassigned (stroke only, drawn by the outline layers).
    private static func shapePath(role: HoldRole?, center: CGPoint, radius: CGFloat) -> UIBezierPath {
        let square = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        switch role {
        case .start:
            return UIBezierPath(rect: square)
        case .intermediate:
            return UIBezierPath(ovalIn: square)
        case .top:
            let path = UIBezierPath()
            path.move(to: CGPoint(x: center.x, y: center.y - radius))
            path.addLine(to: CGPoint(x: center.x - radius * 0.95, y: center.y + radius * 0.78))
            path.addLine(to: CGPoint(x: center.x + radius * 0.95, y: center.y + radius * 0.78))
            path.close()
            return path
        case nil:
            let path = UIBezierPath()
            path.move(to: CGPoint(x: center.x, y: center.y - radius * 1.15))
            path.addLine(to: CGPoint(x: center.x - radius * 1.15, y: center.y))
            path.addLine(to: CGPoint(x: center.x, y: center.y + radius * 1.15))
            path.addLine(to: CGPoint(x: center.x + radius * 1.15, y: center.y))
            path.close()
            return path
        }
    }

    // MARK: - DEVELOPMENT FPS HUD

    func setFPSMeterVisible(_ visible: Bool) {
        #if DEVELOPMENT
        if visible {
            if fpsLabel == nil {
                let label = CanvasFPSLabel(frame: .zero)
                addSubview(label)
                fpsLabel = label
                let meter = CanvasFPSMeter()
                meter.onSample = { [weak self] fps in
                    guard let self else { return }
                    self.fpsLabel?.update(fps: fps, holdCount: self.holds.count)
                }
                fpsMeter = meter
            }
            if window != nil {
                fpsMeter?.start()
            }
        } else {
            fpsMeter?.stop()
            fpsLabel?.removeFromSuperview()
            fpsLabel = nil
            fpsMeter = nil
        }
        #endif
    }

    private func positionFPSLabel() {
        #if DEVELOPMENT
        guard let fpsLabel else { return }
        fpsLabel.frame.origin = CGPoint(
            x: bounds.width - fpsLabel.bounds.width - 8,
            y: 8
        )
        #endif
    }
}
