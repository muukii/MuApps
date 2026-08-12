import Testing

@testable import Verse

@Suite("Video item media presentation")
struct VideoItemTests {
  @Test
  func audioOnlyPresentationIsDerivedFromImportedMediaKind() {
    let audioItem = VideoItem(
      videoID: "imported-audio",
      url: "audio.m4a",
      source: .importedFile,
      importedMediaKind: .audio
    )
    let videoItem = VideoItem(
      videoID: "imported-video",
      url: "video.mp4",
      source: .importedFile,
      importedMediaKind: .video
    )
    let youtubeItem = VideoItem(
      videoID: "youtube-video",
      url: "https://www.youtube.com/watch?v=youtube-video"
    )

    #expect(audioItem.isAudioOnly)
    #expect(videoItem.isAudioOnly == false)
    #expect(youtubeItem.isAudioOnly == false)
  }
}
