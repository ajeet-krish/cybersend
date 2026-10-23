import AVFoundation
import SwiftUI
import UIKit

// The camera preview plus tap to focus. A UIView whose backing layer is the preview layer, so
// there is no second view to keep in sync with layout. Taps are converted into capture device
// coordinates here, because that conversion belongs to the layer and not to the view model.

struct CapturePreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// View point (for the reticle) and device point (for the focus lock).
    let onTap: (CGPoint, CGPoint) -> Void

    func makeUIView(context: Context) -> CapturePreviewView {
        let view = CapturePreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onTap = onTap
        return view
    }

    func updateUIView(_ uiView: CapturePreviewView, context: Context) {
        uiView.applyPortraitRotation()
    }
}

final class CapturePreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // The layer class is fixed above, so this cast cannot fail.
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            return AVCaptureVideoPreviewLayer()
        }
        return layer
    }

    var onTap: ((CGPoint, CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func applyPortraitRotation() {
        guard let connection = previewLayer.connection else { return }
        if #available(iOS 17.0, *) {
            if connection.videoRotationAngle != 90 {
                connection.videoRotationAngle = 90
            }
        } else {
            if connection.videoOrientation != .portrait {
                connection.videoOrientation = .portrait
            }
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: point)
        onTap?(point, devicePoint)
    }
}
