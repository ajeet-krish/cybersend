import Testing
@testable import CyberSendDomain

// Canvas geometry tests (M3, US-18): the aspect fit contract, the exact norm to screen
// round trip that backs the 3 px tap accuracy budget, and the hit test arbitration that
// lets a hold drag win over the scroll pan.

@Suite("Canvas geometry")
struct CanvasGeometryTests {
    // MARK: - fitContentBox

    @Test("fit is aspect fit with centered letterbox offsets")
    func fitContentBoxAspectFit() {
        // Landscape image in a square view: the width binds, height letterboxes.
        let landscape = fitContentBox(imageWidth: 2000, imageHeight: 1000, viewWidth: 400, viewHeight: 400)
        #expect(landscape.scale == 0.2)
        #expect(landscape.offsetX == 0)
        #expect(landscape.offsetY == 100)

        // Portrait image in a wide view: the height binds, width letterboxes.
        let portrait = fitContentBox(imageWidth: 1000, imageHeight: 2000, viewWidth: 400, viewHeight: 300)
        #expect(portrait.scale == 0.15)
        #expect(portrait.offsetX == (400 - 150) / 2)
        #expect(portrait.offsetY == 0)

        // Square image in a rectangular view: both axes letterbox around a centered fit.
        let square = fitContentBox(imageWidth: 1000, imageHeight: 1000, viewWidth: 400, viewHeight: 200)
        #expect(square.scale == 0.2)
        #expect(square.offsetX == 100)
        #expect(square.offsetY == 0)
    }

    @Test("degenerate sizes produce the empty box and mappings degenerate to the origin")
    func degenerateSizes() {
        let zeroView = fitContentBox(imageWidth: 100, imageHeight: 100, viewWidth: 0, viewHeight: 0)
        #expect(zeroView == canvasEmptyContentBox)
        #expect(zeroView.isEmpty)

        let zeroImage = fitContentBox(imageWidth: 0, imageHeight: 0, viewWidth: 400, viewHeight: 300)
        #expect(zeroImage.isEmpty)

        let negative = fitContentBox(imageWidth: -10, imageHeight: 10, viewWidth: 10, viewHeight: 10)
        #expect(negative.isEmpty)

        // Under the empty box the mappings return the origin instead of NaN or a crash.
        let screen = normToScreen(xNorm: 0.5, yNorm: 0.75, imageWidth: 100, imageHeight: 100, box: zeroView)
        #expect(screen == CanvasPoint(x: 0, y: 0))
        let norm = screenToNorm(x: 120, y: 340, imageWidth: 100, imageHeight: 100, box: zeroView)
        #expect(norm == CanvasPoint(x: 0, y: 0))
        #expect(normRadiusToScreen(radiusNorm: 0.02, imageWidth: 100, box: zeroView) == 0)

        // Zero image dimensions with a valid box degrade the same way.
        let odd = CanvasContentBox(scale: 0.5, offsetX: 10, offsetY: 20)
        #expect(normToScreen(xNorm: 0.5, yNorm: 0.5, imageWidth: 0, imageHeight: 80, box: odd).x == 10)
        #expect(screenToNorm(x: 50, y: 50, imageWidth: 0, imageHeight: 80, box: odd) == CanvasPoint(x: 0, y: 0))
    }

    // MARK: - Round trips

    @Test("norm to screen to norm round trips 10000 points under 1e-6 (US-18.4)")
    func roundTripsTenThousandPoints() {
        var rng = SplitMix64(seed: 20_261_020)
        let boxes = [
            fitContentBox(imageWidth: 2048, imageHeight: 1536, viewWidth: 390, viewHeight: 600),
            fitContentBox(imageWidth: 1536, imageHeight: 2048, viewWidth: 390, viewHeight: 600),
            fitContentBox(imageWidth: 2048, imageHeight: 2048, viewWidth: 320, viewHeight: 320),
        ]
        for box in boxes {
            var maxError = 0.0
            for _ in 0..<10_000 {
                let xNorm = Double.random(in: 0 ... 1, using: &rng)
                let yNorm = Double.random(in: 0 ... 1, using: &rng)
                let screen = normToScreen(
                    xNorm: xNorm, yNorm: yNorm, imageWidth: 2048, imageHeight: 1536, box: box
                )
                let back = screenToNorm(
                    x: screen.x, y: screen.y, imageWidth: 2048, imageHeight: 1536, box: box
                )
                maxError = max(maxError, abs(back.x - xNorm), abs(back.y - yNorm))
            }
            #expect(maxError < 1e-6, "round trip error \(maxError) exceeded 1e-6")
        }
    }

    @Test("norm radius scales with the content and ignores the letterbox offsets")
    func radiusScaling() {
        let box = fitContentBox(imageWidth: 2048, imageHeight: 1536, viewWidth: 400, viewHeight: 400)
        // The default 0.02 radius over a 2048 px image at the fit scale.
        #expect(normRadiusToScreen(radiusNorm: 0.02, imageWidth: 2048, box: box) == 0.02 * 2048 * box.scale)
        // Radius has no offset: doubling the radius doubles the screen radius.
        let doubled = normRadiusToScreen(radiusNorm: 0.04, imageWidth: 2048, box: box)
        #expect(doubled == 2 * normRadiusToScreen(radiusNorm: 0.02, imageWidth: 2048, box: box))
    }

