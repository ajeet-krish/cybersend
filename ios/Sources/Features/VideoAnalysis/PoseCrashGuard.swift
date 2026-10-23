import Foundation

// Crash guard for the pose pipeline (US-40.3).
//
// Analysis is foreground and explicit: a marker is written when a run starts and cleared when it
// ends, on every path including cancellation. A marker still present at the next launch therefore
// means the process died mid run (a crash, a watchdog kill, or a force quit), and the launch path
// turns the experimental flag off rather than leaving a user in a crash loop. Settings shows a
// notice and offers a one tap way back on, so an auto disable is never a dead end.
//
// A cancelled run clears its marker, so the ordinary cancel path is never mistaken for a crash.
// The guard only reports; flipping the flag is the caller's job, because the flag lives in the
// settings table and the guard has no repository access.

public final class PoseCrashGuard: @unchecked Sendable {
    /// The run that was in flight. The timestamp is carried for the notice and for diagnostics.
    public struct Marker: Codable, Equatable, Sendable {
        public var videoId: String
        public var startedAt: Date

        public init(videoId: String, startedAt: Date = Date()) {
            self.videoId = videoId
            self.startedAt = startedAt
        }
    }

    /// What the launch path should do after looking at the marker.
    public struct Recovery: Equatable, Sendable {
        /// True when a run did not finish, so the experimental flag should be turned off.
        public var autoDisabled: Bool
        /// The clip that was being analysed when the process died, when known.
        public var videoId: String?

        public init(autoDisabled: Bool, videoId: String? = nil) {
            self.autoDisabled = autoDisabled
            self.videoId = videoId
        }

        public static let none = Recovery(autoDisabled: false)
    }

    /// UserDefaults keys. Namespaced so they cannot collide with settings table keys.
    public static let markerKey = "pose.inflight"
    public static let autoDisabledKey = "pose.autoDisabled"

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Run lifecycle

    /// Marks a run as started. Called before extraction begins.
    public func begin(videoId: String, at date: Date = Date()) {
        guard let data = try? JSONEncoder().encode(Marker(videoId: videoId, startedAt: date)) else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        defaults.set(data, forKey: Self.markerKey)
    }

    /// Clears the marker. Called on success, failure, and cancellation alike.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: Self.markerKey)
    }

    public func marker() -> Marker? {
        lock.lock()
        defer { lock.unlock() }
        guard
            let data = defaults.data(forKey: Self.markerKey),
            let marker = try? JSONDecoder().decode(Marker.self, from: data)
        else { return nil }
        return marker
    }

    // MARK: - Launch recovery

    /// Reads and clears the marker. Any marker at launch is a run that did not finish, because no
    /// analysis can be in flight in a process that has only just started, so no age threshold is
    /// needed. The caller turns the flag off when `autoDisabled` is true.
    public func recoverIfNeeded() -> Recovery {
        lock.lock()
        defer { lock.unlock() }
        guard
            let data = defaults.data(forKey: Self.markerKey),
            let marker = try? JSONDecoder().decode(Marker.self, from: data)
        else {
            return .none
        }
        defaults.removeObject(forKey: Self.markerKey)
        defaults.set(true, forKey: Self.autoDisabledKey)
        return Recovery(autoDisabled: true, videoId: marker.videoId)
    }

    /// True after an auto disable until the user turns the feature back on.
    public var wasAutoDisabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return defaults.bool(forKey: Self.autoDisabledKey)
    }

    /// Clears the auto disable notice. Called when the user re-enables the feature.
    public func clearAutoDisabled() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: Self.autoDisabledKey)
    }
}
