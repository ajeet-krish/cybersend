import Foundation

/// Failures the pose pipeline can report. Every case has a plain language description because
/// these strings reach the review screen, and the feature is experimental, so "why did nothing
/// happen" has to be answerable without a console.
public enum PoseAnalysisError: Error, Equatable, Sendable {
    case unreadableAsset(String)
    case noVideoTrack
    case noPoseDetected
    case cancelled
    case decodeFailed(String)
    case detectionFailed(String)
    case emptyTrack
}

extension PoseAnalysisError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unreadableAsset(let detail):
            return "This video could not be opened. \(detail)"
        case .noVideoTrack:
            return "This file has no video track."
        case .noPoseDetected:
            return "No person was found in the video."
        case .cancelled:
            return "Analysis was cancelled."
        case .decodeFailed(let detail):
            return "Video decoding failed. \(detail)"
        case .detectionFailed(let detail):
            return "Pose detection failed. \(detail)"
        case .emptyTrack:
            return "The analysis produced no frames."
        }
    }
}
