import CapturePhoto
import SwiftUI
import UIKit

/// Native sheet shell for capturing a photo card from the composer.
///
/// The sheet does not create a draft until `PhotoCaptureView` returns an image.
/// Dismissal without capture is therefore a pure cancellation.
struct ThreadDraftPhotoCaptureSheet: View {

  @Environment(\.dismiss) private var dismiss

  /// Existing draft to update. `nil` means the caller will decide where the
  /// captured photo should be inserted after capture completes.
  let card: ThreadDraftCard?

  /// Called with the captured photo before the sheet dismisses.
  let onCapture: @MainActor @Sendable (CapturedPhoto) -> Void

  var body: some View {
    NavigationStack {
      ThreadDraftPhotoCaptureContent(card: card) { photo in
        onCapture(photo)
        dismiss()
      }
      .navigationTitle("Photo")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            dismiss()
          }
        }
      }
    }
  }
}

/// Photo capture content shared by the Creation sheet and the full-screen draft
/// editor. It previews an existing captured photo and switches back to the camera
/// when the user chooses to retake it.
struct ThreadDraftPhotoCaptureContent: View {

  /// Existing draft whose photo can be previewed or replaced.
  let card: ThreadDraftCard?

  /// Called whenever the camera completes a new capture.
  let onCapture: @MainActor @Sendable (CapturedPhoto) -> Void

  @State private var isCapturingReplacement: Bool = false

  var body: some View {
    if let photo = card?.photo, isCapturingReplacement == false {
      ThreadDraftPhotoExistingContent(
        photo: photo,
        onRetake: {
          isCapturingReplacement = true
        }
      )
    } else {
      PhotoCaptureView { photo in
        onCapture(photo)
        isCapturingReplacement = false
      }
      .clipped()
    }
  }
}

/// Displays the still already attached to a photo draft.
private struct ThreadDraftPhotoExistingContent: View {

  let photo: CapturedPhoto
  let onRetake: @MainActor @Sendable () -> Void

  private var image: UIImage? {
    photo.image
  }

  var body: some View {
    ZStack {
      if let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ThreadDraftPhotoUnavailableContent()
      }

      VStack {
        Spacer()
        Button(action: onRetake) {
          Label("Retake Photo", systemImage: "camera.rotate")
        }
        .buttonStyle(.borderedProminent)
        .padding(.bottom, 32)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Placeholder for a photo draft whose stored image data can no longer decode.
private struct ThreadDraftPhotoUnavailableContent: View {

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "photo")
        .font(.system(size: 54, weight: .light))
      Text("Photo unavailable")
        .font(.headline)
    }
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
