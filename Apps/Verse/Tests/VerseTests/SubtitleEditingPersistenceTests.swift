import Foundation
import SwiftData
import Testing

@testable import Verse

@Suite("Subtitle edit persistence")
@MainActor
struct SubtitleEditingPersistenceTests {
  @Test
  func editedTranscriptPersistsAndMergedBookmarksAreDeduplicated() throws {
    let container = try ModelContainer(
      for: VideoItem.self,
      DownloadStateEntity.self,
      TranscriptionSession.self,
      TranscriptionEntry.self,
      Playlist.self,
      PlaylistEntry.self,
      SubtitleBookmark.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let context = container.mainContext
    let downloadManager = DownloadManager(modelContainer: container)
    let service = VideoItemService(
      modelContext: context,
      downloadManager: downloadManager
    )

    let firstCue = Subtitle.Cue(
      id: 1,
      startTime: 0,
      endTime: 2,
      text: "First"
    )
    let secondCue = Subtitle.Cue(
      id: 2,
      startTime: 2,
      endTime: 4,
      text: "Second"
    )
    let item = VideoItem(
      videoID: "subtitle-edit-test",
      url: "https://example.com/video"
    )
    item.cachedSubtitles = Subtitle([firstCue, secondCue])
    context.insert(item)

    let firstBookmark = SubtitleBookmark(cue: firstCue, video: item)
    let secondBookmark = SubtitleBookmark(cue: secondCue, video: item)
    item.subtitleBookmarks = [firstBookmark, secondBookmark]
    context.insert(firstBookmark)
    context.insert(secondBookmark)
    try context.save()

    let edited = try SubtitleEditor.merge(
      try #require(item.cachedSubtitles),
      cueID: firstCue.id,
      direction: .next,
      editedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    try service.updateEditedSubtitles(video: item, subtitles: edited)

    let verificationContext = ModelContext(container)
    let videoIDRaw = item.videoID.rawValue
    let descriptor = FetchDescriptor<VideoItem>(
      predicate: #Predicate { $0._videoID == videoIDRaw }
    )
    let persistedItem = try #require(verificationContext.fetch(descriptor).first)
    let persistedBookmark = try #require(persistedItem.subtitleBookmarks.first)

    #expect(persistedItem.cachedSubtitles == edited)
    #expect(persistedItem.subtitleBookmarks.count == 1)
    #expect(persistedBookmark.startTime == 0)
    #expect(persistedBookmark.endTime == 4)
    #expect(persistedBookmark.text == "First Second")
  }
}
