import Combine
import CyberSendData
import CyberSendDomain
import Foundation

// Stats store (M3 Task 5, US-23): the observable aggregation behind the stats tab.
// Everything is read through repositories only (US-13); the store itself holds no SQL.
//
// Data access note: AttemptRepository has no list-all surface (only per session and per
// climb queries, which would be an N+1 scan for a dashboard), so the store reads one
// DumpRepository.dumpAll() pass (one query per table, the backup dump path) and
// aggregates in memory. At the personal scale this stays far under the 100 ms query
// budget with 10k attempts (proven by StatsStoreTests); a future dedicated
// StatsRepository with GROUP BY aggregates in SQL is the natural upgrade if the budget
// ever tightens (reported to the orchestrator rather than modifying Sources/Data here).
//
// Design choices (documented per the task scope):
//  * A fall is an attempt with outcome fail. The role distribution buckets
//    every fall: a recorded fall hold maps to its role, and skipped fall holds or holds
//    without a role land in unassigned.
//  * The position third distribution only counts falls whose hold belongs to an origin
//    climb with a photo (normalized coordinates are photo relative), splitting y_norm
//    into top (< 1/3), middle, and bottom (>= 2/3) of the photo.
//  * The heatmap is per climb (photo plus fall markers) because one photo can never
//    aggregate across climbs; the gym level summary is the per climb attempt/fall table
//    the picker browses.
//  * The by grade table carries a row for every level of every grade system that has at
//    least one attempt, so zero-attempt grades of an in-use system render with zero
//    rates instead of vanishing.

/// The parsed database slice every stats view derives from, built once per refresh.
struct StatsSnapshot {
    struct ClimbRef {
        var systemId: String
        var levelId: String?
        var name: String?
    }

    struct LevelRef {
        var id: String
        var systemId: String
        var label: String
        var rankOrder: Int
    }

    struct HoldRef {
        var xNorm: Double
        var yNorm: Double
        var radiusNorm: Double
        var role: HoldRole?
        var originClimbId: String
    }

    struct AttemptRef {
        var climbId: String
        var outcome: AttemptOutcome
        var fallOnHoldId: String?
        var date: Date
        /// The UTC day number of the stamp (days since the Unix epoch); the ISO week
        /// bucket is cached per day, so a 10k attempt month pays the week calendar once
        /// per day instead of once per attempt. A local week boundary that splits a UTC
        /// day is handled by re-checking the cached interval (StatsSnapshot.buildStats).
        var dayKey: Int

        /// Fail is the only fall outcome; flash and send top out the climb.
        var isFall: Bool {
            outcome == .fail
        }
    }

    struct PhotoRef {
        var id: String
        var uri: String
        var width: Int
        var height: Int
        var capturedAt: String
        var createdAt: String
    }

    var systems: [String: String] = [:]
    var levels: [String: LevelRef] = [:]
    var levelsBySystem: [String: [LevelRef]] = [:]
    var climbs: [String: ClimbRef] = [:]
    var holds: [String: HoldRef] = [:]
    /// climb id to linked hold ids (climb_holds membership, US-20).
    var membership: [String: [String]] = [:]
    var photosByClimb: [String: [PhotoRef]] = [:]
    var attempts: [AttemptRef] = []
    var ratedSessions: [(date: Date, rpe: Int)] = []
    /// ISO 8601 week calendar pinned to the store's time zone (local date bucketing).
    var calendar: Calendar

