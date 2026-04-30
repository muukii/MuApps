import SwiftData
import SwiftUI

struct ReaderView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(\.scenePhase) private var scenePhase

  let readingText: ReadingText

  @State private var viewModel = ReaderViewModel()

  var body: some View {
    Group {
      if viewModel.sentences.isEmpty {
        ContentUnavailableView {
          Label("No Sentences", systemImage: "text.page.badge.magnifyingglass")
        } description: {
          Text("This text does not contain readable sentences.")
        }
      } else {
        readerContent
      }
    }
    .navigationTitle(readingText.title)
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          viewModel.restart()
        } label: {
          Label("Restart", systemImage: "backward.end.fill")
        }
        .disabled(viewModel.sentences.isEmpty || viewModel.currentIndex == 0)
      }
    }
    .onAppear {
      viewModel.configure(readingText: readingText, modelContext: modelContext)
    }
    .onDisappear {
      viewModel.pause()
      viewModel.persistPosition()
    }
    .onChange(of: scenePhase) { _, newPhase in
      if newPhase != .active {
        viewModel.pause()
        viewModel.persistPosition()
      }
    }
  }

  private var readerContent: some View {
    VStack(spacing: 24) {
      VStack(spacing: 8) {
        HStack {
          Text(viewModel.positionText)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedDigit()

          Spacer()

          Text("\(Int(viewModel.wordsPerMinute)) WPM")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }

        ProgressView(value: viewModel.progress)
      }

      Spacer(minLength: 12)

      ScrollView {
        Text(viewModel.currentSentence)
          .font(.system(.largeTitle, design: .serif, weight: .regular))
          .lineSpacing(8)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 720)
          .padding(.horizontal, 24)
          .padding(.vertical, 36)
          .frame(maxWidth: .infinity)
      }

      Spacer(minLength: 12)

      VStack(spacing: 18) {
        playbackControls
        speedControl
      }
    }
    .padding(20)
  }

  private var playbackControls: some View {
    HStack(spacing: 28) {
      Button {
        viewModel.previous()
      } label: {
        Image(systemName: "backward.fill")
          .font(.title3)
          .frame(width: 52, height: 52)
      }
      .buttonStyle(.bordered)
      .disabled(!viewModel.canGoBackward)
      .help("Previous sentence")

      Button {
        viewModel.togglePlayback()
      } label: {
        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
          .font(.title2.weight(.semibold))
          .frame(width: 68, height: 68)
          .background(Circle().fill(Color.accentColor))
          .foregroundStyle(.white)
      }
      .buttonStyle(.plain)
      .help(viewModel.isPlaying ? "Pause" : "Play")

      Button {
        viewModel.next()
      } label: {
        Image(systemName: "forward.fill")
          .font(.title3)
          .frame(width: 52, height: 52)
      }
      .buttonStyle(.bordered)
      .disabled(!viewModel.canGoForward)
      .help("Next sentence")
    }
  }

  private var speedControl: some View {
    HStack(spacing: 14) {
      Image(systemName: "tortoise.fill")
        .foregroundStyle(.secondary)
        .frame(width: 24, height: 24)

      Slider(value: speedBinding, in: 80...400, step: 10)

      Image(systemName: "hare.fill")
        .foregroundStyle(.secondary)
        .frame(width: 24, height: 24)
    }
    .frame(maxWidth: 520)
  }

  private var speedBinding: Binding<Double> {
    Binding(
      get: { viewModel.wordsPerMinute },
      set: { newValue in
        viewModel.wordsPerMinute = newValue
        viewModel.rescheduleIfPlaying()
      }
    )
  }
}
