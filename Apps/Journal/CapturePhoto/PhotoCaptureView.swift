import Capturer
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
      Color.black.ignoresSafeArea()

      switch controller.authorization {
      case .unknown:
        ProgressView().tint(.white)
      case .authorized:
        CameraPreviewView(previewView: controller.previewView)
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
    .task { await controller.configureAndStart() }
    .onDisappear { Task { await controller.stop() } }
  }

  private var controls: some View {
    VStack {
      HStack {
        Spacer()
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
      .foregroundStyle(.white)
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

/// Hosts Capturer's `PixelBufferView` (a UIView) inside SwiftUI. The view is
/// owned by the controller, so this representable just mounts it.
private struct CameraPreviewView: UIViewRepresentable {
  let previewView: PixelBufferView

  func makeUIView(context: Context) -> PixelBufferView {
    previewView
  }

  func updateUIView(_ uiView: PixelBufferView, context: Context) {}
}
