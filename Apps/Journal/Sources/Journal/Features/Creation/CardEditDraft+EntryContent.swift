import AppUIComponents
import CaptureAudio
import CaptureBauhaus
import CaptureDoodle
import CapturePhoto
import JournalVault
import MediaProcessing

extension CardEditDraft {

  /// Authored-content projection for read-only display and export styles.
  ///
  /// `CardEditDraft` remains app state owned by the creation/editing feature.
  /// `AppUIComponents` receives only this value projection, so the UI module
  /// does not depend back on the app target.
  @MainActor
  var entryContent: EntryContent {
    switch kind {
    case .text:
      return .text(text)
    case .todo:
      return .todo(
        TodoContentSource(text: text, completedAt: completedAt)
      )
    case .link:
      return .link(text)
    case .file:
      return .file(FileContentSource(displayName: text))
    case .photo:
      return .photo(
        PhotoContentSource(
          imageData: photo?.imageData,
          pixelSize: photo?.pixelSize
        )
      )
    case .video:
      return .video(
        VideoContentSource(
          fileURL: video?.fileURL,
          thumbnailData: video?.thumbnailData,
          pixelSize: video?.pixelSize
        )
      )
    case .livePhoto:
      return .livePhoto(
        LivePhotoContentSource(
          stillImageData: livePhoto?.stillImageData,
          pairedVideoFileURL: livePhoto?.pairedVideoFileURL,
          thumbnailData: livePhoto?.thumbnailData,
          pixelSize: livePhoto?.pixelSize
        )
      )
    case .audio:
      return .audio(AudioContentSource(fileURL: audio?.fileURL))
    case .suggestion:
      return .suggestion(
        SuggestionContentSource(
          suggestion: suggestion,
          mediaFileURLsByResourceID: suggestionMediaFileURLsByResourceID
        )
      )
    case .doodle:
      return .doodle(DoodleContentSource(drawing: doodle))
    case .bauhaus:
      return .bauhaus(BauhausContentSource(document: bauhaus))
    case .unknown:
      return .unknown
    @unknown default:
      return .unknown
    }
  }
}
