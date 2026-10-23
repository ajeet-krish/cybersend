import AVFoundation
import SwiftUI
import UIKit

// AVPlayerLayer in a UIView whose backing layer is the player layer itself. No controls, no
// chrome: the review screen draws its own transport and overlay, and AVKit's controls would
// cover the bottom of the frame where a climber's feet are.

struct ClipPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> ClipPlayerHostView {
        let view = ClipPlayerHostView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: ClipPlayerHostView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

final class ClipPlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // The layer class is fixed above, so this cannot fail in practice.
        guard let layer = layer as? AVPlayerLayer else { return AVPlayerLayer() }
        return layer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}
