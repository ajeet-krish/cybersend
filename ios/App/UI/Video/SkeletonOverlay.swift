import CyberSendDomain
import SwiftUI

// Pose overlay for the review screen: bones between the joints Vision returned for one frame,
// drawn on top of the player layer.
//
// Coordinates are normalized image space with a top left origin, which is the same convention
// the tagging canvas uses, so the only maths here is the aspect fit between the video's pixel
// size and the space the player layer actually occupies.

enum SkeletonEdges {
    /// Bones worth drawing. The face points are omitted: they are noisy and add nothing to a
    /// climbing read, and Vision drops them first when the climber turns away.
    static let pairs: [(PoseJoint, PoseJoint)] = [
        (.neck, .nose),
        (.neck, .leftShoulder), (.neck, .rightShoulder),
        (.leftShoulder, .rightShoulder),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.leftShoulder, .leftHip), (.rightShoulder, .rightHip),
        (.leftHip, .rightHip),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
        (.root, .leftHip), (.root, .rightHip),
    ]
}

struct SkeletonOverlay: View {
    let frame: PoseFrame
    let videoSize: CGSize

    var body: some View {
        GeometryReader { proxy in
            let rect = Self.fittedRect(video: videoSize, in: proxy.size)
            Canvas { context, _ in
                for (from, to) in SkeletonEdges.pairs {
                    guard
                        let start = point(for: from, in: rect),
                        let end = point(for: to, in: rect)
                    else { continue }
                    var path = Path()
                    path.move(to: start)
                    path.addLine(to: end)
                    context.stroke(
                        path,
                        with: .color(Theme.accent.opacity(0.9)),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                }
                for (_, sample) in frame.joints where sample.isUsable {
                    let center = CGPoint(
                        x: rect.minX + sample.x * rect.width,
                        y: rect.minY + sample.y * rect.height
                    )
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: center.x - 3,
                            y: center.y - 3,
                            width: 6,
                            height: 6
                        )),
                        with: .color(.white)
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func point(for joint: PoseJoint, in rect: CGRect) -> CGPoint? {
        guard let sample = frame.joints[joint], sample.isUsable else { return nil }
        return CGPoint(
            x: rect.minX + sample.x * rect.width,
            y: rect.minY + sample.y * rect.height
        )
    }

    /// The rectangle the video occupies under aspect fit, which is what the player layer draws.
    static func fittedRect(video: CGSize, in container: CGSize) -> CGRect {
        guard video.width > 0, video.height > 0, container.width > 0, container.height > 0 else {
            return .zero
        }
        let scale = min(container.width / video.width, container.height / video.height)
        let size = CGSize(width: video.width * scale, height: video.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}
