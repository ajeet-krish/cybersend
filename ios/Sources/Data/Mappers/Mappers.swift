import CyberSendDomain
import Foundation
import GRDB

// Row to domain and domain to row mappers (port of src/data/mappers). Row keys are snake_case
// column names exactly as SQLite returned them; domain fields are camelCase. Repositories are
// the only SQL surface; these helpers only translate rows.

public enum DataError: Error, Equatable, CustomStringConvertible {
    case unknownAttemptOutcome(String)
    case unknownHoldSource(String)
    case unknownHoldRole(String)
    case unknownPhotoSource(String)
    case unknownPoseStatus(String)
    case unknownRetentionClass(String)

    public var description: String {
        switch self {
        case .unknownAttemptOutcome(let raw): return "Unknown attempt outcome in database: \(raw)"
        case .unknownHoldSource(let raw): return "Unknown hold source in database: \(raw)"
        case .unknownHoldRole(let raw): return "Unknown hold role in database: \(raw)"
        case .unknownPhotoSource(let raw): return "Unknown photo source in database: \(raw)"
        case .unknownPoseStatus(let raw): return "Unknown pose status in database: \(raw)"
        case .unknownRetentionClass(let raw): return "Unknown retention class in database: \(raw)"
        }
    }
}

extension DataError: LocalizedError {
    public var errorDescription: String? { description }
}

// MARK: - Row to domain

func rowToGym(_ row: Row) -> Gym {
    Gym(
        id: row["id"],
        name: row["name"],
        timezone: row["timezone"],
        isArchived: row["is_archived"],
        createdAt: row["created_at"],
        updatedAt: row["updated_at"]
    )
}

func rowToWall(_ row: Row) -> Wall {
    Wall(
        id: row["id"],
        gymId: row["gym_id"],
        name: row["name"],
        angleDeg: row["angle_deg"],
        angleLabel: row["angle_label"],
        isActive: row["is_active"],
        createdAt: row["created_at"],
        updatedAt: row["updated_at"]
    )
}

func rowToGradeSystem(_ row: Row) -> GradeSystem {
    GradeSystem(
        id: row["id"],
        name: row["name"],
        isBuiltin: row["is_builtin"],
        levels: []
    )
}

func rowToGradeLevel(_ row: Row) -> GradeLevel {
    GradeLevel(
        id: row["id"],
        label: row["label"],
        rankOrder: row["rank_order"],
        colorHex: row["color_hex"]
    )
}

func rowToClimb(_ row: Row) -> Climb {
    Climb(
        id: row["id"],
        gymId: row["gym_id"],
        wallId: row["wall_id"],
        boardId: row["board_id"],
        boardProblemId: row["board_problem_id"],
        name: row["name"],
        gradeSystemId: row["grade_system_id"],
        gradeLevelId: row["grade_level_id"],
        gradeNorm: row["grade_norm"],
        colorCircuit: row["color_circuit"],
        angleDeg: row["angle_deg"],
        isActive: row["is_active"],
        isArchived: row["is_archived"],
        createdAt: row["created_at"],
        updatedAt: row["updated_at"]
    )
}

func rowToSession(_ row: Row) -> Session {
    Session(
        id: row["id"],
        gymId: row["gym_id"],
        startedAt: row["started_at"],
        endedAt: row["ended_at"],
        rpe: row["rpe"],
        notes: row["notes"],
        createdAt: row["created_at"],
        updatedAt: row["updated_at"]
    )
}

/// The history query aliases the attempt count as attempt_count.
func rowToSessionSummary(_ row: Row) throws -> SessionSummary {
    let attemptCount: Int64 = row["attempt_count"]
    return SessionSummary(session: rowToSession(row), attemptCount: Int(attemptCount))
}

func rowToAttempt(_ row: Row) throws -> Attempt {
    let outcomeRaw: String = row["outcome"]
    guard let outcome = AttemptOutcome(rawValue: outcomeRaw) else {
        throw DataError.unknownAttemptOutcome(outcomeRaw)
    }
    return Attempt(
        id: row["id"],
        sessionId: row["session_id"],
        climbId: row["climb_id"],
        attemptNo: row["attempt_no"],
        outcome: outcome,
        fallOnHoldId: row["fall_on_hold_id"],
        videoId: row["video_id"],
        notes: row["notes"],
        attemptedAt: row["attempted_at"]
    )
}

func rowToHold(_ row: Row) throws -> Hold {
    let sourceRaw: String = row["source"]
    guard let source = HoldSource(rawValue: sourceRaw) else {
        throw DataError.unknownHoldSource(sourceRaw)
    }
    let roleRaw: String? = row["role"]
    let role = try roleRaw.map { raw in
        guard let parsed = HoldRole(rawValue: raw) else {
            throw DataError.unknownHoldRole(raw)
        }
        return parsed
    }
    return Hold(
        id: row["id"],
        climbId: row["climb_id"],
        xNorm: row["x_norm"],
        yNorm: row["y_norm"],
        radiusNorm: row["radius_norm"],
        role: role,
        colorFamily: row["color_family"],
        source: source,
        ordinal: row["ordinal"],
        createdAt: row["created_at"],
        updatedAt: row["updated_at"]
    )
}

func rowToClimbHold(_ row: Row) -> ClimbHold {
    ClimbHold(
        climbId: row["climb_id"],
        holdId: row["hold_id"],
        sequence: row["sequence"],
        createdAt: row["created_at"]
    )
}

func rowToPhoto(_ row: Row) throws -> Photo {
    let sourceRaw: String = row["source"]
    guard let source = PhotoSource(rawValue: sourceRaw) else {
        throw DataError.unknownPhotoSource(sourceRaw)
    }
    return Photo(
        id: row["id"],
        climbId: row["climb_id"],
        sessionId: row["session_id"],
        uri: row["uri"],
        thumbUri: row["thumb_uri"],
        originalUri: row["original_uri"],
        width: row["width"],
        height: row["height"],
        source: source,
        capturedAt: row["captured_at"],
        createdAt: row["created_at"]
    )
}

func rowToVideo(_ row: Row) throws -> Video {
    let poseStatusRaw: String = row["pose_status"]
    guard let poseStatus = PoseStatus(rawValue: poseStatusRaw) else {
        throw DataError.unknownPoseStatus(poseStatusRaw)
    }
    let retentionRaw: String = row["retention_class"]
    guard let retentionClass = RetentionClass(rawValue: retentionRaw) else {
        throw DataError.unknownRetentionClass(retentionRaw)
    }
    return Video(
        id: row["id"],
        sessionId: row["session_id"],
        climbId: row["climb_id"],
        uri: row["uri"],
        width: row["width"],
        height: row["height"],
        durationMs: row["duration_ms"],
        fps: row["fps"],
        poseStatus: poseStatus,
        retentionClass: retentionClass,
        createdAt: row["created_at"]
    )
}

func rowToPoseKeypoint(_ row: Row) -> PoseKeypoint {
    PoseKeypoint(
        id: row["id"],
        videoId: row["video_id"],
        tMs: row["t_ms"],
        score: row["score"],
        keypointsJson: row["keypoints_json"]
    )
}