    /// Builds the snapshot from one table dump. Rows missing required columns are
    /// skipped defensively; the dump comes from our own database, so a skip means a
    /// hand edited row, never a broken dashboard.
    init(dump: TableDump, timeZone: TimeZone) {
        var weekCalendar = Calendar(identifier: .iso8601)
        weekCalendar.timeZone = timeZone
        calendar = weekCalendar

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        // The dashboard is the one reader that walks every attempt timestamp, and
        // ISO8601DateFormatter plus Calendar.date(from:) together cost tens of
        // microseconds per stamp (about 250 ms over 10k attempts, measured). The
        // database only ever stores ISO 8601 UTC stamps ("2026-10-06T12:00:00.000Z",
        // milliseconds optional), so the fixed offset C string parse plus day number
        // math handles the whole real corpus with zero allocations on the hot path,
        // and the formatters stay as the fallback for any other shape. The day key is
        // the UTC day number, the cache key for the local ISO week bucket.
        func parseStamp(_ text: String) -> (date: Date, dayKey: Int)? {
            let parsed = text.withCString { cString -> (Int, Int, Int, Int, Int, Int)? in
                var length = 0
                while cString[length] != 0 { length += 1 }
                // Canonical shape: "YYYY-MM-DDTHH:MM:SS", optional fraction, "Z" ended.
                guard length >= 19,
                    cString[4] == 45, cString[7] == 45, cString[10] == 84,
                    cString[13] == 58, cString[16] == 58,
                    cString[length - 1] == 90
                else { return nil }
                func digit(_ offset: Int, _ count: Int) -> Int {
                    var value = 0
                    for position in offset ..< (offset + count) {
                        let byte = cString[position]
                        guard byte >= 48, byte <= 57 else { return -1 }
                        value = value * 10 + Int(byte - 48)
                    }
                    return value
                }
                return (digit(0, 4), digit(5, 2), digit(8, 2), digit(11, 2), digit(14, 2), digit(17, 2))
            }
            if let parsed,
                parsed.0 >= 1000, parsed.1 >= 1, parsed.1 <= 12, parsed.2 >= 1, parsed.2 <= 31,
                parsed.3 >= 0, parsed.3 <= 23, parsed.4 >= 0, parsed.4 <= 59, parsed.5 >= 0, parsed.5 <= 60
            {
                let dayNumber = utcDayNumber(year: parsed.0, month: parsed.1, day: parsed.2)
                let epoch = Double(dayNumber) * 86_400
                    + Double(parsed.3 * 3_600 + parsed.4 * 60 + parsed.5)
                return (Date(timeIntervalSince1970: epoch), dayNumber)
            }
            guard let date = fractional.date(from: text) ?? plain.date(from: text) else { return nil }
            return (date, Int(floor(date.timeIntervalSince1970 / 86_400)))
        }

        for row in dump[.gradeSystems] {
            guard let id = row.text("id"), let name = row.text("name") else { continue }
            systems[id] = name
        }

        for row in dump[.gradeLevels] {
            guard
                let id = row.text("id"),
                let systemId = row.text("system_id"),
                let label = row.text("label"),
                let rankOrder = row.integer("rank_order")
            else { continue }
            let level = LevelRef(id: id, systemId: systemId, label: label, rankOrder: rankOrder)
            levels[id] = level
            levelsBySystem[systemId, default: []].append(level)
        }

        for row in dump[.climbs] {
            guard let id = row.text("id"), let systemId = row.text("grade_system_id") else { continue }
            climbs[id] = ClimbRef(systemId: systemId, levelId: row.text("grade_level_id"), name: row.text("name"))
        }

        for row in dump[.holds] {
            guard
                let id = row.text("id"),
                let climbId = row.text("climb_id"),
                let xNorm = row.real("x_norm"),
                let yNorm = row.real("y_norm"),
                let radiusNorm = row.real("radius_norm")
            else { continue }
            let roleText = row.text("role")
            holds[id] = HoldRef(
                xNorm: xNorm,
                yNorm: yNorm,
                radiusNorm: radiusNorm,
                role: roleText.flatMap(HoldRole.init(rawValue:)),
                originClimbId: climbId
            )
        }

        for row in dump[.climbHolds] {
            guard let climbId = row.text("climb_id"), let holdId = row.text("hold_id") else { continue }
            membership[climbId, default: []].append(holdId)
        }

        for row in dump[.photos] {
            guard
                let id = row.text("id"),
                let climbId = row.text("climb_id"),
                let uri = row.text("uri"),
                let width = row.integer("width"),
                let height = row.integer("height")
            else { continue }
            let photo = PhotoRef(
                id: id,
                uri: uri,
                width: width,
                height: height,
                capturedAt: row.text("captured_at") ?? "",
                createdAt: row.text("created_at") ?? ""
            )
            photosByClimb[climbId, default: []].append(photo)
        }
        // Newest photo first: capture moment wins, creation time breaks ties (two rows
        // written in the same clock tick stay deterministic).
        for (climbId, photos) in photosByClimb {
            photosByClimb[climbId] = photos.sorted {
                if $0.capturedAt != $1.capturedAt { return $0.capturedAt > $1.capturedAt }
                return $0.createdAt > $1.createdAt
            }
        }

        for row in dump[.attempts] {
            guard
                let climbId = row.text("climb_id"),
                let outcomeText = row.text("outcome"),
                let outcome = AttemptOutcome(rawValue: outcomeText),
                let attemptedAt = row.text("attempted_at"),
                let stamp = parseStamp(attemptedAt)
            else { continue }
            attempts.append(AttemptRef(
                climbId: climbId,
                outcome: outcome,
                fallOnHoldId: row.text("fall_on_hold_id"),
                date: stamp.date,
                dayKey: stamp.dayKey
            ))
        }

        for row in dump[.sessions] {
            guard
                let rpe = row.integer("rpe"),
                let startedAt = row.text("started_at"),
                let stamp = parseStamp(startedAt)
            else { continue }
            ratedSessions.append((date: stamp.date, rpe: rpe))
        }
    }

