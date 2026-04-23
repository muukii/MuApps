//
//  URLInputSheet.swift
//  YouTubeSubtitle
//
//  Created by Hiroshi Kimura on 2025/12/04.
//

import SwiftUI
import AsyncMultiplexImage
import AsyncMultiplexImage_Nuke

struct URLInputSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var urlText: String = ""
  @State private var loadedMetadata: VideoMetadata?
  @State private var isLoadingMetadata: Bool = false
  @State private var currentVideoID: YouTubeContentID?
  @FocusState private var isTextFieldFocused: Bool

  let onSubmit: (String) -> Void

  var body: some View {

    VStack(spacing: 24) {
      VStack(alignment: .leading, spacing: 8) {
        Text("YouTube URL")
          .font(.subheadline)
          .foregroundStyle(.secondary)

        HStack(spacing: 8) {
          Image(systemName: "link")
            .foregroundStyle(.secondary)
            .font(.system(size: 16, weight: .medium))

          TextField("Paste YouTube URL", text: $urlText)
            .textContentType(.URL)
            #if os(iOS)
              .keyboardType(.URL)
              .autocapitalization(.none)
            #endif
            .focused($isTextFieldFocused)
            .onSubmit {
              submitURL()
            }

          if !urlText.isEmpty {
            Button {
              urlText = ""
            } label: {
              Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(Color.gray.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 12))
      }

      // Preview Section
      metadataPreviewView

      Button {
        submitURL()
      } label: {
        Text("Open Video")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(!canSubmit)

      Spacer()
    }
    .padding(20)
    .navigationTitle("Enter URL")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") {
          dismiss()
        }
      }
    }
    .onChange(of: urlText) { _, newValue in
      updateVideoID(from: newValue)
    }
    .task(id: currentVideoID) {
      await fetchMetadata()
    }
  }

  // MARK: - Preview View

  @ViewBuilder
  private var metadataPreviewView: some View {
    if isLoadingMetadata {
      HStack {
        ProgressView()
        Text("Loading...")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 16)
    } else if let metadata = loadedMetadata,
              metadata.title != nil || metadata.thumbnailURL != nil {
      HStack(spacing: 12) {
        // Thumbnail
        if let thumbnailURLString = metadata.thumbnailURL,
           let thumbnailURL = URL(string: thumbnailURLString) {
          AsyncMultiplexImageNuke(
            imageRepresentation: .remote(.init(constant: thumbnailURL))
          )
          .aspectRatio(contentMode: .fill)
          .frame(width: 100, height: 56)
          .clipShape(RoundedRectangle(cornerRadius: 8))
        }

        // Title
        VStack(alignment: .leading, spacing: 4) {
          if let title = metadata.title {
            Text(title)
              .font(.subheadline)
              .fontWeight(.medium)
              .lineLimit(2)
          }
          if let author = metadata.author {
            Text(author)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(12)
      .background(Color.gray.opacity(0.1))
      .clipShape(RoundedRectangle(cornerRadius: 12))
    }
  }

  // MARK: - Private Methods

  private func updateVideoID(from urlText: String) {
    guard let url = URL(string: urlText), !urlText.isEmpty else {
      currentVideoID = nil
      loadedMetadata = nil
      return
    }

    let videoID = YouTubeURLParser.extractVideoID(from: url)
    if videoID != currentVideoID {
      currentVideoID = videoID
      loadedMetadata = nil
    }
  }

  private func fetchMetadata() async {
    guard let videoID = currentVideoID else {
      isLoadingMetadata = false
      return
    }

    isLoadingMetadata = true
    let metadata = await VideoMetadataFetcher.fetch(videoID: videoID)

    // Check if task was not cancelled and videoID is still current
    guard currentVideoID == videoID else { return }

    loadedMetadata = metadata
    isLoadingMetadata = false
  }

  private var canSubmit: Bool {
    guard let metadata = loadedMetadata else { return false }
    return metadata.title != nil || metadata.thumbnailURL != nil
  }

  private var isValidURL: Bool {
    guard let url = URL(string: urlText), !urlText.isEmpty else {
      return false
    }
    return YouTubeURLParser.extractVideoID(from: url) != nil
  }

  private func submitURL() {
    guard canSubmit else { return }
    onSubmit(urlText)
    dismiss()
  }
}

#Preview {
  URLInputSheet { url in
    print("URL: \(url)")
  }
}
