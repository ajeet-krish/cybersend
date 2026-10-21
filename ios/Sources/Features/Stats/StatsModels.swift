import CyberSendDomain
import Foundation

// Stats value models (M3 Task 5, US-23). Plain Sendable structs the stats tab renders
// directly. Rates are Doubles in 0..1 and every rate guards a zero denominator, so an
// empty bucket reports 0 instead of NaN (zero-attempt grade rows stay renderable).

/// Totals across every logged attempt: counts per outcome plus the headline rates.
public struct StatsSummary: Equatable, Sendable {
    public let attempts: Int
    public let flashes: Int
    public let sends: Int
    public let projects: Int
    public let fails: Int
    /// flashes + sends: every attempt that topped out, flash included.
    public let totalSends: Int
    /// flashes / attempts; 0 when attempts is 0.
    public let flashRate: Double
    /// totalSends / attempts; 0 when attempts is 0.
    public let sendRate: Double

    public init(
        attempts: Int,
        flashes: Int,
        sends: Int,
        projects: Int,
        fails: Int,
        flashRate: Double,
        sendRate: Double
    ) {
        self.attempts = attempts
        self.flashes = flashes
        self.sends = sends
        self.projects = projects
        self.fails = fails
        self.totalSends = flashes + sends
        self.flashRate = flashRate
        self.sendRate = sendRate
    }
}

/// One row of the by grade table (US-23.1): counts and rates for one (system, level)
/// pair. Rows exist for every level of a grade system that has at least one attempt, so
/// unclimbed grades of an in-use system render with zero counts; systems without any
/// attempt produce no rows at all.
public struct GradeStatsRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let systemId: String
    public let systemName: String
    /// Nil for the ungraded bucket (attempts on climbs without a stored level).
    public let levelId: String?
    public let label: String
    /// Sort key inside the system; the ungraded bucket sorts last.
    public let rankOrder: Int
    public let attempts: Int
    public let flashes: Int
    public let sends: Int
    public let projects: Int
    public let fails: Int
    /// flashes / attempts; 0 when attempts is 0.
    public let flashRate: Double
    /// (flashes + sends) / attempts; 0 when attempts is 0.
    public let sendRate: Double

    /// Every attempt that topped out, flash included.
    public var totalSends: Int {
        flashes + sends
    }
}

/// Fall distribution buckets by hold role (US-23.3). A fall is an attempt with outcome
/// project or fail; unassigned covers skipped fall holds and holds without a role.
public enum FallRoleBucket: String, CaseIterable, Sendable {
    case start
    case intermediate
    case top
    case unassigned

    public var displayName: String {
        switch self {
        case .start: return "Start"
        case .intermediate: return "Intermediate"
        case .top: return "Top"
        case .unassigned: return "Unassigned"
        }
    }
}

public struct FallRoleStat: Equatable, Sendable, Identifiable {
    public let bucket: FallRoleBucket
    public let falls: Int

    public var id: String {
        bucket.rawValue
    }

    public init(bucket: FallRoleBucket, falls: Int) {
        self.bucket = bucket
        self.falls = falls
    }
}

/// Fall distribution by normalized position third relative to the wall photo (US-23.3).
/// y_norm is 0 at the top of the pixels-up working copy, so top means near the top of
/// the photo. Only falls whose hold belongs to a climb with a photo qualify.
public enum PhotoThird: String, CaseIterable, Sendable {
    case top
    case middle
    case bottom

    public var displayName: String {
        switch self {
        case .top: return "Top third"
        case .middle: return "Middle third"
        case .bottom: return "Bottom third"
        }
    }
}

public struct FallPositionStat: Equatable, Sendable, Identifiable {
    public let third: PhotoThird
    public let falls: Int

    public var id: String {
        third.rawValue
    }

    public init(third: PhotoThird, falls: Int) {
        self.third = third
        self.falls = falls
    }
}

/// One ISO week bucket of attempt volume (US-23.4). Buckets use the local calendar date
/// of the attempt (docs/requirements.md section 5: stats bucket by local date), and the
/// series is continuous: weeks without attempts appear with zero so the chart keeps its
/// shape.
public struct WeekVolumePoint: Equatable, Sendable, Identifiable {
    /// The local Monday that starts the ISO week.
    public let weekStart: Date
    /// ISO label such as "2026-W42".
    public let weekLabel: String
    public let attempts: Int

    public var id: String {
        weekLabel
    }

