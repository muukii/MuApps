@preconcurrency import AVFoundation
import CoreImage
import ImageIO
import Observation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Owns the AVFoundation camera session and bridges camera state to SwiftUI.
/// Internal to the framework so AVFoundation setup stays behind the component's
/// public `PhotoCaptureView` / `CapturedPhoto` API.
@MainActor
@Observable
final class CameraController {

  /// Camera authorization states that affect the capture surface.
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

  /// Whether the current platform exposes meaningful front/back camera choices.
  var canFlipCamera: Bool {
    #if os(macOS)
    false
    #else
    true
    #endif
  }

  @ObservationIgnored private let cameraSession = CameraSession()
  @ObservationIgnored private var activePhotoCaptureProcessor: PhotoCaptureProcessor?

  var previewSession: AVCaptureSession {
    cameraSession.session
  }

  init() {}

  /// Requests camera authorization when needed and starts the selected camera.
  /// Resolves `authorization` to `.unavailable` when the device has no usable
  /// camera, such as on Simulator.
  func configureAndStart() async {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      authorization = .authorized
    case .notDetermined:
      guard await AVCaptureDevice.requestAccess(for: .video) else {
        authorization = .denied
        return
      }
      authorization = .authorized
    case .denied, .restricted:
      authorization = .denied
      return
    @unknown default:
      authorization = .denied
      return
    }

    await start(front: isFront)
  }

  func flip() async {
    guard canFlipCamera else { return }
    await start(front: !isFront)
  }

  func stop() async {
    await cameraSession.stop()
    isRunning = false
  }

  func capturePhoto() async throws -> CapturedPhoto {
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
      throw CameraError.notAuthorized
    }

    let settings = cameraSession.makePhotoSettings()

    return try await withCheckedThrowingContinuation { continuation in
      let processor = PhotoCaptureProcessor(isMirrored: isFront) { [weak self] result in
        self?.activePhotoCaptureProcessor = nil
        switch result {
        case .success(let photo):
          continuation.resume(returning: photo)
        case .failure(let error):
          continuation.resume(throwing: error)
        }
      }
      activePhotoCaptureProcessor = processor
      cameraSession.capturePhoto(with: settings, delegate: processor)
    }
  }

  private func start(front: Bool) async {
    do {
      #if os(macOS)
      // Mac cameras don't model the iPhone front/back relationship. Asking for
      // an unspecified video device lets AVFoundation select the built-in or
      // user-selected continuity camera instead of filtering every device out.
      let position = AVCaptureDevice.Position.unspecified
      #else
      let position: AVCaptureDevice.Position = front ? .front : .back
      #endif
      try await cameraSession.configureAndStart(position: position)
      isFront = front
      isRunning = true
    } catch {
      authorization = .unavailable
    }
  }
}

/// Errors produced by the local camera implementation.
private enum CameraError: LocalizedError, Sendable {
  case notAuthorized
  case couldNotFindCamera
  case couldNotAddInput
  case couldNotAddPhotoOutput
  case missingImageRepresentation
  case missingJPEGData
  case captureFailed(String)

  var errorDescription: String? {
    switch self {
    case .notAuthorized:
      return "Camera access is not authorized."
    case .couldNotFindCamera:
      return "No usable camera is available."
    case .couldNotAddInput:
      return "The camera input could not be added to the session."
    case .couldNotAddPhotoOutput:
      return "The photo output could not be added to the session."
    case .missingImageRepresentation:
      return "The captured photo did not contain an image representation."
    case .missingJPEGData:
      return "The captured photo could not be converted to JPEG."
    case .captureFailed(let message):
      return message
    }
  }
}

/// Serializes `AVCaptureSession` mutations while exposing the session to the
/// preview layer. Keeping this local avoids a package-level camera abstraction.
private final class CameraSession: @unchecked Sendable {

  let session = AVCaptureSession()

  private let photoOutput = AVCapturePhotoOutput()
  private let queue = DispatchQueue(label: "app.muukii.journal.capture-photo.session")
  private var currentInput: AVCaptureDeviceInput?

  init() {
    photoOutput.maxPhotoQualityPrioritization = .balanced
  }

  func configureAndStart(position: AVCaptureDevice.Position) async throws {
    try await queue.perform {
      let device = try Self.bestBuiltInCamera(position: position)
      let input = try AVCaptureDeviceInput(device: device)

      self.session.beginConfiguration()

      do {
        self.session.sessionPreset = .photo
        #if os(iOS)
        self.session.automaticallyConfiguresCaptureDeviceForWideColor = true
        #endif

        if let currentInput = self.currentInput {
          self.session.removeInput(currentInput)
          self.currentInput = nil
        }

        guard self.session.canAddInput(input) else {
          throw CameraError.couldNotAddInput
        }
        self.session.addInput(input)
        self.currentInput = input

        if self.session.outputs.contains(self.photoOutput) == false {
          guard self.session.canAddOutput(self.photoOutput) else {
            throw CameraError.couldNotAddPhotoOutput
          }
          self.session.addOutput(self.photoOutput)
        }
        self.session.commitConfiguration()
      } catch {
        self.session.commitConfiguration()
        throw error
      }

      if self.session.isRunning == false {
        self.session.startRunning()
      }
    }
  }

  func stop() async {
    await queue.perform {
      if self.session.isRunning {
        self.session.stopRunning()
      }
    }
  }