    /// Outcome counters for one bucket.
    struct OutcomeCounts {
        var attempts = 0
        var flashes = 0
        var sends = 0
        var fails = 0

        mutating func add(_ outcome: AttemptOutcome) {
            attempts += 1
            switch outcome {
            case .flash: flashes += 1
            case .send: sends += 1
            case .fail: fails += 1
            }
        }
    }

    /// The full aggregation result the store publishes.
    struct StatsData {
        var summary: StatsSummary
        var gradeRows: [GradeStatsRow]
        var roleDistribution: [FallRoleStat]
        var positionDistribution: [FallPositionStat]
        var weeklyVolume: [WeekVolumePoint]
        var rpe: RpeSummary
        var climbSummaries: [ClimbFallSummary]
    }

    /// One pass over the parsed attempts feeds every section (US-23.5: the dashboard
    /// renders well inside 300 ms with 10k attempts; the DB side is the single dump).
    func buildStats() -> StatsData {
        var totals = OutcomeCounts()
        var byGrade: [String: OutcomeCounts] = [:]
        var byClimb: [String: OutcomeCounts] = [:]
        var weekCounts: [Date: Int] = [:]
        var weekCache: [Int: DateInterval] = [:]
        var falls: [AttemptRef] = []
        var systemsInUse: Set<String> = []

        for attempt in attempts {
            // Attempts whose climb vanished (hand edited database) stay out of every
            // section instead of landing in an orphan bucket.
            guard let climb = climbs[attempt.climbId] else { continue }
            totals.add(attempt.outcome)
            systemsInUse.insert(climb.systemId)
            byGrade[gradeKey(climb.systemId, climb.levelId), default: OutcomeCounts()].add(attempt.outcome)
            byClimb[attempt.climbId, default: OutcomeCounts()].add(attempt.outcome)
            // One calendar walk per distinct UTC day (a cache hit still verifies the
            // instant is inside the cached week, so a local week boundary that splits
            // a UTC day re-buckets exactly), so dense months stay cheap.
            let weekStart: Date?
            if let cached = weekCache[attempt.dayKey], cached.contains(attempt.date) {
                weekStart = cached.start
            } else if let interval = calendar.dateInterval(of: .weekOfYear, for: attempt.date) {
                weekCache[attempt.dayKey] = interval
                weekStart = interval.start
            } else {
                weekStart = nil
            }
            if let weekStart {
                weekCounts[weekStart, default: 0] += 1
            }
            if attempt.isFall {
                falls.append(attempt)
            }
        }

        return StatsData(
            summary: summary(from: totals),
            gradeRows: gradeRows(byGrade: byGrade, systemsInUse: systemsInUse),
            roleDistribution: roleDistribution(falls: falls),
            positionDistribution: positionDistribution(falls: falls),
            weeklyVolume: weeklyVolume(weekCounts: weekCounts),
            rpe: rpeSummary(),
            climbSummaries: climbSummaries(byClimb: byClimb)
        )
    }

