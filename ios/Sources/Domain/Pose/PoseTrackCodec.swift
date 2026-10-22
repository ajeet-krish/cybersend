import Foundation

/// Packed binary form of a pose track.
///
/// A 30 second clip at 30 Hz is 900 frames by 19 joints, which is about 103 KB in this format and
/// roughly four times that as JSON. The blob is an internal storage detail: it is not exported, so
/// a restored backup keeps analysis metadata and events and marks the track for recompute.
///
/// Layout, little endian throughout:
/// magic (8 bytes), joint count (UInt16), sampling rate (Float64), source width and height
/// (UInt32 each), source fps (Float32, zero means unknown), Vision revision (Int32), frame count
/// (Int32), then per frame: timestamp (Int32), coverage (Float32), and for every joint in
/// `PoseJoint.allCases` order: x (Float16), y (Float16), confidence (Float16), flags (UInt8).
///
/// A joint with confidence zero is absent. Flag bit 0 marks an interpolated sample.
public enum PoseTrackCodec {
    public static let formatIdentifier = "pose-track-f16-v1"

    private static let magic: [UInt8] = Array("CSPOSE01".utf8)
    private static let frameHeaderBytes = 8
    private static let bytesPerJoint = 7

    public static func encode(_ track: PoseTrack) -> Data {
        let jointCount = PoseJoint.allCases.count
        var bytes: [UInt8] = []
        bytes.reserveCapacity(
            magic.count + 30 + track.frames.count * (frameHeaderBytes + jointCount * bytesPerJoint)
        )

        bytes.append(contentsOf: magic)
        append(UInt16(jointCount), to: &bytes)
        append(track.samplingHz.bitPattern, to: &bytes)
        append(UInt32(clamping: track.sourceWidth), to: &bytes)
        append(UInt32(clamping: track.sourceHeight), to: &bytes)
        append(Float32(track.sourceFPS ?? 0).bitPattern, to: &bytes)
        append(Int32(clamping: track.visionRevision), to: &bytes)
        append(Int32(clamping: track.frames.count), to: &bytes)

        for frame in track.frames {
            append(Int32(clamping: frame.tMs), to: &bytes)
            append(Float32(frame.coverage).bitPattern, to: &bytes)
            for joint in PoseJoint.allCases {
                if let sample = frame.joints[joint], sample.confidence > 0 {
                    append(Float16(sample.x).bitPattern, to: &bytes)
                    append(Float16(sample.y).bitPattern, to: &bytes)
                    append(Float16(sample.confidence).bitPattern, to: &bytes)
                    bytes.append(sample.isInterpolated ? 1 : 0)
                } else {
                    append(Float16(0).bitPattern, to: &bytes)
                    append(Float16(0).bitPattern, to: &bytes)
                    append(Float16(0).bitPattern, to: &bytes)
                    bytes.append(0)
                }
            }
        }

        return Data(bytes)
    }

    public static func decode(_ data: Data) throws -> PoseTrack {
        var reader = ByteReader(Array(data))

        guard try reader.readBytes(magic.count) == magic else {
            throw PoseTrackCodecError.badMagic
        }
        let jointCount = Int(try reader.readUInt16())
        guard jointCount == PoseJoint.allCases.count else {
            throw PoseTrackCodecError.unsupportedJointCount(jointCount)
        }

        let samplingHz = Double(bitPattern: try reader.readUInt64())
        let sourceWidth = Int(try reader.readUInt32())
        let sourceHeight = Int(try reader.readUInt32())
        let sourceFPSBits = try reader.readUInt32()
        let sourceFPS = Float32(bitPattern: sourceFPSBits)
        let visionRevision = Int(try reader.readInt32())
        let frameCount = Int(try reader.readInt32())

        guard frameCount >= 0 else { throw PoseTrackCodecError.corrupt }

        var frames: [PoseFrame] = []
        frames.reserveCapacity(frameCount)

        for _ in 0..<frameCount {
            let tMs = Int(try reader.readInt32())
            let coverageBits = try reader.readUInt32()
            let coverage = Double(Float32(bitPattern: coverageBits))

            var joints: [PoseJoint: JointSample] = [:]
            joints.reserveCapacity(jointCount)

            for joint in PoseJoint.allCases {
                let x = Float16(bitPattern: try reader.readUInt16())
                let y = Float16(bitPattern: try reader.readUInt16())
                let confidence = Float16(bitPattern: try reader.readUInt16())
                let flags = try reader.readUInt8()

                guard confidence > 0 else { continue }
                joints[joint] = JointSample(
                    x: Double(x),
                    y: Double(y),
                    confidence: Double(confidence),
                    isInterpolated: flags & 0x01 != 0
                )
            }

            frames.append(PoseFrame(tMs: tMs, joints: joints, coverage: coverage))
        }

        return PoseTrack(
            samplingHz: samplingHz,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            sourceFPS: sourceFPS > 0 ? Double(sourceFPS) : nil,
            visionRevision: visionRevision,
            frames: frames
        )
    }

    // MARK: - Byte writing

    private static func append<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { buffer in
            bytes.append(contentsOf: buffer)
        }
    }
}

public enum PoseTrackCodecError: Error, Equatable, Sendable {
    case badMagic
    case truncated
    case corrupt
    case unsupportedJointCount(Int)
}

extension PoseTrackCodecError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .badMagic:
            return "The stored pose track is not in a recognised format."
        case .truncated:
            return "The stored pose track ended unexpectedly."
        case .corrupt:
            return "The stored pose track is damaged."
        case .unsupportedJointCount(let count):
            return "The stored pose track uses \(count) joints, which this build cannot read."
        }
    }
}

private struct ByteReader {
    private let bytes: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard index + count <= bytes.count else { throw PoseTrackCodecError.truncated }
        let slice = Array(bytes[index..<(index + count)])
        index += count
        return slice
    }

    mutating func readUInt8() throws -> UInt8 {
        guard index < bytes.count else { throw PoseTrackCodecError.truncated }
        defer { index += 1 }
        return bytes[index]
    }

    mutating func readUInt16() throws -> UInt16 {
        try readInteger()
    }

    mutating func readUInt32() throws -> UInt32 {
        try readInteger()
    }

    mutating func readUInt64() throws -> UInt64 {
        try readInteger()
    }

    mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    private mutating func readInteger<T: FixedWidthInteger>() throws -> T {
        let count = MemoryLayout<T>.size
        guard index + count <= bytes.count else { throw PoseTrackCodecError.truncated }
        var value: T = 0
        for offset in 0..<count {
            value |= T(bytes[index + offset]) << (8 * offset)
        }
        index += count
        return value
    }
}
