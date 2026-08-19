import SwiftUI

/// A native iOS, iPadOS, and macOS surface for editing an `ImageCropSession`.
///
/// Drag to reposition the image and pinch (or use a Mac trackpad magnification
/// gesture) to zoom. The circular mask previews how the profile image will be
/// presented, while `ImageCropSession.renderJPEG()` intentionally returns a
/// square JPEG so other UI can choose its own display shape.
public struct ImageCropEditor: View {

  private let session: ImageCropSession

  /// Creates an editor for an existing crop session.
  public init(session: ImageCropSession) {
    self.session = session
  }

  public var body: some View {
    GeometryReader { proxy in
      let viewportLength = min(proxy.size.width, proxy.size.height)

      ImageCropCanvas(
        session: session,
        viewportLength: viewportLength
      )
      .frame(width: viewportLength, height: viewportLength)
      .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
    }
  }
}

private struct ImageCropCanvas: View {

  let session: ImageCropSession
  let viewportLength: CGFloat

  @GestureState private var transientTranslation: CGSize = .zero
  @GestureState private var transientMagnification: CGFloat = 1

  var body: some View {
    let presentation = session.presentation(
      viewportLength: viewportLength,
      transientMagnification: transientMagnification,
      transientTranslation: transientTranslation
    )

    ZStack {
      Color.black.opacity(0.08)

      Image(decorative: session.sourceImage, scale: 1, orientation: .up)
        .resizable()
        .interpolation(.high)
        .frame(
          width: presentation.displayedImageSize.width,
          height: presentation.displayedImageSize.height
        )
        .offset(presentation.imageOffset)
        .allowsHitTesting(false)
    }
    .clipShape(Circle())
    .overlay {
      Circle()
        .stroke(.white.opacity(0.72), lineWidth: 1)
        .allowsHitTesting(false)
    }
    .contentShape(Circle())
    .gesture(dragGesture)
    .simultaneousGesture(magnificationGesture)
    .accessibilityElement()
    .accessibilityLabel(
      Text(
        "Image crop area",
        bundle: #bundle,
        comment: "Accessibility label for the draggable and zoomable profile image crop area."
      )
    )
    .accessibilityValue(
      Text(session.currentZoomScale, format: .percent.precision(.fractionLength(0)))
    )
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment:
        session.adjustZoom(by: 1.25)
      case .decrement:
        session.adjustZoom(by: 0.8)
      @unknown default:
        break
      }
    }
  }

  private var dragGesture: some Gesture {
    DragGesture(minimumDistance: 0)
      .updating($transientTranslation) { value, state, _ in
        state = value.translation
      }
      .onEnded { value in
        session.commitTranslation(
          value.translation,
          viewportLength: viewportLength
        )
      }
  }

  private var magnificationGesture: some Gesture {
    MagnifyGesture()
      .updating($transientMagnification) { value, state, _ in
        state = value.magnification
      }
      .onEnded { value in
        session.commitMagnification(value.magnification)
      }
  }
}