    /// The per climb fall heatmap: linked holds with at least one fall, plus the newest
    /// wall photo of the climb (id and resolved file URL when storage is wired).
    func heatmap(climbId: String, storage: MediaStorage?) -> ClimbHeatmap? {
        guard let climb = climbs[climbId] else { return nil }

        var fallCounts: [String: Int] = [:]
        for attempt in attempts where attempt.climbId == climbId && attempt.isFall {
            guard let holdId = attempt.fallOnHoldId else { continue }
            fallCounts[holdId, default: 0] += 1
        }

        var markers: [HeatmapMarker] = []
        for holdId in membership[climbId] ?? [] {
            guard let hold = holds[holdId], let fallCount = fallCounts[holdId], fallCount > 0 else { continue }
            markers.append(HeatmapMarker(
                holdId: holdId,
                xNorm: hold.xNorm,
                yNorm: hold.yNorm,
                radiusNorm: hold.radiusNorm,
                role: hold.role,
                fallCount: fallCount
            ))
        }
        markers.sort {
            if $0.fallCount != $1.fallCount { return $0.fallCount > $1.fallCount }
            return $0.holdId < $1.holdId
        }

        let photo = photosByClimb[climbId]?.first
        var photoURL: URL?
        if let photo, let storage, storage.fileExists(relativeURI: photo.uri) {
            photoURL = try? storage.url(relativeURI: photo.uri)
        }

        return ClimbHeatmap(
            climbId: climbId,
            climbName: climb.name,
            gradeLabel: gradeLabel(systemId: climb.systemId, levelId: climb.levelId),
            photoId: photo?.id,
            photoURL: photoURL,
            photoWidth: photo?.width ?? 0,
            photoHeight: photo?.height ?? 0,
            markers: markers
        )
    }

    // MARK: - Section builders

    private func summary(from totals: OutcomeCounts) -> StatsSummary {
        StatsSummary(
            attempts: totals.attempts,
            flashes: totals.flashes,
            sends: totals.sends,
            fails: totals.fails,
            flashRate: rate(totals.flashes, totals.attempts),
            sendRate: rate(totals.flashes + totals.sends, totals.attempts)
        )
    }

    /// One row per level of every in-use grade system, ordered by system name then rank,
    /// with the ungraded bucket last inside its system. Zero-attempt levels keep their
    /// row with zero rates (no NaN, ever).
    private func gradeRows(byGrade: [String: OutcomeCounts], systemsInUse: Set<String>) -> [GradeStatsRow] {
        var rows: [GradeStatsRow] = []
        let usedSystemIds = systemsInUse.sorted {
            (systems[$0] ?? $0).localizedCaseInsensitiveCompare(systems[$1] ?? $1) == .orderedAscending
        }
        for systemId in usedSystemIds {
            let systemName = systems[systemId] ?? systemId
            let systemLevels = (levelsBySystem[systemId] ?? []).sorted { $0.rankOrder < $1.rankOrder }
            for level in systemLevels {
                let counts = byGrade[gradeKey(systemId, level.id)] ?? OutcomeCounts()
                rows.append(gradeRow(
                    systemId: systemId,
                    systemName: systemName,
                    levelId: level.id,
                    label: level.label,
                    rankOrder: level.rankOrder,
                    counts: counts
                ))
            }
            if let counts = byGrade[gradeKey(systemId, nil)] {
                rows.append(gradeRow(
                    systemId: systemId,
                    systemName: systemName,
                    levelId: nil,
                    label: "Ungraded",
                    rankOrder: Int.max,
                    counts: counts
                ))
            }
        }
        return rows
    }

    private func gradeRow(
        systemId: String,
        systemName: String,
        levelId: String?,
        label: String,
        rankOrder: Int,
        counts: OutcomeCounts
    ) -> GradeStatsRow {
        GradeStatsRow(
            id: gradeKey(systemId, levelId),
            systemId: systemId,
            systemName: systemName,
            levelId: levelId,
            label: label,
            rankOrder: rankOrder,
            attempts: counts.attempts,
            flashes: counts.flashes,
            sends: counts.sends,
            fails: counts.fails,
            flashRate: rate(counts.flashes, counts.attempts),
            sendRate: rate(counts.flashes + counts.sends, counts.attempts)
        )
    }

