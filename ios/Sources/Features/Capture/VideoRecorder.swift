#if canImport(AVFoundation)
import AVFoundation
import Combine
import CoreGraphics
import Foundation

// Guided video recorder (P4). One session, one movie output, no audio input: a boulder clip is
// silent by nature and skipping audio means the recorder never asks for the microphone.
//
// Concurrency: every AVFoundation session mutation runs on one serial queue owned by the box,
// because startRunning blocks and the session is not safe to configure from several threads.
// The published state and the continuation live on the main actor. The session object itself is
// shared with the preview layer on the main actor, which is the configuration Apple documents.

public struct RecordedClip: Sendable, Equatable {
    public let fileURL: URL
    public let durationMs: Int

    public init(fileURL: URL, durationMs: Int) {
        self.fileURL = fileURL
        self.durationMs = durationMs
    }
}

public enum VideoRecorderError: Error, Equatable, Sendable {
    case cameraUnavailable
    case permissionDenied
    case configurationFailed
    case notReady
    case alreadyRecording
    case notRecording
    case recordingFailed(String)
    case emptyRecording
}

extension VideoRecorderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            return "This device has no back camera."
        case .permissionDenied:
            return "Camera access is off for CyberSend. Turn it on in Settings."
        case .configurationFailed:
            return "The camera could not be configured for recording."
        case .notReady:
            return "The camera is not ready yet."
        case .alreadyRecording:
            return "A recording is already running."
        case .notRecording:
            return "No recording is running."
        case .recordingFailed(let detail):
            return "Recording failed. \(detail)"
        case .emptyRecording:
            return "The recording produced no video."
        }
    }
}

/// Owns the session and the queue. `@unchecked Sendable` because every mutable field is touched
/// only on `queue`; the session is also read by the preview layer on the main actor, which
/// AVFoundation supports.
private final class CaptureSessionBox: @unchecked Sendable {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "app.cybersend.capture.session", qos: .userInitiated)
    var movieOutput: AVCaptureMovieFileOutput?
    var device: AVCaptureDevice?
    var appliedFPS: Double = 0
    var appliedWidth: Int = 0
    var appliedHeight: Int = 0
}

@MainActor
public final class VideoRecorder: NSObject, ObservableObject {
    public enum State: Equatable, Sendable {
        case idle
        case preparing
        case ready
        case recording
        case finishing
        case failed(String)
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var elapsedMs: Int = 0
    @Published public private(set) var appliedFPS: Double = 0
    @Published public private(set) var appliedWidth: Int = 0
    @Published public private(set) var appliedHeight: Int = 0

    private nonisolated let box = CaptureSessionBox()
    private var finishContinuation: CheckedContinuation<RecordedClip, Error>?
    private var timer: Timer?
    private var startedAt: Date?
    private var clipURL: URL?
    /// Set when the user backs out mid recording, so the finalized file is deleted rather than
    /// left in the temporary directory.
    private var isCancelling = false

    /// The session the preview layer renders. Read on the main actor only.
    public nonisolated var session: AVCaptureSession { box.session }

    public override init() {
        super.init()
    }

    // MARK: - Lifecycle

    /// Requests access, picks a format, and starts the session. Safe to call again after a
    /// failure; a ready or recording recorder is left alone.
    public func prepare() async throws {
        switch state {
        case .ready, .recording, .finishing:
            return
        default:
            break
        }

        guard AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
            || AVCaptureDevice.default(for: .video) != nil
        else {
            state = .failed(VideoRecorderError.cameraUnavailable.localizedDescription)
            throw VideoRecorderError.cameraUnavailable
        }

        state = .preparing

        guard await AVCaptureDevice.requestAccess(for: .video) else {
            state = .failed(VideoRecorderError.permissionDenied.localizedDescription)
            throw VideoRecorderError.permissionDenied
        }

        let box = self.box
        let configuration: (fps: Double, width: Int, height: Int)? = await withCheckedContinuation { continuation in
            box.queue.async {
                continuation.resume(returning: Self.configure(box: box))
            }
        }

        guard let configuration else {
            state = .failed(VideoRecorderError.configurationFailed.localizedDescription)
            throw VideoRecorderError.configurationFailed
        }

        appliedFPS = configuration.fps
        appliedWidth = configuration.width
        appliedHeight = configuration.height
        state = .ready
    }

