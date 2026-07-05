import AppUIComponents
import CaptureBauhaus
import CaptureDoodle
import CapturePhoto
import JournalVault
import MediaProcessing

extension CardEditDraft {

  /// Display payload for read-only card previews.
  ///
  /// `CardEditDraft` remains app state owned by the creation/editing feature.
  /// `AppUIComponents` receives only this value projection, so the UI module
  /// does not depend back on the app target.
  @MainActor
  var previewPayload: CardPreviewPayload {
    switch kind {
    case .text:
      return .text(text)
    case .link:
      return .link(text)
    case .photo:
      return .photo(CardPreviewPhotoPayload(imageData: photo?.imageData))
    case .video:
      return .video(
        CardPreviewVideoPayload(
          fileURL: video?.fileURL,
          thumbnailData: video?.thumbnailData
        )
      )
    case .livePhoto:
      return .livePhoto(
        CardPreviewLivePhotoPayload(
          stillImageData: livePhoto?.stillImageData,
          pairedVideoFileURL: livePhoto?.pairedVideoFileURL,
          thumbnailData: livePhoto?.thumbnailData
        )
      )
    case .audio:
      return .audio
    case .doodle:
      return .doodle(CardPreviewDoodlePayload(drawing: doodle))
    case .bauhaus:
      return .bauhaus(CardPreviewBauhausPayload(document: bauhaus))
    case .unknown:
      return .unknown
    @unknown default:
      return .unknown
    }
  }
}
