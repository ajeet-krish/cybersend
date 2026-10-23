import CyberSendDomain
import CyberSendFeatures
import SwiftUI

// Compare (P6): two analysed clips on numbers only, gated on camera stability.
//
// There is no pixel level overlay of two videos. Handheld footage has no shared coordinate frame,
// and even two fixed camera clips can differ in distance and angle, so the screen shows the
// normalized progress curves and the metric table, and only offers a spatial read of the
// hesitation maps when both clips were filmed from a fixed camera (docs/decisions.md, 2026-10-22
// P6 record).

struct CompareView: View {
    let services: AppServices
    private let preselectedId: String?

    @StateObject private var store: VideoAnalysisStore
    @State private var leftId: String?
    @State private var rightId: String?
    @State private var leftMetrics: TierAMetrics?
    @State private var rightMetrics: TierAMetrics?
    @State private var loadError: String?

    init(services: AppServices, preselectedId: String? = nil) {
        self.services = services
        self.preselectedId = preselectedId
        _store = StateObject(wrappedValue: VideoAnalysisStore(
            repositories: services.repos,
            storage: services.media.storage
        ))
    }

    private var analysableClips: [VideoAnalysisStore.ClipRow] {
        store.clips.filter { $0.analysis != nil && !$0.needsRecompute }
    }

    private var gate: ClipComparison.Gate? {
        guard
            let leftMetrics,
            let rightMetrics,
            let leftId,
            let rightId,
            leftId != rightId
        else { return nil }
        return ClipComparison.compare(
            left: (label: label(for: leftId), metrics: leftMetrics),
            right: (label: label(for: rightId), metrics: rightMetrics)
        )
    }

    var body: some View {
        Screen {
            if let loadError {
                ErrorNote(loadError)
                    .accessibilityIdentifier("compare.error")
            }

            SectionTitle("Two clips")
            Card {
                picker(title: "Clip A", selection: $leftId, identifier: "compare.picker.left")
                Divider()
                    .overlay(Theme.separator)
                    .padding(.vertical, 10)
                picker(title: "Clip B", selection: $rightId, identifier: "compare.picker.right")
                if analysableClips.count < 2 {
                    Text("Comparison needs two clips that have been analysed. Analyse a clip from its review screen first.")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.top, 10)
                        .accessibilityIdentifier("compare.needs-two")
                } else if let leftId, let rightId, leftId == rightId {
                    Text("Choose two different clips.")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.top, 10)
                        .accessibilityIdentifier("compare.same-clip")
                }
            }

