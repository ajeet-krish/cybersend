import CyberSendDomain
import AVFoundation
import CoreMedia
import Foundation
import ImageIO

/// AVFoundation frame reader for a local clip.
///
/// Uses AVAssetReader, not AVAssetImageGenerator: the reader walks the track once in decode
/// order, which is roughly an order of magnitude faster for a full clip and has honest
/// presentation timestamps. Output settings downscale during decode so Vision never receives a
/// full resolution buffer.
public final class AssetReaderVideoFrameReader: VideoFrameReading {
    /// Long edge of the buffers handed to Vision. The filming contract asks for 1080p capture,
    /// and 720 px analysis keeps decode and inference cost down without losing wrist precision
    /// in practice, which P0 will confirm on the corpus.
    public static let analysisLongEdge = 720

    public let metadata: VideoMetadata
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let orientation: CGImagePropertyOrientation
    private let bufferWidth: Int
    private let bufferHeight: Int

    private init(
        asset: AVURLAsset,
        track: AVAssetTrack,
        metadata: VideoMetadata,
        orientation: CGImagePropertyOrientation,
        bufferWidth: Int,
        bufferHeight: Int
    ) {
        self.asset = asset
        self.track = track
        self.metadata = metadata
        self.orientation = orientation
        self.bufferWidth = bufferWidth
        self.bufferHeight = bufferHeight
    }