    public init(weekStart: Date, weekLabel: String, attempts: Int) {
        self.weekStart = weekStart
        self.weekLabel = weekLabel
        self.attempts = attempts
    }
}

/// One rated session in chronological order, for the RPE trend card.
public struct RpePoint: Equatable, Sendable {
    public let date: Date
    public let rpe: Int

    public init(date: Date, rpe: Int) {
        self.date = date
        self.rpe = rpe
    }
}

public enum RpeTrendDirection: String, Sendable {
    case rising
    case falling
    case flat
}

/// Session RPE summary (summary card): average over every rated session plus a coarse
/// trend that compares the back half of the series against the front half. Four rated
/// sessions are the minimum for a direction; fewer render flat.
public struct RpeSummary: Equatable, Sendable {
    public let average: Double
    public let latest: Int?
    public let trend: RpeTrendDirection
    public let points: [RpePoint]

    public init(average: Double, latest: Int?, trend: RpeTrendDirection, points: [RpePoint]) {
        self.average = average
        self.latest = latest
        self.trend = trend
        self.points = points
    }

    public static let empty = RpeSummary(average: 0, latest: nil, trend: .flat, points: [])
}

/// One heatmap mark: a hold linked to the selected climb with at least one recorded
/// fall, in normalized photo coordinates (docs/decisions.md, normalized coordinates).
public struct HeatmapMarker: Equatable, Sendable, Identifiable {
    public let holdId: String
    public let xNorm: Double
    public let yNorm: Double
    public let radiusNorm: Double
    public let role: HoldRole?
    public let fallCount: Int

    public var id: String {
        holdId
    }

    public init(holdId: String, xNorm: Double, yNorm: Double, radiusNorm: Double, role: HoldRole?, fallCount: Int) {
        self.holdId = holdId
        self.xNorm = xNorm
        self.yNorm = yNorm
        self.radiusNorm = radiusNorm
        self.role = role
        self.fallCount = fallCount
    }
}

/// The per climb fall heatmap (US-23.2): the climb's newest wall photo plus one marker
/// per linked hold that recorded at least one fall. Zero-fall holds stay off the map so
/// the overlay reads as falls, not as a hold inventory. The gym level summary is the
/// accompanying [ClimbFallSummary] the picker browses; one photo can never aggregate
/// across climbs, so the overlay itself stays per climb (documented design choice).
public struct ClimbHeatmap: Equatable, Sendable {
    public let climbId: String
    public let climbName: String?
    public let gradeLabel: String?
    public let photoId: String?
    /// Resolved working copy file URL when media storage is wired and the file exists.
    public let photoURL: URL?
    public let photoWidth: Int
    public let photoHeight: Int
    public let markers: [HeatmapMarker]

    public init(
        climbId: String,
        climbName: String?,
        gradeLabel: String?,
        photoId: String?,
        photoURL: URL?,
        photoWidth: Int,
        photoHeight: Int,
        markers: [HeatmapMarker]
    ) {
        self.climbId = climbId
        self.climbName = climbName
        self.gradeLabel = gradeLabel
        self.photoId = photoId
        self.photoURL = photoURL
        self.photoWidth = photoWidth
        self.photoHeight = photoHeight
        self.markers = markers
    }

    /// The photo aspect (width over height) for aspect fitting the overlay; 1 when the
    /// stored dimensions are degenerate.
    public var photoAspect: Double {
        guard photoHeight > 0, photoWidth > 0 else { return 1 }
        return Double(photoWidth) / Double(photoHeight)
    }

    public var displayName: String {
        guard let climbName, !climbName.isEmpty else { return "Untitled climb" }
        return climbName
    }
}

/// One row of the gym level fall summary: per climb attempt and fall totals, ordered
/// most falls first. The stats UI picker browses this list and loads the selected
/// climb's heatmap.
public struct ClimbFallSummary: Equatable, Sendable, Identifiable {
    public let climbId: String
    public let climbName: String?
    public let gradeLabel: String?
    public let attempts: Int
    /// Attempts with outcome project or fail.
    public let falls: Int

    public var id: String {
        climbId
    }

    public init(climbId: String, climbName: String?, gradeLabel: String?, attempts: Int, falls: Int) {
        self.climbId = climbId
        self.climbName = climbName
        self.gradeLabel = gradeLabel
        self.attempts = attempts
        self.falls = falls
    }

    public var displayName: String {
        guard let climbName, !climbName.isEmpty else { return "Untitled climb" }
        return climbName
    }
}