    private func roleDistribution(falls: [AttemptRef]) -> [FallRoleStat] {
        var counts: [FallRoleBucket: Int] = [:]
        for fall in falls {
            var bucket: FallRoleBucket = .unassigned
            if let holdId = fall.fallOnHoldId, let role = holds[holdId]?.role {
                bucket = FallRoleBucket(role: role)
            }
            counts[bucket, default: 0] += 1
        }
        return FallRoleBucket.allCases.map { FallRoleStat(bucket: $0, falls: counts[$0] ?? 0) }
    }

    private func positionDistribution(falls: [AttemptRef]) -> [FallPositionStat] {
        var counts: [PhotoThird: Int] = [:]
        for fall in falls {
            guard let holdId = fall.fallOnHoldId, let hold = holds[holdId] else { continue }
            // Normalized coordinates are photo relative (docs/decisions.md), so a hold
            // whose origin climb never got a photo has no meaningful position third.
            guard let photos = photosByClimb[hold.originClimbId], !photos.isEmpty else { continue }
            counts[third(yNorm: hold.yNorm), default: 0] += 1
        }
        return PhotoThird.allCases.map { FallPositionStat(third: $0, falls: counts[$0] ?? 0) }
    }

    private func weeklyVolume(weekCounts: [Date: Int]) -> [WeekVolumePoint] {
        guard let firstWeek = weekCounts.keys.min(), let lastWeek = weekCounts.keys.max() else {
            return []
        }
        var points: [WeekVolumePoint] = []
        var weekStart = firstWeek
        while weekStart <= lastWeek {
            let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: weekStart)
            let label = String(
                format: "%d-W%02d",
                components.yearForWeekOfYear ?? 0,
                components.weekOfYear ?? 0
            )
            points.append(WeekVolumePoint(
                weekStart: weekStart,
                weekLabel: label,
                attempts: weekCounts[weekStart] ?? 0
            ))
            guard let nextWeek = calendar.date(byAdding: .day, value: 7, to: weekStart) else { break }
            weekStart = nextWeek
        }
        return points
    }

    private func rpeSummary() -> RpeSummary {
        let ordered = ratedSessions.sorted { $0.date < $1.date }
        guard !ordered.isEmpty else { return .empty }
        let points = ordered.map { RpePoint(date: $0.date, rpe: $0.rpe) }
        let values = points.map { Double($0.rpe) }
        let average = values.reduce(0, +) / Double(values.count)

        // Trend: back half mean minus front half mean; four rated sessions are the
        // minimum for a direction, and a half-point delta is the flat dead band.
        var trend: RpeTrendDirection = .flat
        if points.count >= 4 {
            let half = points.count / 2
            let front = values.prefix(half)
            let back = values.suffix(half)
            let frontMean = front.reduce(0, +) / Double(front.count)
            let backMean = back.reduce(0, +) / Double(back.count)
            let delta = backMean - frontMean
            if delta >= 0.5 {
                trend = .rising
            } else if delta <= -0.5 {
                trend = .falling
            }
        }
        return RpeSummary(average: average, latest: points.last?.rpe, trend: trend, points: points)
    }

    private func climbSummaries(byClimb: [String: OutcomeCounts]) -> [ClimbFallSummary] {
        var rows: [ClimbFallSummary] = []
        for (climbId, counts) in byClimb {
            guard let climb = climbs[climbId] else { continue }
            rows.append(ClimbFallSummary(
                climbId: climbId,
                climbName: climb.name,
                gradeLabel: gradeLabel(systemId: climb.systemId, levelId: climb.levelId),
                attempts: counts.attempts,
                falls: counts.fails
            ))
        }
        rows.sort {
            if $0.falls != $1.falls { return $0.falls > $1.falls }
            if $0.attempts != $1.attempts { return $0.attempts > $1.attempts }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        return rows
    }

    // MARK: - Shared helpers

    private func gradeKey(_ systemId: String, _ levelId: String?) -> String {
        "\(systemId)|\(levelId ?? "")"
    }

    private func gradeLabel(systemId: String, levelId: String?) -> String? {
        guard let levelId else { return nil }
        return levels[levelId]?.label
    }

    private func rate(_ numerator: Int, _ denominator: Int) -> Double {
        guard denominator > 0 else { return 0 }
        return Double(numerator) / Double(denominator)
    }

    private func third(yNorm: Double) -> PhotoThird {
        if yNorm < 1.0 / 3.0 { return .top }
        if yNorm < 2.0 / 3.0 { return .middle }
        return .bottom
    }
}