    /// Loads the track once. All AVFoundation async loading happens here so the read loop stays
    /// synchronous and cannot interleave with other actor work.
    public static func make(url: URL) async throws -> AssetReaderVideoFrameReader {
        let asset = AVURLAsset(url: url)

        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw PoseAnalysisError.unreadableAsset(error.localizedDescription)
        }

        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw PoseAnalysisError.unreadableAsset(error.localizedDescription)
        }
        guard let track = tracks.first else { throw PoseAnalysisError.noVideoTrack }

        let transform = try await track.load(.preferredTransform)
        let naturalSize = try await track.load(.naturalSize)
        let nominalFPS = try? await track.load(.nominalFrameRate)
        let descriptions = try? await track.load(.formatDescriptions)

        let orientation = deriveOrientation(from: transform)
        let displaySize = displayDimensions(naturalSize: naturalSize, orientation: orientation)

        let metadata = VideoMetadata(
            width: max(1, Int(displaySize.width.rounded())),
            height: max(1, Int(displaySize.height.rounded())),
            nominalFPS: nominalFPS.flatMap { $0 > 0 ? Double($0) : nil },
            durationMs: max(0, Int((CMTimeGetSeconds(duration) * 1000).rounded())),
            isHDR: isHDRFormat(descriptions ?? []),
            orientation: orientation
        )

        let bufferSize = encodedBufferSize(naturalSize: naturalSize)
        return AssetReaderVideoFrameReader(
            asset: asset,
            track: track,
            metadata: metadata,
            orientation: cgOrientation(orientation),
            bufferWidth: bufferSize.width,
            bufferHeight: bufferSize.height
        )
    }

    public func read(
        stride: Int,
        startAfterMs: Int?,
        onFrame: (DecodedFrame) throws -> Bool
    ) throws {
        let effectiveStride = max(1, stride)
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw PoseAnalysisError.unreadableAsset(error.localizedDescription)
        }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: bufferWidth,
            kCVPixelBufferHeightKey as String: bufferHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw PoseAnalysisError.decodeFailed("The video track could not be read.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw PoseAnalysisError.decodeFailed(reader.error?.localizedDescription ?? "Unknown reason.")
        }

        var decodedIndex = 0
        while let sample = output.copyNextSampleBuffer() {
            defer { decodedIndex += 1 }

            if decodedIndex % effectiveStride != 0 { continue }

            let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
            let tMs = Int((CMTimeGetSeconds(presentation) * 1000).rounded())
            if let startAfterMs, tMs <= startAfterMs { continue }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }

            let keepGoing: Bool
            do {
                keepGoing = try onFrame(
                    DecodedFrame(pixelBuffer: pixelBuffer, tMs: tMs, orientation: orientation)
                )
            } catch {
                reader.cancelReading()
                throw error
            }
            if !keepGoing {
                reader.cancelReading()
                return
            }
        }

        if reader.status == .failed {
            throw PoseAnalysisError.decodeFailed(reader.error?.localizedDescription ?? "Unknown reason.")
        }
        if reader.status == .cancelled {
            throw PoseAnalysisError.cancelled
        }
    }

    // MARK: - Geometry

    /// Derives the display orientation from the track preferred transform.
    ///
    /// A clip recorded in portrait on an iPhone is usually stored landscape with a 90 degree
    /// transform. Ignoring it rotates every keypoint and produces plausible nonsense rather than
    /// an error, so this mapping is load bearing rather than cosmetic.
    ///
    /// The linear part of a video preferred transform is always a signed permutation matrix, so
    /// the eight orientations can be matched directly. Deriving the angle with atan2 is not
    /// enough: it reports a horizontal flip as a 180 degree rotation, which flips the result
    /// vertically and mirrors it incorrectly.
    public static func deriveOrientation(from transform: CGAffineTransform) -> VideoOrientation {
        let a = Int(transform.a.rounded())
        let b = Int(transform.b.rounded())
        let c = Int(transform.c.rounded())
        let d = Int(transform.d.rounded())

        switch (a, b, c, d) {
        case (1, 0, 0, 1): return .up
        case (-1, 0, 0, 1): return .upMirrored
        case (-1, 0, 0, -1): return .down
        case (1, 0, 0, -1): return .downMirrored
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (0, 1, 1, 0): return .leftMirrored
        case (0, -1, -1, 0): return .rightMirrored
        default:
            // Unknown rotation: treat as upright rather than failing the clip. The quality
            // summary will expose the resulting degradation.
            return .up
        }
    }

    static func displayDimensions(naturalSize: CGSize, orientation: VideoOrientation) -> CGSize {
        if orientation.swapsDimensions {
            return CGSize(width: naturalSize.height, height: naturalSize.width)
        }
        return naturalSize
    }

    /// Buffer dimensions for the analysis pass, scaled so the long edge is `analysisLongEdge` and
    /// rounded to even numbers because video decoders prefer even dimensions.
    static func encodedBufferSize(naturalSize: CGSize) -> (width: Int, height: Int) {
        let width = max(1, naturalSize.width)
        let height = max(1, naturalSize.height)
        let longEdge = max(width, height)
        let scale = min(1, Double(analysisLongEdge) / Double(longEdge))
        let scaledWidth = max(2, Int((width * scale).rounded()))
        let scaledHeight = max(2, Int((height * scale).rounded()))
        return (even(scaledWidth), even(scaledHeight))
    }

    private static func even(_ value: Int) -> Int {
        value.isMultiple(of: 2) ? value : value + 1
    }

    static func cgOrientation(_ orientation: VideoOrientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .upMirrored: return .upMirrored
        case .down: return .down
        case .downMirrored: return .downMirrored
        case .left: return .left
        case .leftMirrored: return .leftMirrored
        case .right: return .right
        case .rightMirrored: return .rightMirrored
        }
    }

    static func isHDRFormat(_ descriptions: [CMFormatDescription]) -> Bool {
        for description in descriptions {
            if let bits = CMFormatDescriptionGetExtension(
                description,
                extensionKey: kCMFormatDescriptionExtension_BitsPerComponent
            ) as? Int, bits > 8 {
                return true
            }
            if let transfer = CMFormatDescriptionGetExtension(
                description,
                extensionKey: kCMFormatDescriptionExtension_TransferFunction
            ) as? String {
                if transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
                    || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) {
                    return true
                }
            }
        }
        return false
    }
}