  func capturePhoto(
    with settings: AVCapturePhotoSettings,
    delegate: PhotoCaptureProcessor
  ) {
    #if os(iOS)
    photoOutput.connection(with: .video)?.setPortraitVideoRotationIfSupported()
    #endif
    photoOutput.capturePhoto(with: settings, delegate: delegate)
  }

  func makePhotoSettings() -> AVCapturePhotoSettings {
    let settings = AVCapturePhotoSettings()
    if photoOutput.supportedFlashModes.contains(.auto) {
      settings.flashMode = .auto
    }
    return settings
  }

  private static func bestBuiltInCamera(position: AVCaptureDevice.Position) throws -> AVCaptureDevice {
    if position == .unspecified,
       let defaultVideoDevice = AVCaptureDevice.default(for: .video) {
      return defaultVideoDevice
    }

    #if os(iOS)
    let deviceTypes: [AVCaptureDevice.DeviceType] = [
      .builtInWideAngleCamera,
      .builtInUltraWideCamera,
      .builtInTelephotoCamera,
    ]
    #else
    let deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
    #endif

    let discoverySession = AVCaptureDevice.DiscoverySession(
      deviceTypes: deviceTypes,
      mediaType: .video,
      position: position
    )

    guard let device = discoverySession.devices.first else {
      throw CameraError.couldNotFindCamera
    }

    return device
  }
}

/// Retains the `AVCapturePhotoCaptureDelegate` until one still-photo capture
/// finishes, then reports a component-level `CapturedPhoto`.
private final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {

  private let isMirrored: Bool
  private let completion: @MainActor @Sendable (Result<CapturedPhoto, CameraError>) -> Void

  init(
    isMirrored: Bool,
    completion: @escaping @MainActor @Sendable (Result<CapturedPhoto, CameraError>) -> Void
  ) {
    self.isMirrored = isMirrored
    self.completion = completion
  }

  func photoOutput(
    _ output: AVCapturePhotoOutput,
    didFinishProcessingPhoto photo: AVCapturePhoto,
    error: (any Error)?
  ) {
    let result: Result<CapturedPhoto, CameraError>

    if let error {
      result = .failure(.captureFailed(error.localizedDescription))
    } else {
      do {
        result = .success(try Self.makeCapturedPhoto(from: photo, isMirrored: isMirrored))
      } catch let error as CameraError {
        result = .failure(error)
      } catch {
        result = .failure(.captureFailed(error.localizedDescription))
      }
    }

    Task { @MainActor [completion] in
      completion(result)
    }
  }

  private static func makeCapturedPhoto(
    from photo: AVCapturePhoto,
    isMirrored: Bool
  ) throws -> CapturedPhoto {
    guard let cgImage = photo.cgImageRepresentation() else {
      throw CameraError.missingImageRepresentation
    }

    #if canImport(UIKit)
    let orientation = photo.cgImagePropertyOrientation.uiImageOrientation
    let image = UIImage(cgImage: cgImage, scale: 1, orientation: orientation)
    let outputImage = isMirrored ? image.withHorizontallyFlippedOrientation() : image

    guard let data = outputImage.jpegData(compressionQuality: 0.9) else {
      throw CameraError.missingJPEGData
    }

    return CapturedPhoto(imageData: data, pixelSize: outputImage.size)
    #elseif canImport(AppKit)
    let orientedImage = CIImage(cgImage: cgImage)
      .oriented(photo.cgImagePropertyOrientation)
    let context = CIContext(options: [.useSoftwareRenderer: false])
    guard let outputCGImage = context.createCGImage(orientedImage, from: orientedImage.extent) else {
      throw CameraError.missingImageRepresentation
    }

    let bitmap = NSBitmapImageRep(cgImage: outputCGImage)
    guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
      throw CameraError.missingJPEGData
    }
    return CapturedPhoto(
      imageData: data,
      pixelSize: CGSize(width: outputCGImage.width, height: outputCGImage.height)
    )
    #endif
  }
}

private extension AVCapturePhoto {

  var cgImagePropertyOrientation: CGImagePropertyOrientation {
    #if os(iOS)
    guard
      let value = metadata[String(kCGImagePropertyOrientation)] as? NSNumber,
      let orientation = CGImagePropertyOrientation(rawValue: value.uint32Value)
    else {
      return .up
    }

    return orientation
    #else
    // Desktop capture devices deliver their still image in display orientation;
    // AVCapturePhoto does not expose the iOS metadata dictionary on macOS.
    return .up
    #endif
  }
}

#if canImport(UIKit)
private extension CGImagePropertyOrientation {

  var uiImageOrientation: UIImage.Orientation {
    switch self {
    case .up:
      return .up
    case .upMirrored:
      return .upMirrored
    case .down:
      return .down
    case .downMirrored:
      return .downMirrored
    case .left:
      return .left
    case .leftMirrored:
      return .leftMirrored
    case .right:
      return .right
    case .rightMirrored:
      return .rightMirrored
    }
  }
}
#endif

private extension DispatchQueue {

  func perform(_ work: @escaping @Sendable () -> Void) async {
    await withCheckedContinuation { continuation in
      async {
        work()
        continuation.resume()
      }
    }
  }

  func perform(_ work: @escaping @Sendable () throws -> Void) async throws {
    try await withCheckedThrowingContinuation { continuation in
      async {
        do {
          try work()
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}

extension AVCaptureConnection {

  func setPortraitVideoRotationIfSupported() {
    let portraitAngle: CGFloat = 90
    if isVideoRotationAngleSupported(portraitAngle) {
      videoRotationAngle = portraitAngle
    }
  }
}
