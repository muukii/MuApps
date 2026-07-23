import Foundation
import SwiftData
import TypedIdentifier

// MARK: - Video Item Source

/// Identifies where a `VideoItem` obtains its playable media.
///
/// Existing records have no stored source value and are interpreted as YouTube
/// items to preserve compatibility with the original model.
nonisolated enum VideoItemSource: String, Codable, Sendable {
  case youtube
  case importedFile
}

/// Describes the primary presentation of a file imported from Files.
nonisolated enum ImportedMediaKind: String, Codable, Sendable {
  case audio
  case video
}

// MARK: - Video Item

@Model
final class VideoItem: TypedIdentifiable {

  typealias TypedIdentifierRawValue = UUID

  var typedID: TypedIdentifier<VideoItem> {
    .init(id)
  }

  var id: UUID

  // Database storage (primitive String for SwiftData optimization)
  internal var _videoID: String

  // Public API (type-safe)
  var videoID: YouTubeContentID {
    get { YouTubeContentID(rawValue: _videoID) }
    set { _videoID = newValue.rawValue }
  }

  var url: String
  var title: String?
  var author: String?
  var thumbnailURL: String?
  var timestamp: Date

  /// Persisted raw value for `source`.
  ///
  /// This remains optional so records created before local-file import was
  /// introduced migrate as YouTube items without a data rewrite.
  internal var _sourceRawValue: String?

  /// Persisted raw value for `importedMediaKind`.
  internal var _importedMediaKindRawValue: String?

  /// The service that provides this item's playable media.
  var source: VideoItemSource {
    get {
      _sourceRawValue
        .flatMap(VideoItemSource.init(rawValue:))
        ?? .youtube
    }
    set {
      _sourceRawValue = newValue.rawValue
    }
  }

  /// The presentation kind of an imported file, or `nil` for YouTube items.
  var importedMediaKind: ImportedMediaKind? {
    get {
      _importedMediaKindRawValue.flatMap(ImportedMediaKind.init(rawValue:))
    }
    set {
      _importedMediaKindRawValue = newValue?.rawValue
    }
  }

  var isYouTubeSource: Bool {
    source == .youtube
  }

  /// Lexicographic order key for manual sorting in history list.
  /// nil means the item needs to be initialized with a sort order.
  var sortOrder: String?

  // Transcript cache
  var transcriptData: Data?
  var transcriptLanguage: String?

  // Managed media file (relative path from Documents directory)
  var downloadedFileName: String?

  // MARK: - Playback Resume

  /// Last playback position in seconds for resume functionality
  var lastPlaybackPosition: Double?

  /// Total duration of the video in seconds (for progress display)
  var duration: Double?

  /// Last time this video was played (updated when playback position is saved)
  var lastPlayedTime: Date?

  // MARK: - Download State Relationship

  /// Active download state (exists only during download).
  /// When download completes, fails, or is cancelled, this entity is deleted.
  @Relationship(deleteRule: .cascade, inverse: \DownloadStateEntity.videoItem)
  var downloadState: DownloadStateEntity?

  // MARK: - Playlist Relationship

  /// Playlist entries that include this video
  @Relationship(deleteRule: .cascade, inverse: \PlaylistEntry.video)
  var playlistEntries: [PlaylistEntry] = []

  /// Playlists containing this video
  var playlists: [Playlist] {
    playlistEntries.compactMap { $0.playlist }
  }

  // MARK: - Computed Download Properties

  /// Whether there is an active download in progress
  var hasActiveDownload: Bool {
    downloadState != nil
  }

  /// Whether a YouTube video has been downloaded for local playback.
  var isDownloaded: Bool {
    isYouTubeSource && hasLocalFile
  }

  /// Whether this item has media stored in the app's Documents directory.
  var hasLocalFile: Bool {
    downloadedFileName != nil
  }

  var downloadedFileURL: URL? {
    guard let fileName = downloadedFileName else { return nil }
    return URL.documentsDirectory.appendingPathComponent(fileName)
  }

  @Transient private var _cachedSubtitles: Subtitle?

  var cachedSubtitles: Subtitle? {
    get {
      if let cached = _cachedSubtitles {
        return cached
      }
      guard let data = transcriptData else { return nil }
      _cachedSubtitles = try? JSONDecoder().decode(Subtitle.self, from: data)
      return _cachedSubtitles
    }
    set {
      _cachedSubtitles = newValue
      transcriptData = newValue.flatMap { try? JSONEncoder().encode($0) }
    }
  }

  init(
    videoID: YouTubeContentID,
    url: String,
    title: String? = nil,
    author: String? = nil,
    thumbnailURL: String? = nil,
    source: VideoItemSource = .youtube,
    importedMediaKind: ImportedMediaKind? = nil
  ) {
    self.id = UUID()
    self._videoID = videoID.rawValue  // Store as primitive String
    self.url = url
    self.title = title
    self.author = author
    self.thumbnailURL = thumbnailURL
    self.timestamp = Date()
    self._sourceRawValue = source.rawValue
    self._importedMediaKindRawValue = importedMediaKind?.rawValue
  }
}