private extension FallRoleBucket {
    init(role: HoldRole) {
        switch role {
        case .start: self = .start
        case .intermediate: self = .intermediate
        case .top: self = .top
        }
    }
}

/// The number of days since the Unix epoch for a proleptic Gregorian UTC date, via the
/// days from civil date algorithm (integer math, no calendar objects). Only valid for
/// the four digit years the database stores.
private func utcDayNumber(year: Int, month: Int, day: Int) -> Int {
    let shiftedYear = month <= 2 ? year - 1 : year
    let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
    let yearOfEra = shiftedYear - era * 400
    let shiftedMonth = month + (month > 2 ? -3 : 9)
    let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
}

private extension ExportRow {
    func text(_ column: String) -> String? {
        self[column]?.textValue
    }

    func integer(_ column: String) -> Int? {
        self[column]?.integerValue.map(Int.init)
    }

    func real(_ column: String) -> Double? {
        self[column]?.realValue
    }
}

/// Observable stats dashboard store (docs/decisions.md, 2026-10-20 M2 store pattern):
/// main actor, repositories only, refresh on appear. Selecting a climb rebuilds the
/// heatmap from the cached snapshot, so picker changes never touch the database.
@MainActor
public final class StatsStore: ObservableObject {
    @Published public private(set) var summary = StatsSummary(
        attempts: 0, flashes: 0, sends: 0, fails: 0, flashRate: 0, sendRate: 0
    )
    @Published public private(set) var gradeRows: [GradeStatsRow] = []
    @Published public private(set) var roleDistribution: [FallRoleStat] = []
    @Published public private(set) var positionDistribution: [FallPositionStat] = []
    @Published public private(set) var weeklyVolume: [WeekVolumePoint] = []
    @Published public private(set) var rpe: RpeSummary = .empty
    /// The gym level fall summary (most falls first); the picker browses this list.
    @Published public private(set) var climbSummaries: [ClimbFallSummary] = []
    @Published public private(set) var selectedClimbId: String?
    @Published public private(set) var heatmap: ClimbHeatmap?
    @Published public private(set) var lastErrorMessage: String?

    private let repos: Repositories
    private let storage: MediaStorage?
    private let timeZone: TimeZone
    private var snapshot: StatsSnapshot?

    /// storage is optional so package tests run against an in-memory database with no
    /// media files; the app wires the real MediaStorage, which resolves photo URLs.
    public init(repos: Repositories, storage: MediaStorage? = nil, timeZone: TimeZone = .current) {
        self.repos = repos
        self.storage = storage
        self.timeZone = timeZone
        refresh()
    }

    /// Reloads every section in one dump pass. Failures surface through
    /// lastErrorMessage and leave the previous values untouched.
    public func refresh() {
        do {
            let dump = try repos.dump.dumpAll()
            let snapshot = StatsSnapshot(dump: dump, timeZone: timeZone)
            let stats = snapshot.buildStats()
            self.snapshot = snapshot
            summary = stats.summary
            gradeRows = stats.gradeRows
            roleDistribution = stats.roleDistribution
            positionDistribution = stats.positionDistribution
            weeklyVolume = stats.weeklyVolume
            rpe = stats.rpe
            climbSummaries = stats.climbSummaries
            if let selectedClimbId, stats.climbSummaries.contains(where: { $0.climbId == selectedClimbId }) {
                // Keep the current selection across refreshes.
            } else {
                selectedClimbId = stats.climbSummaries.first?.climbId
            }
            rebuildHeatmap()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Switches the heatmap to another climb (rebuilds from the cached snapshot).
    public func selectClimb(id: String?) {
        selectedClimbId = id
        rebuildHeatmap()
    }

    private func rebuildHeatmap() {
        guard let snapshot, let selectedClimbId else {
            heatmap = nil
            return
        }
        heatmap = snapshot.heatmap(climbId: selectedClimbId, storage: storage)
    }
}
