//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import AVFoundation
import CoreTransferable
import Foundation

/// A video the user picked, backed by a local file the app owns.
struct VideoSource: Identifiable, Equatable {
  let id = UUID()
  let url: URL
  let asset: AVURLAsset

  init(url: URL) {
    self.url = url
    self.asset = AVURLAsset(url: url)
  }

  static func == (lhs: VideoSource, rhs: VideoSource) -> Bool {
    lhs.url == rhs.url
  }
}

/// Transferable wrapper so `PhotosPicker` can hand us a stable local file.
struct PickedMovie: Transferable {
  let url: URL

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(contentType: .movie) { movie in
      SentTransferredFile(movie.url)
    } importing: { received in
      let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PickedVideos", isDirectory: true)
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let destination = directory.appendingPathComponent(
        UUID().uuidString + "-" + received.file.lastPathComponent
      )
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.copyItem(at: received.file, to: destination)
      return PickedMovie(url: destination)
    }
  }
}
