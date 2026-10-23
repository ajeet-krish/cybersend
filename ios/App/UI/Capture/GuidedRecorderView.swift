import CyberSendFeatures
import SwiftUI
import UIKit

// Guided recorder (P4). One screen, one job: get a clip that the pose pipeline can read.
//
// The screen is deliberately thin on options. Level, framing, focus lock, and a clock are the
// whole feature, because every extra control competes with the two things that actually decide
// whether the analysis works: the phone must not move, and the whole body must stay in frame.
// The clip is handed back as a file URL and adopted by the existing media import path; nothing
// here writes the database.

struct GuidedRecorderView: View {
    let onRecorded: (RecordedClip) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = VideoRecorder()
    @StateObject private var motion = MotionLevelMonitor()

    @State private var errorMessage: String?
    @State private var finishedClip: RecordedClip?
    @State private var focusReticle: CGPoint?
    @State private var showsFocusNotice = false
    @State private var isStopping = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CapturePreview(session: recorder.session) { viewPoint, devicePoint in
                focus(at: viewPoint, devicePoint: devicePoint)
            }
            .ignoresSafeArea()

            if recorder.state == .ready || recorder.state == .preparing || recorder.state == .recording {
                framingOverlay
            }

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                if let errorMessage {
                    errorCard(errorMessage)
                } else if let finishedClip {
                    reviewCard(finishedClip)
                } else {
                    bottomBar
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)

            if showsFocusNotice, let focusReticle {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(.yellow.opacity(0.9), lineWidth: 1.5)
                    .frame(width: 64, height: 64)
                    .position(focusReticle)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .statusBarHidden()
        .accessibilityIdentifier("capture.screen")
        .task { await prepare() }
        .onDisappear {
            motion.stop()
            recorder.tearDown()
        }
        .onChange(of: recorder.elapsedMs) { elapsed in
            guard
                elapsed >= CaptureLimits.maximumRecordingMs,
                recorder.state == .recording,
                !isStopping
            else { return }
            Task { await stop() }
        }
    }

    // MARK: - Bars

    private var topBar: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                if recorder.state == .recording {
                    recorder.cancelRecording()
                }
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .accessibilityIdentifier("capture.close")
            .accessibilityLabel("Close recorder")

            Spacer(minLength: 8)

            VStack(spacing: 6) {
                if recorder.state == .recording || recorder.state == .finishing {
                    Text(CaptureDuration.text(milliseconds: recorder.elapsedMs))
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .foregroundStyle(
                            CaptureDuration.isPastSoftWarning(milliseconds: recorder.elapsedMs)
                                ? Theme.warning
                                : .white
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.45), in: Capsule())
                        .accessibilityIdentifier("capture.clock")
                }
                levelBadge
            }

            Spacer(minLength: 8)

            // Balances the close button so the clock stays centered.
            Color.clear.frame(width: 36, height: 36)
        }
    }

    private var levelBadge: some View {
        let level = motion.level
        let isLevel = level?.isLevel ?? false
        let text: String
        if let level {
            text = level.guidance.text
        } else {
            text = "Level hint unavailable"
        }
        let tint: Color = level == nil ? Theme.secondaryText : (isLevel ? Theme.success : Theme.warning)

        return HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.45), in: Capsule())
        .accessibilityIdentifier("capture.level")
    }

    private var bottomBar: some View {
        VStack(spacing: 14) {
            if showsFocusNotice {
                Text("Focus locked")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.55), in: Capsule())
                    .accessibilityIdentifier("capture.focus-locked")
                    .transition(.opacity)
            }

            if recorder.state == .preparing {
                ProgressView()
                    .tint(.white)
                Text("Starting camera")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
            } else if recorder.state == .recording {
                recordButton(isRecording: true)
            } else if recorder.state == .finishing {
                ProgressView()
                    .tint(.white)
                Text("Finishing clip")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
            } else {
                recordButton(isRecording: false)
                Text("Keep the phone still and both feet in frame")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func recordButton(isRecording: Bool) -> some View {
        Button {
            Task {
                if isRecording {
                    await stop()
                } else {
                    start()
                }
            }
        } label: {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 74, height: 74)
                if isRecording {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.danger)
                        .frame(width: 30, height: 30)
                } else {
                    Circle()
                        .fill(Theme.danger)
                        .frame(width: 58, height: 58)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(recorder.state == .preparing || recorder.state == .finishing)
        .accessibilityIdentifier(isRecording ? "capture.stop" : "capture.record")
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }

    private var framingOverlay: some View {
        GeometryReader { proxy in
            let box = CaptureFramingBox.standard
            let rect = CGRect(
                x: box.x * proxy.size.width,
                y: box.y * proxy.size.height,
                width: box.width * proxy.size.width,
                height: box.height * proxy.size.height
            )
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(
                        .white.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1, dash: [6, 6])
                    )
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)

                ForEach(0..<4, id: \.self) { corner in
                    cornerMark(index: corner, in: rect)
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    private func cornerMark(index: Int, in rect: CGRect) -> Path {
        let length: CGFloat = 22
        var path = Path()
        switch index {
        case 0:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + length))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + length, y: rect.minY))
        case 1:
            path.move(to: CGPoint(x: rect.maxX - length, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + length))
        case 2:
            path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - length))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX - length, y: rect.maxY))
        default:
            path.move(to: CGPoint(x: rect.minX + length, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - length))
        }
        return path
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("capture.error")
            HStack(spacing: 10) {
                if message.contains("Settings"), let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("Open Settings", destination: url)
                        .buttonStyle(.borderedProminent)
                }
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func reviewCard(_ clip: RecordedClip) -> some View {
        VStack(spacing: 14) {
            Text("Clip ready")
                .font(.headline)
                .foregroundStyle(.white)
            Text(CaptureDuration.text(milliseconds: clip.durationMs))
                .font(.system(.title2, design: .monospaced).weight(.semibold))
                .foregroundStyle(.white)
            Text("The clip is saved with the session. Analysis runs from the clip.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)

            HStack(spacing: 10) {
                Button("Retake") {
                    discard(clip)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("capture.retake")

                Button("Use clip") {
                    onRecorded(clip)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("capture.use")
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Actions

    private func prepare() async {
        motion.start()
        do {
            try await recorder.prepare()
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func start() {
        do {
            try recorder.startRecording()
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func stop() async {
        guard !isStopping else { return }
        isStopping = true
        defer { isStopping = false }
        do {
            finishedClip = try await recorder.stopRecording()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func discard(_ clip: RecordedClip) {
        try? FileManager.default.removeItem(at: clip.fileURL)
        finishedClip = nil
        recorder.resetAfterDiscard()
    }

    private func focus(at viewPoint: CGPoint, devicePoint: CGPoint) {
        recorder.lockFocusAndExposure(atDevicePoint: devicePoint)
        focusReticle = viewPoint
        withAnimation(.easeOut(duration: 0.15)) {
            showsFocusNotice = true
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation(.easeIn(duration: 0.2)) {
                showsFocusNotice = false
            }
        }
    }
}
