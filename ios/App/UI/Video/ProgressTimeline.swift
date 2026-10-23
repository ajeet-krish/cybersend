import CyberSendDomain
import SwiftUI

// Clip timeline (P5): the attempt window as a shaded band, the progress curve as a sparkline,
// fall markers, and a playhead. Tap or drag anywhere to seek.
//
// The curve is height above the clip's lowest body centroid in body heights, so its shape is
// comparable between clips even when the camera distance changed. It is deliberately not a
// spatial path: the y axis is vertical progress, not position in the frame.

struct ProgressTimeline: View {
    let metrics: TierAMetrics
    let currentMs: Int
    let durationMs: Int
    let onSeek: (Int) -> Void

    private var spanMs: Int {
        let lastSample = metrics.progress.last?.tMs ?? 0
        return max(1, max(durationMs, lastSample))
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            Canvas { context, _ in
                draw(in: &context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(1, max(0, value.location.x / max(1, size.width)))
                        onSeek(Int((Double(spanMs) * fraction).rounded()))
                    }
            )
        }
        .frame(height: 64)
        .accessibilityIdentifier("video.timeline")
        .accessibilityLabel("Clip timeline")
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let inset: CGFloat = 8
        let top = inset
        let bottom = size.height - inset
        let height = bottom - top
        let width = size.width

        func x(for ms: Int) -> CGFloat {
            width * CGFloat(min(1, max(0, Double(ms) / Double(spanMs))))
        }

        // Attempt window band.
        let windowStart = x(for: metrics.attemptWindow.startMs)
        let windowEnd = x(for: metrics.attemptWindow.endMs)
        let band = CGRect(
            x: windowStart,
            y: top,
            width: max(2, windowEnd - windowStart),
            height: height
        )
        context.fill(
            Path(roundedRect: band, cornerRadius: 4),
            with: .color(Theme.accent.opacity(0.14))
        )

        // Baseline.
        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: bottom))
        baseline.addLine(to: CGPoint(x: width, y: bottom))
        context.stroke(baseline, with: .color(Theme.separator), lineWidth: 1)

        // Progress curve.
        if metrics.progress.count > 1 {
            let peak = max(0.0001, metrics.progress.map(\.value).max() ?? 0)
            var curve = Path()
            for (index, sample) in metrics.progress.enumerated() {
                let point = CGPoint(
                    x: x(for: sample.tMs),
                    y: bottom - CGFloat(min(1, sample.value / peak)) * height
                )
                if index == 0 {
                    curve.move(to: point)
                } else {
                    curve.addLine(to: point)
                }
            }
            context.stroke(
                curve,
                with: .color(Theme.accent),
                style: StrokeStyle(lineWidth: 2, lineJoin: .round)
            )
        }

        // Fall markers: a small triangle sitting on the baseline at the fall time.
        for fall in metrics.fallEvents {
            let center = x(for: fall.startMs)
            var marker = Path()
            marker.move(to: CGPoint(x: center, y: bottom - 1))
            marker.addLine(to: CGPoint(x: center - 4, y: bottom - 9))
            marker.addLine(to: CGPoint(x: center + 4, y: bottom - 9))
            marker.closeSubpath()
            context.fill(marker, with: .color(Theme.danger))
        }

        // Playhead.
        let playhead = x(for: currentMs)
        var line = Path()
        line.move(to: CGPoint(x: playhead, y: 0))
        line.addLine(to: CGPoint(x: playhead, y: size.height))
        context.stroke(line, with: .color(Theme.primaryText), lineWidth: 1.5)
    }
}