    /// Stops the session and releases the camera. Called when the recorder screen goes away.
    public func tearDown() {
        if state == .recording {
            cancelRecording()
        }
        stopTimer()
        // A view that disappears while a stop is still finalizing must not leave the awaiting
        // task suspended forever.
        if let continuation = finishContinuation {
            finishContinuation = nil
            continuation.resume(
                throwing: VideoRecorderError.recordingFailed("The recorder closed before the clip finished saving.")
            )
        }
        let box = self.box
        box.queue.async {
            if box.session.isRunning {
                box.session.stopRunning()
            }
            box.session.beginConfiguration()
            for input in box.session.inputs {
                box.session.removeInput(input)
            }
            for output in box.session.outputs {
                box.session.removeOutput(output)
            }
            box.session.commitConfiguration()
            box.movieOutput = nil
            box.device = nil
        }
        state = .idle
        elapsedMs = 0
    }

    // MARK: - Recording

    public func startRecording() throws {
        guard state == .ready else {
            throw state == .recording ? VideoRecorderError.alreadyRecording : VideoRecorderError.notReady
        }
        guard let output = box.movieOutput else {
            throw VideoRecorderError.notReady
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cybersend-\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: url)

        output.startRecording(to: url, recordingDelegate: self)
        clipURL = url
        startedAt = Date()
        elapsedMs = 0
        state = .recording
        startTimer()
    }

    /// Stops and waits for the file to be finalized. The delegate resumes the continuation.
    public func stopRecording() async throws -> RecordedClip {
        guard state == .recording else { throw VideoRecorderError.notRecording }
        guard let output = box.movieOutput, output.isRecording else {
            throw VideoRecorderError.notRecording
        }

        state = .finishing
        stopTimer()

        return try await withCheckedThrowingContinuation { continuation in
            finishContinuation = continuation
            output.stopRecording()
        }
    }

    /// Returns to the ready state after the user discards a finished clip. The session keeps
    /// running, because the camera is already warm and a retake should not wait for it again.
    public func resetAfterDiscard() {
        clipURL = nil
        elapsedMs = 0
        if state != .recording, state != .preparing {
            state = box.movieOutput == nil ? .idle : .ready
        }
    }

    public func cancelRecording() {
        guard state == .recording else { return }
        isCancelling = true
        stopTimer()
        state = .finishing
        box.movieOutput?.stopRecording()
    }

    // MARK: - Focus and exposure

