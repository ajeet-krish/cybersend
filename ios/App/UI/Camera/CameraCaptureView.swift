import AVFoundation
import CyberSendFeatures
import SwiftUI
import UIKit

// Camera seam (M3, docs/decisions.md "photo capture is PhotosPicker plus
// UIImagePickerController behind a seam"): stills capture is a UIImagePickerController
// wrapped by CameraCaptureView and hidden behind the CameraCapturing protocol, so the
// simulator and denied states degrade to a disabled row and any later swap to
// AVCaptureSession (M6) replaces one type. Permission handling: first use lets the
// system prompt fire when the picker presents; denied and restricted never re-prompt
// (the screen shows a Settings deep link instead, US-17).

/// The video authorization that drives the camera row state. Restricted means parental
/// controls block the camera; the Settings link cannot fix that but the state is honest.
enum CameraAuthorization: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

/// The camera seam the photo source dialog talks to. Views never touch UIKit camera
/// types directly; app tests drive a fake through this protocol and the simulator run
/// exercises the unavailable path for real.
@MainActor
protocol CameraCapturing: AnyObject {
    /// False when the device has no camera (the simulator) or the hardware is otherwise
    /// unavailable; the photo source dialog hides the Take photo row.
    var isAvailable: Bool { get }
    /// The current video authorization; denied and restricted render the disabled state
    /// with the Settings deep link.
    var authorization: CameraAuthorization { get }
    /// Whether the capture UI is on screen. The full screen cover binds this.
    var isPresenting: Bool { get set }
    /// Presents the capture UI. First use triggers the system prompt from the picker
    /// itself; denied and restricted are no-ops (never a re-prompt loop).
    func present()
    /// Dismisses the capture UI and re reads the authorization (the system prompt may
    /// have just been decided while the picker was up).
    func dismiss()
}

/// The live seam over UIImagePickerController and AVCaptureDevice authorization.
@MainActor
final class SystemCameraCapture: CameraCapturing, ObservableObject {
    @Published var isPresenting: Bool = false
    @Published private(set) var authorization: CameraAuthorization

    let isAvailable: Bool

    init() {
        isAvailable = UIImagePickerController.isSourceTypeAvailable(.camera)
        authorization = Self.currentAuthorization()
    }

    func present() {
        authorization = Self.currentAuthorization()
        guard isAvailable, !isPresenting else { return }
        // Denied and restricted never re-present: the picker would fail immediately and
        // a second system prompt can never appear anyway (iOS prompt rules).
        guard authorization != .denied, authorization != .restricted else { return }
        isPresenting = true
    }

    func dismiss() {
        isPresenting = false
        authorization = Self.currentAuthorization()
    }

    private static func currentAuthorization() -> CameraAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }
}

/// The UIImagePickerController wrapper (stills only). The coordinator hands captured
/// image bytes up and never touches any store: the caller runs them through the ingest
/// pipeline exactly like library bytes (docs/architecture.md M3 photo stack).
struct CameraCaptureView: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    let onCancel: () -> Void
    let onFail: (String) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        // The iOS 26 SDK removed the sourceType initializer; the property remains. The
        // full screen cover only renders after CameraCapturing.present passed the
        // availability guard, and the extra check keeps a race from asserting.
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .camera
        }
        picker.delegate = context.coordinator
        picker.modalPresentationStyle = .fullScreen
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel, onFail: onFail)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (Data) -> Void
        private let onCancel: () -> Void
        private let onFail: (String) -> Void

        init(onCapture: @escaping (Data) -> Void, onCancel: @escaping () -> Void, onFail: @escaping (String) -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
            self.onFail = onFail
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard
                let image = info[.originalImage] as? UIImage,
                let data = image.jpegData(compressionQuality: photoIngestJPEGQuality)
            else {
                onFail("The photo could not be captured. Try again.")
                return
            }
            onCapture(data)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}
