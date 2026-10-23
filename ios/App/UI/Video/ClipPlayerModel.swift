import AVFoundation
import Combine
import Foundation

// Playback state for the clip review screen (P5). One AVPlayer, one periodic observer, and a
// millisecond clock, so the overlay and the timeline can follow the video without owning any
// AVFoundation state themselves.
//
// The clock is driven by the player's own time observer rather than a SwiftUI timer, because a
// timer drifts against playback and the overlay would lag the frame it is meant to annotate.

@MainActor
final class ClipPlayerModel: ObservableObject {
    let player: AVPlayer
    @Published private(set) var currentMs: Int = 0
    @Published private(set) var durationMs: Int = 0
    @Published private(set) var isPlaying = false

    private let item: AVPlayerItem
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    init(url: URL) {
        item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        installObservers()
        loadDuration()
    }

    func play() {
        if durationMs > 0, currentMs >= durationMs - 20 {
            seek(toMs: 0)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func toggle() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func seek(toMs milliseconds: Int) {
        let clamped = max(0, min(milliseconds, durationMs > 0 ? durationMs : milliseconds))
        currentMs = clamped
        let time = CMTime(value: CMTimeValue(clamped), timescale: 1000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Detaches every observer and pauses. Called from the screen's onDisappear, so a dismissed
    /// screen does not keep decoding frames or retain the player through the observer closure.
    func stop() {
        player.pause()
        isPlaying = false
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func installObservers() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            let milliseconds = Int((CMTimeGetSeconds(time) * 1000).rounded())
            Task { @MainActor in
                self?.currentMs = max(0, milliseconds)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = false
                self.currentMs = self.durationMs
            }
        }
    }

    private func loadDuration() {
        Task { [weak self] in
            guard let self else { return }
            let asset = item.asset
            guard let duration = try? await asset.load(.duration) else { return }
            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite, seconds > 0 else { return }
            self.durationMs = Int((seconds * 1000).rounded())
        }
    }
}
