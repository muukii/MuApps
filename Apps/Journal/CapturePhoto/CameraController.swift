import Capturer
import Observation
import UIKit

/// Owns the Capturer session graph (input → preview/photo outputs) and bridges
/// it to SwiftUI. Internal to the framework so Capturer types never leak into
/// the component's public API.
@MainActor
@Observable
final class CameraController {

  enum AuthorizationState: Equatable {
    case unknown
    case authorized
    /// User declined camera access.
    case denied
    /// No usable camera (e.g. Simulator).
    case unavailable
  }

  private(set) var authorization: AuthorizationState = .unknown
  private(set) var isFront = false
  private(set) var isRunning = false

  // Capturer graph. `attach`/`start`/`stop` are async; the preview view renders
  // CVPixelBuffers pushed from PreviewOutput.
  @ObservationIgnored let previewView = PixelBufferView()
  @ObservationIgnored
  private let captureBody = CaptureBody(configuration: .init { $0.sessionPreset = .photo })
  @ObservationIgnored private let previewOutput = PreviewOutput()
  @ObservationIgnored private let photoOutput = PhotoOutput(quality: .balanced)
  @ObservationIgnored private var isConfigured = false

  init() {}

  /// Requests authorization (Capturer never does this itself) and starts the
  /// session. Resolves `authorization` to `.unavailable` when there's no camera.
  func configureAndStart() async {
    guard await AVCaptureDevice.requestAccess(for: .video) else {
      authorization = .denied
      return
    }
    authorization = .authorized
    await start(front: isFront)
  }

  func flip() async {
    await start(front: !isFront)
  }

  func stop() async {
    await captureBody.stop()
    isRunning = false
  }

  func capturePhoto() async throws -> CapturedPhoto {
    let settings = AVCapturePhotoSettings()
    settings.flashMode = .auto
    let result = try await photoOutput.capture(with: settings)
    let image = result.makeImage(isMirrored: isFront)
    let data = image.jpegData(compressionQuality: 0.9) ?? Data()
    return CapturedPhoto(imageData: data, pixelSize: image.size)
  }

  private func start(front: Bool) async {
    do {
      let input = try CameraInput.bestBuiltInDevice(position: front ? .front : .back)
      await captureBody.attach(input: input)
      if isConfigured == false {
        await captureBody.attach(output: previewOutput)
        await captureBody.attach(output: photoOutput)
        previewView.attach(output: previewOutput)
        isConfigured = true
      }
      previewOutput.setIsMirroringEnabled(front)
      isFront = front
      await captureBody.start()
      isRunning = true
    } catch {
      authorization = .unavailable
    }
  }
}