    @Test("corner points map to the letterboxed content corners exactly")
    func cornerMapping() {
        let box = fitContentBox(imageWidth: 2000, imageHeight: 1000, viewWidth: 400, viewHeight: 400)
        #expect(normToScreen(xNorm: 0, yNorm: 0, imageWidth: 2000, imageHeight: 1000, box: box)
            == CanvasPoint(x: 0, y: 100))
        #expect(normToScreen(xNorm: 1, yNorm: 1, imageWidth: 2000, imageHeight: 1000, box: box)
            == CanvasPoint(x: 400, y: 300))
        #expect(screenToNorm(x: 0, y: 100, imageWidth: 2000, imageHeight: 1000, box: box)
            == CanvasPoint(x: 0, y: 0))
        #expect(screenToNorm(x: 400, y: 300, imageWidth: 2000, imageHeight: 1000, box: box)
            == CanvasPoint(x: 1, y: 1))
    }

    // MARK: - Hit testing

    private let hitBox = fitContentBox(imageWidth: 1000, imageHeight: 1000, viewWidth: 500, viewHeight: 500)

    private func hold(id: String, x: Double, y: Double, radius: Double) -> Hold {
        Hold(id: id, climbId: "climb-1", xNorm: x, yNorm: y, radiusNorm: radius,
             createdAt: "2026-10-20T00:00:00Z", updatedAt: "2026-10-20T00:00:00Z")
    }

    @Test("a tap on a hold center selects that hold")
    func tapOnCenterSelects() {
        let holds = [
            hold(id: "a", x: 0.2, y: 0.2, radius: 0.02),
            hold(id: "b", x: 0.8, y: 0.8, radius: 0.02),
        ]
        let point = normToScreen(xNorm: 0.8, yNorm: 0.8, imageWidth: 1000, imageHeight: 1000, box: hitBox)
        #expect(hitTestHold(
            x: point.x, y: point.y, tolerance: 0, holds: holds,
            imageWidth: 1000, imageHeight: 1000, box: hitBox
        ) == "b")
    }

    @Test("the tap lands on a hold circle or its tolerance slack, never beyond")
    func toleranceSlack() {
        // The hold sits at 0.5 with a 10 px screen radius under the box (0.02 over
        // 1000 px at scale 0.5).
        let holds = [hold(id: "a", x: 0.5, y: 0.5, radius: 0.02)]
        let center = normToScreen(xNorm: 0.5, yNorm: 0.5, imageWidth: 1000, imageHeight: 1000, box: hitBox)
        #expect(normRadiusToScreen(radiusNorm: 0.02, imageWidth: 1000, box: hitBox) == 10)

        func hit(dx: Double, tolerance: Double) -> String? {
            hitTestHold(
                x: center.x + dx, y: center.y, tolerance: tolerance, holds: holds,
                imageWidth: 1000, imageHeight: 1000, box: hitBox
            )
        }

        #expect(hit(dx: 8, tolerance: 0) == "a", "inside the circle")
        #expect(hit(dx: 12, tolerance: 0) == nil, "outside the circle with no tolerance")
        #expect(hit(dx: 12, tolerance: 5) == "a", "inside the tolerance slack")
        #expect(hit(dx: 16, tolerance: 5) == nil, "beyond radius plus slack")
        #expect(hit(dx: 8, tolerance: -3) == "a", "negative tolerance clamps to zero, still on the circle")
        #expect(hit(dx: 12, tolerance: -3) == nil)
    }

    @Test("the nearest hold wins and equidistant taps break toward the smaller radius")
    func nearestWinsWithRadiusTieBreak() {
        let holds = [
            hold(id: "big", x: 0.4, y: 0.5, radius: 0.05),
            hold(id: "small", x: 0.6, y: 0.5, radius: 0.02),
        ]
        // Dead center between the two: equal distance, so the smaller radius wins. The
        // 40 pt tolerance slack makes both equidistant taps candidates (45 and 30 pt
        // reach against 50 pt of distance).
        let point = CanvasPoint(x: 250, y: 250)
        #expect(hitTestHold(
            x: point.x, y: point.y, tolerance: 40, holds: holds,
            imageWidth: 1000, imageHeight: 1000, box: hitBox
        ) == "small")

        // A point closer to the big hold selects it despite the smaller hold's presence.
        let towardBig = CanvasPoint(x: 210, y: 250)
        #expect(hitTestHold(
            x: towardBig.x, y: towardBig.y, tolerance: 0, holds: holds,
            imageWidth: 1000, imageHeight: 1000, box: hitBox
        ) == "big")
    }

    @Test("empty hold sets and out of range taps miss")
    func missCases() {
        let point = CanvasPoint(x: 250, y: 250)
        #expect(hitTestHold(
            x: point.x, y: point.y, tolerance: 10, holds: [],
            imageWidth: 1000, imageHeight: 1000, box: hitBox
        ) == nil)

        let holds = [hold(id: "a", x: 0.1, y: 0.1, radius: 0.02)]
        #expect(hitTestHold(
            x: point.x, y: point.y, tolerance: 10, holds: holds,
            imageWidth: 1000, imageHeight: 1000, box: hitBox
        ) == nil)
    }
}

/// Deterministic split mix generator so the round trip suite is reproducible.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
