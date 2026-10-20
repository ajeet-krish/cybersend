import CyberSendData
import CyberSendDomain
import Foundation

// Feature flags (port of src/app/flags.ts): compile time defaults per build variant
// plus runtime overrides stored in the settings table (docs/decisions.md: feature flags
// via build variant plus settings overrides). Foundation only; the hidden dev screen
// that flips flags is M2 UI.

public enum BuildVariant: String, CaseIterable, Sendable {
    case development
    case internalBuild = "internal"
    case release
}

public enum FeatureFlag: String, CaseIterable, Codable, Sendable {
    case videoCapture = "video_capture"
    case gradeNormalization = "grade_normalization"
    case aiHoldDetection = "ai_hold_detection"
    case aiPoseAnalysis = "ai_pose_analysis"
    case boulderVision = "boulder_vision"
    case boardImport = "board_import"
}

/// The six flag values (the TypeScript FlagValues record). Codable with the snake_case
/// keys of the TypeScript spec so settings JSON stays interchangeable.
public struct FlagValues: Equatable, Sendable {
    public var videoCapture: Bool
    public var gradeNormalization: Bool
    public var aiHoldDetection: Bool
    public var aiPoseAnalysis: Bool
    public var boulderVision: Bool
    public var boardImport: Bool

    public init(
        videoCapture: Bool,
        gradeNormalization: Bool,
        aiHoldDetection: Bool,
        aiPoseAnalysis: Bool,
        boulderVision: Bool,
        boardImport: Bool
    ) {
        self.videoCapture = videoCapture
        self.gradeNormalization = gradeNormalization
        self.aiHoldDetection = aiHoldDetection
        self.aiPoseAnalysis = aiPoseAnalysis
        self.boulderVision = boulderVision
        self.boardImport = boardImport
    }

    public subscript(flag: FeatureFlag) -> Bool {
        get {
            switch flag {
            case .videoCapture: return videoCapture
            case .gradeNormalization: return gradeNormalization
            case .aiHoldDetection: return aiHoldDetection
            case .aiPoseAnalysis: return aiPoseAnalysis
            case .boulderVision: return boulderVision
            case .boardImport: return boardImport
            }
        }
        set {
            switch flag {
            case .videoCapture: videoCapture = newValue
            case .gradeNormalization: gradeNormalization = newValue
            case .aiHoldDetection: aiHoldDetection = newValue
            case .aiPoseAnalysis: aiPoseAnalysis = newValue
            case .boulderVision: boulderVision = newValue
            case .boardImport: boardImport = newValue
            }
        }
    }
}

extension FlagValues: Codable {
    private enum CodingKeys: String, CodingKey {
        case videoCapture = "video_capture"
        case gradeNormalization = "grade_normalization"
        case aiHoldDetection = "ai_hold_detection"
        case aiPoseAnalysis = "ai_pose_analysis"
        case boulderVision = "boulder_vision"
        case boardImport = "board_import"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        videoCapture = try container.decodeIfPresent(Bool.self, forKey: .videoCapture) ?? false
        gradeNormalization = try container.decodeIfPresent(Bool.self, forKey: .gradeNormalization) ?? false
        aiHoldDetection = try container.decodeIfPresent(Bool.self, forKey: .aiHoldDetection) ?? false
        aiPoseAnalysis = try container.decodeIfPresent(Bool.self, forKey: .aiPoseAnalysis) ?? false
        boulderVision = try container.decodeIfPresent(Bool.self, forKey: .boulderVision) ?? false
        boardImport = try container.decodeIfPresent(Bool.self, forKey: .boardImport) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(videoCapture, forKey: .videoCapture)
        try container.encode(gradeNormalization, forKey: .gradeNormalization)
        try container.encode(aiHoldDetection, forKey: .aiHoldDetection)
        try container.encode(aiPoseAnalysis, forKey: .aiPoseAnalysis)
        try container.encode(boulderVision, forKey: .boulderVision)
        try container.encode(boardImport, forKey: .boardImport)
    }
}

private let developmentFlags = FlagValues(
    videoCapture: true,
    gradeNormalization: true,
    aiHoldDetection: false,
    aiPoseAnalysis: false,
    boulderVision: true,
    boardImport: false
)

private let internalFlags = FlagValues(
    videoCapture: true,
    gradeNormalization: true,
    aiHoldDetection: false,
    aiPoseAnalysis: false,
    boulderVision: true,
    boardImport: false
)

private let releaseFlags = FlagValues(
    videoCapture: false,
    gradeNormalization: false,
    aiHoldDetection: false,
    aiPoseAnalysis: false,
    boulderVision: false,
    boardImport: false
)

/// Compile time defaults per build variant (port of defaultFlags). AI flags ship off
/// in every variant and toggle on from the hidden dev screen; board_import stays
/// dormant with the board seam (docs/decisions.md).
public func defaultFlags(for variant: BuildVariant) -> FlagValues {
    switch variant {
    case .development:
        return developmentFlags
    case .internalBuild:
        return internalFlags
    case .release:
        return releaseFlags
    }
}

/// Applies settings overrides over defaults (port of mergeFlags).
public func mergeFlags(_ defaults: FlagValues, overrides: [FeatureFlag: Bool]) -> FlagValues {
    var merged = defaults
    for (flag, value) in overrides {
        merged[flag] = value
    }
    return merged
}

/// Tolerant override parsing for the settings table JSON ({"ai_hold_detection": true}).
/// Unknown keys are ignored; malformed or absent JSON leaves the defaults untouched,
/// matching the TypeScript getJson null fallback.
public func mergeFlags(_ defaults: FlagValues, overridesJSON: String?) -> FlagValues {
    guard let overridesJSON,
          let data = overridesJSON.data(using: .utf8),
          let raw = try? JSONDecoder().decode([String: Bool].self, from: data)
    else {
        return defaults
    }
    let overrides = compactMapKeys(raw) { FeatureFlag(rawValue: $0) }
    return mergeFlags(defaults, overrides: overrides)
}

/// Reads the build variant (port of readBuildVariant); unknown or missing values fall
/// back to development.
public func readBuildVariant(rawValue: String?) -> BuildVariant {
    guard let rawValue else { return .development }
    return BuildVariant(rawValue: rawValue) ?? .development
}

/// Merged flags for the running variant: settings overrides (key flags.override) over
/// the compile time defaults. This is the connection point the M2 settings screen and
/// the hidden dev screen read through.
public func resolvedFlags(for variant: BuildVariant, settings: any SettingsRepository) throws -> FlagValues {
    let defaults = defaultFlags(for: variant)
    guard let raw = try settings.get(key: settingsKeyFlagOverrides) else {
        return defaults
    }
    return mergeFlags(defaults, overridesJSON: raw)
}

private func compactMapKeys<Value>(_ dictionary: [String: Value], _ transform: (String) -> FeatureFlag?) -> [FeatureFlag: Value] {
    var result: [FeatureFlag: Value] = [:]
    for (key, value) in dictionary {
        if let mapped = transform(key) {
            result[mapped] = value
        }
    }
    return result
}
