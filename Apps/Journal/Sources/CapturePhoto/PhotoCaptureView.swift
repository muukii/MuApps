@preconcurrency import AVFoundation
import SwiftUI

/// A self-contained in-place camera surface: live preview, shutter, and
/// front/back flip. Launches the camera on appear and emits the still through
/// `onCapture`.
public struct PhotoCaptureView: View {

  @State private var controller = CameraController()
  @State private var isCapturing = false
  @State private var errorMessage: String?

  private let onCapture: @MainActor @Sendable (CapturedPhoto) -> Void

  public init(onCapture: @escaping @MainActor @Sendable (CapturedPhoto) -> Void) {
    self.onCapture = onCapture
  }

  public var body: some View {
    ZStack {
      switch controller.authorization {
      case .unknown:
        ProgressView().tint(.primary)
      case .authorized:
        CameraPreviewView(session: controller.previewSession, isMirrored: controller.isFront)
          .ignoresSafeArea()
      case .denied:
        unavailableMessage("Camera access is off. Enable it in Settings to take a photo.")
      case .unavailable:
        unavailableMessage("No camera is available on this device.")
      }

      if controller.authorization == .authorized {
        controls
      }
    }
    .background(.background)
    .task { await controller.configureAndStart() }
    .onDisappear { Task { await controller.stop() } }
  }

  private var controls: some View {
    VStack {
      HStack {
        Spacer()
        if controller.canFlipCamera {
          Button {
            Task { await controller.flip() }
          } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
              .font(.title2)
              .padding(12)
              .background(.ultraThinMaterial, in: Circle())
          }
          .tint(.white)
        }
      }
      .padding()

      Spacer()

      shutterButton
        .padding(.bottom, 32)
    }
  }

  private var shutterButton: some View {
    Button {
      capture()
    } label: {
      ZStack {
        Circle().strokeBorder(.white, lineWidth: 4).frame(width: 74, height: 74)
        Circle().fill(.white).frame(width: 60, height: 60)
      }
      .opacity(isCapturing ? 0.4 : 1)
    }
    .disabled(isCapturing)
    .accessibilityLabel("Take photo")
  }

  private func unavailableMessage(_ text: String) -> some View {
    Text(text)
      .multilineTextAlignment(.center)
      .foregroundStyle(.primary)
      .padding(40)
  }

  private func capture() {
    isCapturing = true
    Task {
      defer { isCapturing = false }
      do {
        let photo = try await controller.capturePhoto()
        onCapture(photo)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}

// MARK: - Preview bridge

/// Hosts `AVCaptureVideoPreviewLayer` inside SwiftUI.
#if canImport(UIKit)
private struct CameraPreviewView: UIViewRepresentable {
  let session: AVCaptureSession
  let isMirrored: Bool

  func makeUIView(context: Context) -> PreviewView {
    let view = PreviewView()
    view.configure(session: session, isMirrored: isMirrored)
    return view
  }

  func updateUIView(_ uiView: PreviewView, context: Context) {
    uiView.configure(session: session, isMirrored: isMirrored)
  }
}
#elseif canImport(AppKit)
/// Hosts the same AVFoundation preview session in a layer-backed AppKit view.
private struct CameraPreviewView: NSViewRepresentable {
  let session: AVCaptureSession
  let isMirrored: Bool

  func makeNSView(context: Context) -> PreviewView {
    let view = PreviewView()
    view.configure(session: session, isMirrored: isMirrored)
    return view
  }

  func updateNSView(_ nsView: PreviewView, context: Context) {
    nsView.configure(session: session, isMirrored: isMirrored)
  }
}

private final class PreviewView: NSView {
  private let previewLayer = AVCaptureVideoPreviewLayer()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.addSublayer(previewLayer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    previewLayer.frame = bounds
  }

  func configure(session: AVCaptureSession, isMirrored: Bool) {
    previewLayer.videoGravity = .resizeAspectFill
    if previewLayer.session !== session {
      previewLayer.session = session
    }
    if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
      connection.automaticallyAdjustsVideoMirroring = false
      connection.isVideoMirrored = isMirrored
    }
  }
}
#endif

#if canImport(UIKit)
private final class PreviewView: UIView {

  override static var layerClass: AnyClass {
    AVCaptureVideoPreviewLayer.self
  }

  private var previewLayer: AVCaptureVideoPreviewLayer {
    layer as! AVCaptureVideoPreviewLayer
  }

  private var isMirrored = false

  func configure(session: AVCaptureSession, isMirrored: Bool) {
    previewLayer.videoGravity = .resizeAspectFill
    if previewLayer.session !== session {
      previewLayer.session = session
    }
    self.isMirrored = isMirrored
    configureConnection()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    configureConnection()
  }

  private func configureConnection() {
    guard let connection = previewLayer.connection else { return }

    connection.setPortraitVideoRotationIfSupported()

    if connection.isVideoMirroringSupported {
      connection.automaticallyAdjustsVideoMirroring = false
      connection.isVideoMirrored = isMirrored
    }
  }
}
#endif
