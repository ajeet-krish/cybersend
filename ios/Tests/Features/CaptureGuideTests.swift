import Foundation
import Testing
@testable import CyberSendFeatures

// Guided capture rules (P4): level math, format choice, the recording clock, and the framing
// box. No camera, no AVFoundation, no device.

@Suite("Capture level")
struct CaptureLevelTests {
    @Test("a phone held upright reads level")
    func uprightIsLevel() {
        let level = CaptureLevel(gravity: GravityVector(x: 0, y: -1, z: 0))
        #expect(level.rollDegrees == 0)
        #expect(level.isLevel)
        #expect(level.guidance == .level)
        #expect(level.guidance.text == "Level")
    }

    @Test("a sideways tilt reads as roll and asks for the opposite correction")
    func tiltedRightAsksForLeft() {
        // Gravity leaning toward the device's right edge means the top of the phone rolled right.
        let level = CaptureLevel(gravity: GravityVector(x: 0.0998, y: -0.995, z: 0))
        #expect(level.rollDegrees > 5)
        #expect(level.isLevel == false)
        guard case .rollRight(let degrees) = level.guidance else {
            Issue.record("expected a roll right guidance, got \(level.guidance)")
            return
        }
        #expect(abs(degrees - level.rollDegrees) < 1e-9)
        #expect(level.guidance.text.hasPrefix("Rotate left"))
    }

    @Test("the opposite tilt asks for the opposite correction")
    func tiltedLeftAsksForRight() {
        let level = CaptureLevel(gravity: GravityVector(x: -0.0998, y: -0.995, z: 0))
        #expect(level.rollDegrees < -5)
        guard case .rollLeft(let degrees) = level.guidance else {
            Issue.record("expected a roll left guidance, got \(level.guidance)")
            return
        }
        #expect(abs(degrees + level.rollDegrees) < 1e-9)
        #expect(level.guidance.text.hasPrefix("Rotate right"))
    }

    @Test("the tolerance boundary is inclusive on both sides")
    func toleranceBoundary() {
        #expect(CaptureLevel(rollDegrees: 2).isLevel)
        #expect(CaptureLevel(rollDegrees: -2).isLevel)
        #expect(CaptureLevel(rollDegrees: 2.01).isLevel == false)
        #expect(CaptureLevel(rollDegrees: -2.01).isLevel == false)
    }

    @Test("a degenerate gravity vector does not produce a NaN roll")
    func degenerateGravity() {
        let level = CaptureLevel(gravity: GravityVector(x: 0, y: 0, z: 0))
        #expect(level.rollDegrees == 0)
        #expect(level.isLevel)
        #expect(level.rollDegrees.isNaN == false)
    }

    @Test("roll ignores the component that points out of the screen")
    func rollIgnoresDepth() {
        let flat = CaptureLevel(gravity: GravityVector(x: 0.05, y: -0.9987, z: 0))
        let tipped = CaptureLevel(gravity: GravityVector(x: 0.05, y: -0.9987, z: 0.4))
        #expect(abs(flat.rollDegrees - tipped.rollDegrees) < 1e-9)
    }
}

@Suite("Capture format selection")
struct CaptureFormatSelectionTests {
    private func format(_ width: Int, _ height: Int, _ fps: Double) -> CaptureFormat {
        CaptureFormat(width: width, height: height, maxFrameRate: fps)
    }

    @Test("1080p60 wins over 4K and over 720p high frame rate")
    func prefers1080p60() {
        let formats = [
            format(1920, 1080, 30),
            format(3840, 2160, 60),
            format(1920, 1080, 60),
            format(1280, 720, 240),
        ]
        #expect(CaptureFormatSelection.bestIndex(in: formats) == 2)
    }

    @Test("without 60 fps the best 1080p30 is chosen")
    func fallsBackTo1080p30() {
        let formats = [format(1280, 720, 240), format(1920, 1080, 30)]
        #expect(CaptureFormatSelection.bestIndex(in: formats) == 1)
    }

    @Test("a 4K only device still records rather than failing")
    func accepts4KWhenItIsAllThereIs() {
        let formats = [format(3840, 2160, 30)]
        #expect(CaptureFormatSelection.bestIndex(in: formats) == 0)
    }

    @Test("720p is the floor and is used when no 1080p format exists")
    func uses720pAsFloor() {
        let formats = [format(640, 480, 30), format(1280, 720, 60)]
        #expect(CaptureFormatSelection.bestIndex(in: formats) == 1)
    }

    @Test("formats below 30 fps and below the resolution floor are rejected")
    func rejectsUnusableFormats() {
        #expect(CaptureFormatSelection.bestIndex(in: [format(1920, 1080, 24)]) == nil)
        #expect(CaptureFormatSelection.bestIndex(in: [format(640, 480, 30)]) == nil)
        #expect(CaptureFormatSelection.bestIndex(in: []) == nil)
    }

    @Test("portrait formats are ranked by their short edge, same as landscape")
    func portraitDimensionsRankEqually() {
        let landscape = [format(1920, 1080, 60), format(1280, 720, 60)]
        let portrait = [format(1080, 1920, 60), format(720, 1280, 60)]
        #expect(CaptureFormatSelection.bestIndex(in: landscape) == 0)
        #expect(CaptureFormatSelection.bestIndex(in: portrait) == 0)
    }
}

@Suite("Capture clock and framing")
struct CaptureClockTests {
    @Test("the clock reads minutes and zero padded seconds")
    func durationText() {
        #expect(CaptureDuration.text(milliseconds: 0) == "0:00")
        #expect(CaptureDuration.text(milliseconds: 7_000) == "0:07")
        #expect(CaptureDuration.text(milliseconds: 65_000) == "1:05")
        #expect(CaptureDuration.text(milliseconds: 83_900) == "1:23")
        #expect(CaptureDuration.text(milliseconds: -500) == "0:00")
    }

    @Test("the elapsed label carries the hard limit")
    func elapsedText() {
        #expect(CaptureDuration.elapsedText(milliseconds: 12_000) == "0:12 / 1:30")
    }

    @Test("the soft warning starts at a minute")
    func softWarning() {
        #expect(CaptureDuration.isPastSoftWarning(milliseconds: 59_999) == false)
        #expect(CaptureDuration.isPastSoftWarning(milliseconds: 60_000))
    }

    @Test("the framing box leaves a margin on every side")
    func framingBoxIsInsideTheFrame() {
        let box = CaptureFramingBox.standard
        #expect(box.isInsideUnitSquare)
        #expect(box.x > 0.1)
        #expect(box.y > 0.05)
        #expect(box.x + box.width < 0.9)
        #expect(box.y + box.height < 0.95)
        #expect(box.height > box.width, "a climber is taller than wide in frame")
    }
}