    /// Locks focus and exposure on a point the preview layer already converted to device space.
    /// Failures are ignored: a clip with default focus is better than no clip.
    public func lockFocusAndExposure(atDevicePoint point: CGPoint) {
        let box = self.box
        box.queue.async {
            guard let device = box.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    if device.isFocusModeSupported(.autoFocus) {
                        device.focusMode = .autoFocus
                    }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    if device.isExposureModeSupported(.autoExpose) {
                        device.exposureMode = .autoExpose
                    }
                }
                device.unlockForConfiguration()
            } catch {
                // Convenience only.
            }
        }
    }

    /// Returns focus and exposure to continuous autofocus, which is the state the recorder
    /// starts in and the one a climber moving to a new hold needs.
    public func resetFocusAndExposure() {
        let box = self.box
        box.queue.async {
            guard let device = box.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch {
                // Convenience only.
            }
        }
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let startedAt else { return }
        elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
    }

    // MARK: - Delegate handoff

    fileprivate func finish(url: URL, durationMs: Int, failureMessage: String?) {
        stopTimer()
        let continuation = finishContinuation
        finishContinuation = nil
        clipURL = nil

        if isCancelling {
            isCancelling = false
            try? FileManager.default.removeItem(at: url)
            elapsedMs = 0
            state = .idle
            continuation?.resume(
                throwing: VideoRecorderError.recordingFailed("Recording cancelled.")
            )
            return
        }

        if let continuation {
            if let failureMessage {
                state = .failed(VideoRecorderError.recordingFailed(failureMessage).localizedDescription)
                continuation.resume(throwing: VideoRecorderError.recordingFailed(failureMessage))
                return
            }
            guard durationMs > 0, FileManager.default.fileExists(atPath: url.path) else {
                state = .ready
                continuation.resume(throwing: VideoRecorderError.emptyRecording)
                return
            }
            state = .ready
            continuation.resume(returning: RecordedClip(fileURL: url, durationMs: durationMs))
            return
        }

        // The output stopped on its own, usually at the hard limit, with nobody waiting.
        state = failureMessage == nil ? .ready : .failed(failureMessage ?? "")
    }

    // MARK: - Configuration

    /// Runs on the box queue. Returns only Sendable values, so nothing AVFoundation typed crosses
    /// the isolation boundary.
    private nonisolated static func configure(
        box: CaptureSessionBox
    ) -> (fps: Double, width: Int, height: Int)? {
        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video)
        else { return nil }

        let descriptors = device.formats.map { format -> CaptureFormat in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let maxFrameRate = format.videoSupportedFrameRateRanges
                .map(\.maxFrameRate)
                .max() ?? 0
            return CaptureFormat(
                width: Int(dimensions.width),
                height: Int(dimensions.height),
                maxFrameRate: maxFrameRate
            )
        }
        guard let index = CaptureFormatSelection.bestIndex(in: descriptors) else { return nil }
        let selected = device.formats[index]

        let supported = selected.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        let fps = min(CaptureFormatSelection.preferredFPS, supported)

        do {
            try device.lockForConfiguration()
            device.activeFormat = selected
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps.rounded())))
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            device.unlockForConfiguration()
        } catch {
            return nil
        }

        guard
            let input = try? AVCaptureDeviceInput(device: device),
            box.session.canAddInput(input)
        else { return nil }

        box.session.beginConfiguration()
        box.session.addInput(input)

        let output = AVCaptureMovieFileOutput()
        output.movieFragmentInterval = .invalid
        output.maxRecordedDuration = CMTime(
            value: Int64(CaptureLimits.hardStopMs),
            timescale: 1000
        )
        guard box.session.canAddOutput(output) else {
            box.session.commitConfiguration()
            return nil
        }
        box.session.addOutput(output)

        if let connection = output.connection(with: .video) {
            #if os(iOS)
            if #available(iOS 17.0, *) {
                connection.videoRotationAngle = 90
            } else {
                connection.videoOrientation = .portrait
            }
            #endif
            connection.isVideoMirrored = false
        }

        box.session.commitConfiguration()
        box.movieOutput = output
        box.device = device

        let dimensions = CMVideoFormatDescriptionGetDimensions(selected.formatDescription)
        let shortEdge = min(Int(dimensions.width), Int(dimensions.height))
        let longEdge = max(Int(dimensions.width), Int(dimensions.height))
        // Portrait output: the taller edge is the recorded height.
        box.appliedWidth = shortEdge
        box.appliedHeight = longEdge
        box.appliedFPS = fps

        if !box.session.isRunning {
            box.session.startRunning()
        }

        return (fps, shortEdge, longEdge)
    }
}

extension VideoRecorder: AVCaptureFileOutputRecordingDelegate {
    public nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let seconds = CMTimeGetSeconds(output.recordedDuration)
        let durationMs = seconds.isFinite && seconds > 0 ? Int((seconds * 1000).rounded()) : 0
        let message = error?.localizedDescription
        Task { @MainActor in
            self.finish(url: outputFileURL, durationMs: durationMs, failureMessage: message)
        }
    }
}
#endif