            if let gate {
                comparisonContent(gate)
            }
        }
        .navigationTitle("Compare")
        .accessibilityIdentifier("compare.screen")
        .onAppear {
            store.refresh()
            if leftId == nil, let preselectedId,
               analysableClips.contains(where: { $0.id == preselectedId }) {
                leftId = preselectedId
            }
            loadMetrics()
        }
        .onChange(of: leftId) { _ in
            loadMetrics()
        }
        .onChange(of: rightId) { _ in
            loadMetrics()
        }
    }

    private func picker(title: String, selection: Binding<String?>, identifier: String) -> some View {
        Picker(title, selection: selection) {
            Text("Choose a clip").tag(String?.none)
            ForEach(analysableClips) { clip in
                Text(label(for: clip)).tag(String?.some(clip.id))
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Content

    @ViewBuilder
    private func comparisonContent(_ gate: ClipComparison.Gate) -> some View {
        switch gate {
        case .refused(let reason):
            SectionTitle("Not comparable")
            Card {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(Theme.warning)
                    .accessibilityIdentifier("compare.refused")
                Text("A handheld clip has no fixed frame, so its numbers describe this camera's motion as much as the climbing.")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.top, 8)
            }
        case .allowed(let comparison):
            curveCard(comparison)
            numbersCard(comparison)
            notesCard(comparison)
        }
    }

    private func curveCard(_ comparison: ClipComparison) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Progress")
            Card {
                HStack(spacing: 16) {
                    legend(color: Theme.accent, label: comparison.left.label)
                    legend(color: Theme.info, label: comparison.right.label)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 10)
                ComparisonCurveChart(comparison: comparison)
                    .accessibilityIdentifier("compare.chart")
                Text("Height above each clip's lowest point, drawn against attempt progress. Both axes are relative, so the shapes compare even when the clips differ in length.")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.top, 8)
            }
        }
    }

    private func numbersCard(_ comparison: ClipComparison) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Numbers")
            Card {
                comparisonRow("Attempt", timeText(comparison.left.durationMs), timeText(comparison.right.durationMs))
                comparisonDivider
                comparisonRow(
                    "Highest point",
                    String(format: "%.2f", comparison.left.highestPoint),
                    String(format: "%.2f", comparison.right.highestPoint)
                )
                comparisonDivider
                comparisonRow("Falls", "\(comparison.left.fallCount)", "\(comparison.right.fallCount)")
                comparisonDivider
                comparisonRow("Dynos", "\(comparison.left.dynoCount)", "\(comparison.right.dynoCount)")
                comparisonDivider
                comparisonRow("Cut feet", "\(comparison.left.cutFeetCount)", "\(comparison.right.cutFeetCount)")
                comparisonDivider
                comparisonRow(
                    "Rest",
                    String(format: "%.1f s", comparison.left.restSeconds),
                    String(format: "%.1f s", comparison.right.restSeconds)
                )
                comparisonDivider
                comparisonRow("Peak speed", speedText(comparison.left.peakSpeed), speedText(comparison.right.peakSpeed))
                comparisonDivider
                comparisonRow("Smoothness", smoothnessText(comparison.left.smoothness), smoothnessText(comparison.right.smoothness))
                comparisonDivider
                comparisonRow(
                    "Coverage",
                    String(format: "%.0f%%", comparison.left.quality * 100),
                    String(format: "%.0f%%", comparison.right.quality * 100)
                )
                Text("Heights are in body heights and speeds in body heights per second. Neither is a measurement in metres.")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.top, 12)
            }
            .accessibilityIdentifier("compare.table")
        }
    }

    private func notesCard(_ comparison: ClipComparison) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("What this comparison can say")
            Card {
                ForEach(comparison.notes, id: \.self) { note in
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                if comparison.spatialOverlayAllowed {
                    Text("Both clips were filmed from a fixed camera, so the hesitation maps can be read against each other. They still assume the phone did not move between sessions.")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.top, 6)
                }
            }
            .accessibilityIdentifier("compare.notes")
        }
    }

    // MARK: - Loading

    private func loadMetrics() {
        loadError = nil
        leftMetrics = nil
        rightMetrics = nil
        guard let leftId, let rightId, leftId != rightId else { return }
        do {
            leftMetrics = try store.metrics(videoId: leftId)
            rightMetrics = try store.metrics(videoId: rightId)
            if leftMetrics == nil || rightMetrics == nil {
                loadError = "One of these clips has no stored pose track, so there is nothing to compare. Analyse it again."
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func label(for id: String) -> String {
        guard let clip = store.clip(id: id) else { return "Clip" }
        return label(for: clip)
    }

    private func label(for clip: VideoAnalysisStore.ClipRow) -> String {
        "\(DisplayDate.string(from: clip.video.createdAt)) clip"
    }

    private func legend(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
    }

    private func comparisonRow(_ label: String, _ left: String, _ right: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 8)
            Text(left)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.accent)
                .frame(minWidth: 56, alignment: .trailing)
            Text(right)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.info)
                .frame(minWidth: 56, alignment: .trailing)
        }
    }

    private var comparisonDivider: some View {
        Divider()
            .overlay(Theme.separator)
            .padding(.vertical, 8)
    }

    private func timeText(_ milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds) / 1000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func speedText(_ value: Double?) -> String {
        guard let value else { return "None" }
        return String(format: "%.2f", value)
    }

    private func smoothnessText(_ value: Double?) -> String {
        guard let value else { return "None" }
        return String(format: "%.2f", value)
    }
}

// MARK: - Chart

/// Two normalized progress curves on one axis. A Swift Charts line chart would need two series
/// merged into one data set with a category column; a Canvas keeps the shared axis explicit and
/// costs no dependency.
private struct ComparisonCurveChart: View {
    let comparison: ClipComparison

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                draw(in: &context, size: size)
            }
        }
        .frame(height: 160)
        .accessibilityLabel("Normalized progress curves for both clips")
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let inset: CGFloat = 6
        let width = max(1, size.width - inset * 2)
        let height = max(1, size.height - inset * 2)
        let peak = max(
            0.0001,
            (comparison.left.curve + comparison.right.curve).map(\.height).max() ?? 0
        )

        // Grid: halfway progress and halfway height.
        var grid = Path()
        grid.move(to: CGPoint(x: inset + width / 2, y: inset))
        grid.addLine(to: CGPoint(x: inset + width / 2, y: inset + height))
        grid.move(to: CGPoint(x: inset, y: inset + height / 2))
        grid.addLine(to: CGPoint(x: inset + width, y: inset + height / 2))
        context.stroke(grid, with: .color(Theme.separator.opacity(0.6)), lineWidth: 1)

        // Baseline.
        var baseline = Path()
        baseline.move(to: CGPoint(x: inset, y: inset + height))
        baseline.addLine(to: CGPoint(x: inset + width, y: inset + height))
        context.stroke(baseline, with: .color(Theme.separator), lineWidth: 1)

        drawCurve(comparison.left.curve, color: Theme.accent, in: &context, inset: inset, width: width, height: height, peak: peak)
        drawCurve(comparison.right.curve, color: Theme.info, in: &context, inset: inset, width: width, height: height, peak: peak)
    }

    private func drawCurve(
        _ points: [NormalizedProgressPoint],
        color: Color,
        in context: inout GraphicsContext,
        inset: CGFloat,
        width: CGFloat,
        height: CGFloat,
        peak: Double
    ) {
        guard points.count > 1 else { return }
        var path = Path()
        for (index, point) in points.enumerated() {
            let x = inset + width * CGFloat(min(1, max(0, point.progress)))
            let y = inset + height - height * CGFloat(min(1, point.height / peak))
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: 2, lineJoin: .round)
        )
    }
}
