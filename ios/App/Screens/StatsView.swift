import Charts
import CyberSendDomain
import CyberSendFeatures
import SwiftUI

// Stats dashboard (M3 Task 5, US-23): summary cards, flash/send rates by grade, attempt
// volume per ISO week, fall distribution by hold role and photo position third, and the
// fall heatmap on the climb's wall photo (marks sized and colored by fall count). The
// view observes StatsStore only (stores, never repositories, US-13) and refreshes on
// appear; the store's aggregation is a single dump query well inside the 300 ms render
// budget with 10k attempts (docs/requirements.md section 6, proven by StatsStoreTests).
// Swift Charts is a system framework (iOS 16+), no third party chart dependency.

struct StatsView: View {
    @EnvironmentObject private var store: StatsStore
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.appServices) private var services

    var body: some View {
        Screen {
            if let message = store.lastErrorMessage {
                ErrorNote(message)
                    .accessibilityIdentifier("stats.error")
            }

            if store.summary.attempts == 0 {
                EmptyState(
                    systemImage: "chart.bar.xaxis",
                    title: "No attempts yet",
                    message: "Log attempts to see rates by grade, volume over time, and your fall heatmap."
                )
                .accessibilityIdentifier("stats.empty")
            } else {
                summarySection
                byGradeSection
                volumeSection
                fallDistributionSection
                heatmapSection
            }

            clipsSection
        }
        .accessibilityIdentifier("stats.screen")
        .onAppear {
            store.refresh()
        }
    }

    // MARK: - Summary cards

    /// Entry point to the clips surface (P5). Behind the pose flag and reached from Stats rather
    /// than a sixth tab, because five tabs is the bar before iOS collapses the rest into More.
    @ViewBuilder
    private var clipsSection: some View {
        if settings.flags[.aiPoseAnalysis], let services {
            SectionTitle("Clips")
            Card {
                NavigationLink {
                    VideosView(services: services)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "video.fill")
                            .font(.subheadline)
                            .foregroundStyle(Theme.accent)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Clips and analysis")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.primaryText)
                            Text("Attempt window, falls, smoothness, pose overlay")
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("stats.clips.link")
            }
        }
    }

    private var summarySection: some View {
        Group {
            SectionTitle("Summary")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                summaryCard(
                    title: "Attempts",
                    value: "\(store.summary.attempts)",
                    identifier: "stats.summary.attempts"
                )
                summaryCard(
                    title: "Sends",
                    value: "\(store.summary.totalSends)",
                    identifier: "stats.summary.sends"
                )
                summaryCard(
                    title: "Flash rate",
                    value: percent(store.summary.flashRate),
                    identifier: "stats.summary.flashrate"
                )
                summaryCard(
                    title: "RPE trend",
                    value: rpeTrendValue,
                    identifier: "stats.summary.rpe"
                )
            }
        }
    }

    private var rpeTrendValue: String {
        guard store.rpe.latest != nil || store.rpe.points.isEmpty == false else { return "Not set" }
        let average = String(format: "%.1f", store.rpe.average)
        let arrow: String
        switch store.rpe.trend {
        case .rising: arrow = "Rising"
        case .falling: arrow = "Falling"
        case .flat: arrow = "Steady"
        }
        return "\(average) \(arrow)"
    }

    private func summaryCard(title: String, value: String, identifier: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                Text(value)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel("\(title): \(value)")
    }

    // MARK: - By grade (US-23.1)

    /// Rows with attempts only: zero-attempt grades of an in-use system exist in the
    /// store data (their rates are guarded, never NaN) but stay off the dashboard so
    /// the table only shows grades the climber has actually touched.
    private var gradedRows: [GradeStatsRow] {
        store.gradeRows.filter { $0.attempts > 0 }
    }

    @ViewBuilder
    private var byGradeSection: some View {
        Group {
            SectionTitle("By grade")
            Card {
                if gradedRows.isEmpty {
                    EmptyState(
                        systemImage: "chart.bar",
                        title: "No graded attempts",
                        message: "Attempts on climbs without attempts will show up here."
                    )
                } else {
                    Chart(gradedRows) { row in
                        BarMark(
                            x: .value("Grade", row.label),
                            y: .value("Send rate", row.sendRate)
                        )
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel("\(row.label) send rate \(percent(row.sendRate))")

                        BarMark(
                            x: .value("Grade", row.label),
                            y: .value("Flash rate", row.flashRate)
                        )
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityLabel("\(row.label) flash rate \(percent(row.flashRate))")
                    }
                    .chartForegroundStyleScale(
                        ["Send rate": Theme.accent, "Flash rate": Theme.secondaryText]
                    )
                    .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
                    .frame(height: 180)
                    .accessibilityIdentifier("stats.grade.chart")

                    Divider()
                        .padding(.vertical, 8)

                    ForEach(gradedRows) { row in
                        gradeRow(row)
                        if row.id != gradedRows.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func gradeRow(_ row: GradeStatsRow) -> some View {
        HStack(spacing: 8) {
            Text(row.label)
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.primaryText)
                .frame(minWidth: 44, alignment: .leading)
            Spacer(minLength: 8)
            statColumn("Attempts", "\(row.attempts)")
            statColumn("Sends", "\(row.totalSends)")
            statColumn("Flash", percent(row.flashRate))
            statColumn("Send", percent(row.sendRate))
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("stats.grade.row.\(row.id)")
        .accessibilityLabel(
            "\(row.label): \(row.attempts) attempts, \(row.totalSends) sends, "
                + "flash rate \(percent(row.flashRate)), send rate \(percent(row.sendRate))"
        )
    }

    private func statColumn(_ title: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(minWidth: 48)
    }

    // MARK: - Volume over time (US-23.4)

    @ViewBuilder
    private var volumeSection: some View {
        Group {
            SectionTitle("Volume by week")
            Card {
                if store.weeklyVolume.isEmpty {
                    EmptyState(
                        systemImage: "waveform.path.ecg",
                        title: "No weekly volume",
                        message: "Attempts bucket by ISO week of the local date."
                    )
                } else {
                    Chart(store.weeklyVolume) { point in
                        BarMark(
                            x: .value("Week", point.weekStart),
                            y: .value("Attempts", point.attempts)
                        )
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel("Week of \(point.weekLabel): \(point.attempts) attempts")
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        }
                    }
                    .frame(height: 160)
                    .accessibilityIdentifier("stats.volume.chart")
                }
            }
        }
    }

    // MARK: - Fall distribution (US-23.3)

    @ViewBuilder
    private var fallDistributionSection: some View {
        Group {
            SectionTitle("Where you fall")
            Card {
                distributionChart(
                    title: "By hold role",
                    rows: store.roleDistribution.map { (bucket: $0.bucket.displayName, falls: $0.falls) },
                    identifier: "stats.role.chart"
                )
                Divider()
                    .padding(.vertical, 10)
                distributionChart(
                    title: "By photo position",
                    rows: store.positionDistribution.map { (bucket: $0.third.displayName, falls: $0.falls) },
                    identifier: "stats.position.chart"
                )
            }
        }
    }

    private func distributionChart(title: String, rows: [(bucket: String, falls: Int)], identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.primaryText)
            if rows.allSatisfy({ $0.falls == 0 }) {
                Text("No falls with a recorded hold yet.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            } else {
                Chart(rows, id: \.bucket) { row in
                    BarMark(
                        x: .value("Falls", row.falls),
                        y: .value("Bucket", row.bucket)
                    )
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel("\(row.bucket): \(row.falls) falls")
                }
                .frame(height: max(60, CGFloat(rows.count) * 34))
                .accessibilityIdentifier(identifier)
            }
        }
    }

    // MARK: - Fall heatmap (US-23.2)

    @ViewBuilder
    private var heatmapSection: some View {
        Group {
            SectionTitle("Fall heatmap")
            Card {
                if store.climbSummaries.isEmpty {
                    EmptyState(
                        systemImage: "flame",
                        title: "No falls to map",
                        message: "Log fails with a fall hold on a tagged climb to build its heatmap."
                    )
                    .accessibilityIdentifier("stats.heatmap.empty")
                } else {
                    climbPicker
                    heatmapContent
                }
            }
        }
    }

    @ViewBuilder
    private var climbPicker: some View {
        if store.climbSummaries.count > 1 {
            Picker("Climb", selection: Binding(
                get: { store.selectedClimbId ?? "" },
                set: { store.selectClimb(id: $0) }
            )) {
                ForEach(store.climbSummaries) { summary in
                    Text(pickerLabel(summary)).tag(summary.climbId)
                }
            }
            .accessibilityIdentifier("stats.heatmap.picker")
        }
    }

    private func pickerLabel(_ summary: ClimbFallSummary) -> String {
        if let grade = summary.gradeLabel {
            return "\(summary.displayName) (\(grade))"
        }
        return summary.displayName
    }

    @ViewBuilder
    private var heatmapContent: some View {
        if let heatmap = store.heatmap {
            VStack(alignment: .leading, spacing: 8) {
                if heatmap.photoURL == nil {
                    EmptyState(
                        systemImage: "photo",
                        title: "No wall photo",
                        message: "Tag a wall photo on this climb to see fall markers on it."
                    )
                    .accessibilityIdentifier("stats.heatmap.nophoto")
                } else {
                    heatmapOverlay(heatmap)
                    if heatmap.markers.isEmpty {
                        Text("No falls recorded on this climb yet.")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                            .accessibilityIdentifier("stats.heatmap.nomarkers")
                    } else {
                        Text("Larger, brighter marks mean more falls on that hold.")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        } else {
            EmptyState(
                systemImage: "flame",
                title: "No heatmap",
                message: "Select a climb with logged falls."
            )
            .accessibilityIdentifier("stats.heatmap.empty")
        }
    }

    /// The wall photo in a photo aspect fitted frame with the fall markers positioned
    /// over it. The frame carries the photo aspect, so normalized coordinates map
    /// straight onto the frame with no letterbox drift, matching the normalized
    /// contract every hold stores (docs/decisions.md, normalized coordinates).
    private func heatmapOverlay(_ heatmap: ClimbHeatmap) -> some View {
        ZStack {
            AsyncImage(url: heatmap.photoURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                ZStack {
                    Theme.cardBackground
                    ProgressView()
                }
            }

            GeometryReader { geometry in
                ForEach(heatmap.markers) { marker in
                    markerCircle(marker, canvasSize: geometry.size)
                }
            }
        }
        // The identifier rides the overlay container (a plain SwiftUI ZStack), because
        // AsyncImage does not surface accessibility modifiers from its phase content;
        // the container stays queryable while the local file decodes (XCUITest smoke).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stats.heatmap.photo")
        .accessibilityLabel("Wall photo of \(heatmap.displayName)")
        .aspectRatio(heatmap.photoAspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
    }

    private func markerCircle(_ marker: HeatmapMarker, canvasSize: CGSize) -> some View {
        let intensity = min(1.0, 0.35 + 0.18 * Double(marker.fallCount))
        let diameter = min(64, max(18, 14 + 7 * Double(marker.fallCount)))
        return Circle()
            .fill(Color.red.opacity(intensity))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 1))
            .frame(width: diameter, height: diameter)
            .position(x: marker.xNorm * canvasSize.width, y: marker.yNorm * canvasSize.height)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("stats.heatmap.marker.\(marker.holdId)")
            .accessibilityLabel("\(marker.fallCount) falls on the \(marker.role?.rawValue ?? "unassigned") hold")
    }

    // MARK: - Formatting

    private func percent(_ rate: Double) -> String {
        String(format: "%.0f%%", rate * 100)
    }
}
