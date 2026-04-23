//
//  PlaybackControls.swift
//  YouTubeSubtitle
//
//  Created by Hiroshi Kimura on 2025/12/07.
//

import Components
import SwiftUI
import SwiftUIRingSlider
import TipKit

// MARK: - PlayerControls

struct PlayerControls: View {
  @Bindable var model: PlayerModel

  @State private var controlsMode: ControlsMode = .normal

  var body: some View {
    VStack(spacing: 0) {
      ProgressSectionWrapper(model: model)
        .padding(.horizontal, 20)
        .padding(.top, 12)

      PlaybackButtonsControl(model: model)
        .padding(.top, 8)

      ZStack {
        switch controlsMode {
        case .normal:
          NormalModeControls(
            model: model,
            onEnterRepeatMode: { controlsMode = .repeatSetup }
          )
          .transition(.opacity.combined(with: .scale(scale: 0.95)))

        case .repeatSetup:
          RepeatSetupControls(
            model: model,
            onDone: { controlsMode = .normal }
          )
          .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
      }
      .padding(.top, 8)
      .padding(.bottom, 16)
    }
    .animation(.smooth(duration: 0.3), value: controlsMode)

  }

  private struct ProgressSectionWrapper: View {
    let model: PlayerModel

    var body: some View {
      ProgressSection(
        currentTime: model.currentTime,
        displayTime: model.displayTime,
        duration: model.duration,
        onSeek: { model.seek(to: $0) }
      )
    }
  }

}

extension PlayerControls {

  // MARK: - ProgressSection

  struct ProgressSection: View {
    let currentTime: CurrentTime
    let displayTime: Double
    let duration: Double
    let onSeek: (Double) -> Void

    var body: some View {
      VStack(spacing: 4) {
        progressBar
        timeDisplay
      }
    }

    private var progressBar: some View {
      let normalizedValue = Binding<Double>(
        get: {
          guard duration > 0 else { return 0 }
          return currentTime.value / duration
        },
        set: { newValue in
          let clampedValue = max(0, min(1, newValue))
          let seekTime = clampedValue * duration
          onSeek(seekTime)
        }
      )

      return TouchSlider(
        direction: .horizontal,
        value: normalizedValue,
        speed: 0.5,
        foregroundColor: .red,
        backgroundColor: Color.gray.opacity(0.3)
      )
      .frame(height: 16)
    }

    private var timeDisplay: some View {
      HStack {
        Text(formatTime(displayTime))
          .font(.system(.caption, design: .default).monospacedDigit())
          .foregroundStyle(.secondary)

        Spacer()

        Text(formatTime(duration))
          .font(.system(.caption, design: .default).monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 4)
    }

    private func formatTime(_ seconds: Double) -> String {
      let totalSeconds = Int(seconds)
      let hours = totalSeconds / 3600
      let minutes = (totalSeconds % 3600) / 60
      let secs = totalSeconds % 60

      if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
      } else {
        return String(format: "%d:%02d", minutes, secs)
      }
    }
  }

  // MARK: - PlaybackButtonsControl

  struct PlaybackButtonsControl: View {
    let model: PlayerModel

    @AppStorage("backward2SeekMode") private var backward2SeekMode: BackwardSeekMode =
      .subtitle(.skip)
    @AppStorage("backward1SeekMode") private var backward1SeekMode: BackwardSeekMode =
      .seconds(.s3)
    @AppStorage("forward1SeekMode") private var forward1SeekMode: ForwardSeekMode =
      .seconds(.s3)
    @AppStorage("forward2SeekMode") private var forward2SeekMode: ForwardSeekMode =
      .subtitle
    @AppStorage("isStepModeEnabled") private var isStepModeEnabled: Bool = false

    // MARK: - BackwardJumpButton

    private struct BackwardJumpButton: View {
      let model: PlayerModel
      @Binding var mode: BackwardSeekMode

      var body: some View {
        Button {
          model.backward(how: mode)
        } label: {
          seekIcon(mode: mode)
        }
        .contextMenu {
          ForEach(BackwardSeekMode.allCases, id: \.self) { m in
            Button {
              mode = m
            } label: {
              HStack {
                Text(m.displayName)
                if m == mode {
                  Image(systemName: "checkmark")
                }
              }
            }
          }
        }
      }

      @ViewBuilder
      private func seekIcon(mode: BackwardSeekMode) -> some View {
        switch mode {
        case .subtitle(.skip):
          Image(systemName: "chevron.backward.2")
            .font(.system(size: 24))
            .foregroundStyle(.primary)
        case .subtitle(.current):
          Image(systemName: "backward.frame.fill")
            .font(.system(size: 24))
            .foregroundStyle(.primary)
        case .seconds(let s):
          SecondsIcon(prefix: "gobackward", seconds: s)
        }
      }
    }

    // MARK: - ForwardJumpButton

    private struct ForwardJumpButton: View {
      let model: PlayerModel
      @Binding var mode: ForwardSeekMode

      var body: some View {
        Button {
          model.forward(how: mode)
        } label: {
          seekIcon(mode: mode)
        }
        .contextMenu {
          ForEach(ForwardSeekMode.allCases, id: \.self) { m in
            Button {
              mode = m
            } label: {
              HStack {
                Text(m.displayName)
                if m == mode {
                  Image(systemName: "checkmark")
                }
              }
            }
          }
        }
      }

      @ViewBuilder
      private func seekIcon(mode: ForwardSeekMode) -> some View {
        switch mode {
        case .subtitle:
          Image(systemName: "forward.frame.fill")
            .font(.system(size: 24))
            .foregroundStyle(.primary)
        case .seconds(let s):
          SecondsIcon(prefix: "goforward", seconds: s)
        }
      }
    }

    // MARK: - PlayPauseButton

    private struct PlayPauseButton: View {
      let model: PlayerModel
      @Binding var isStepModeEnabled: Bool
      let onTap: () -> Void

      private var playIcon: String {
        if model.isPlaying {
          return isStepModeEnabled ? "pause" : "pause.fill"
        } else {
          return isStepModeEnabled ? "play" : "play.fill"
        }
      }

      var body: some View {
        Button {
          onTap()
        } label: {
          Image(systemName: playIcon)
            .font(.system(size: 32))
        }
        .popoverTip(StepModeTip())
        .contextMenu {
          Button {
            isStepModeEnabled = false
          } label: {
            HStack {
              Text("Normal")
              if !isStepModeEnabled {
                Image(systemName: "checkmark")
              }
            }
          }
          Button {
            isStepModeEnabled = true
          } label: {
            HStack {
              Text("Step Mode")
              if isStepModeEnabled {
                Image(systemName: "checkmark")
              }
            }
          }
        }
      }
    }

    // MARK: - SecondsIcon (shared)

    private struct SecondsIcon: View {
      let prefix: String
      let seconds: SeekSeconds

      var body: some View {
        let interval = Int(seconds.rawValue)
        let symbolName: String = {
          switch interval {
          case 5: return "\(prefix).5"
          case 10: return "\(prefix).10"
          case 15: return "\(prefix).15"
          case 30: return "\(prefix).30"
          case 45: return "\(prefix).45"
          case 60: return "\(prefix).60"
          default: return prefix
          }
        }()

        if interval == 3 || ![5, 10, 15, 30, 45, 60].contains(interval) {
          ZStack {
            Image(systemName: prefix)
              .font(.system(size: 24))
            Text("\(interval)")
              .font(.system(size: 8, weight: .bold))
              .offset(y: 1)
          }
          .foregroundStyle(.primary)
        } else {
          Image(systemName: symbolName)
            .font(.system(size: 24))
            .foregroundStyle(.primary)
        }
      }
    }

    var body: some View {
      ZStack {
        SpeedControls(
          playbackRate: model.playbackRate,
          onRateChange: { model.setPlaybackRate($0) }
        )
        .frame(maxWidth: .infinity, alignment: .leading)

        LoopControl(model: model)
          .frame(maxWidth: .infinity, alignment: .trailing)

        HStack(spacing: 16) {
          // Back buttons group
          HStack(spacing: 12) {
            BackwardJumpButton(model: model, mode: $backward2SeekMode)
            BackwardJumpButton(model: model, mode: $backward1SeekMode)
          }

          // Play/Pause button (context menu toggles step mode)
          PlayPauseButton(
            model: model,
            isStepModeEnabled: $isStepModeEnabled,
            onTap: { model.togglePlayPause() }
          )

          // Forward buttons group
          HStack(spacing: 12) {
            ForwardJumpButton(model: model, mode: $forward1SeekMode)
            ForwardJumpButton(model: model, mode: $forward2SeekMode)
          }
        }
        .tint(Color.primary)
      }
      .padding(.horizontal, 20)
      .onAppear {
        model.isStepModeEnabled = isStepModeEnabled
      }
      .onChange(of: isStepModeEnabled) { _, newValue in
        model.isStepModeEnabled = newValue
      }
    }

  }

  // MARK: - SpeedControls

  struct SpeedControls: View {
    let playbackRate: Double
    let onRateChange: (Double) -> Void

    private let availableRates: [Double] = [
      0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0,
    ]

    var body: some View {
      HStack(spacing: 8) {

        Menu {
          ForEach(availableRates, id: \.self) { rate in
            Button {
              onRateChange(rate)
            } label: {
              HStack {
                Text(formatRate(rate))
                if rate == playbackRate {
                  Image(systemName: "checkmark")
                }
              }
            }
          }
        } label: {
          HStack(alignment: .firstTextBaseline, spacing: -8) {
            Text("\(formatRate(playbackRate))")
              .font(.system(size: 17, weight: .bold, design: .rounded))
              .padding(.horizontal, 8)
              .padding(.vertical, 4)

            Text(Image.init(systemName: "multiply"))
              .font(.system(size: 11, weight: .bold, design: .rounded))
          }
          .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
      }
    }

    private func formatRate(_ rate: Double) -> String {
      if rate == 1.0 {
        return "1"
      } else if rate == floor(rate) {
        return String(format: "%.0f", rate)
      } else {
        return String(format: "%.2g", rate)
      }
    }
  }

  // MARK: - LoopControl

  struct LoopControl: View {
    let model: PlayerModel

    var body: some View {
      Button {
        model.toggleLoop()
      } label: {
        Image(systemName: "repeat")
          .font(.system(size: 24))
      }
      .buttonStyle(ToggleButtonStyle(isOn: model.isLoopingEnabled))

    }
  }

  // MARK: - ControlsMode

  enum ControlsMode {
    case normal
    case repeatSetup
  }

  // MARK: - RepeatEntryButton

  struct RepeatEntryButton: View {
    let isActive: Bool
    let hasRepeatPoints: Bool
    let onTap: () -> Void

    var body: some View {
      Button(action: onTap) {
        Image(systemName: "point.forward.to.point.capsulepath.fill")
      }
    }
  }

  // MARK: - RepeatSetupControls

  struct RepeatSetupControls: View {
    let model: PlayerModel
    let onDone: () -> Void

    @State private var startValue: Double?
    @State private var endValue: Double?

    var body: some View {
      // A-B RingSlider row
      HStack(spacing: 24) {
        RingSliderPointControl(
          labelImage: Image(systemName: "chevron.left.to.line"),
          value: $startValue,
          duration: model.duration,
          onSetToCurrent: { model.setRepeatStartToCurrent() },        
          onClear: { model.clearRepeatStart() }
        )

        // Done button in center
        Button(action: onDone) {
          Image(systemName: "chevron.down")
        }
        .frame(maxHeight: .infinity, alignment: .bottom)

        RingSliderPointControl(
          labelImage: Image(systemName: "chevron.right.to.line"),
          value: $endValue,
          duration: model.duration,
          onSetToCurrent: { model.setRepeatEndToCurrent() },
          onClear: { model.clearRepeatEnd() }
        )
      }
      .padding(.horizontal, 16)
      .onAppear {
        startValue = model.repeatStartTime
        endValue = model.repeatEndTime
      }
      .onChange(of: startValue) { _, newValue in
        // Ensure A < B: clamp start to not exceed end
        if let newValue, let end = endValue, newValue > end {
          startValue = end
        } else {
          model.repeatStartTime = newValue
        }
      }
      .onChange(of: endValue) { _, newValue in
        // Ensure A < B: clamp end to not go below start
        if let newValue, let start = startValue, newValue < start {
          endValue = start
        } else {
          model.repeatEndTime = newValue
        }
      }
      .onChange(of: model.repeatStartTime) { _, newValue in
        if newValue != startValue {
          startValue = newValue
        }
      }
      .onChange(of: model.repeatEndTime) { _, newValue in
        if newValue != endValue {
          endValue = newValue
        }
      }
    }

    // MARK: - RingSliderPointControl

    struct RingSliderPointControl: View {
      let labelImage: Image
      @Binding var value: Double?
      let duration: Double
      let onSetToCurrent: () -> Void
      let onClear: () -> Void

      private var isSet: Bool { value != nil }

      private var timeText: String {
        if let value {
          return formatTime(value)
        } else {
          return "--:--.---"
        }
      }

      private var ringBinding: Binding<Double> {
        Binding(
          get: { value ?? 0 },
          set: { value = $0 }
        )
      }

      var body: some View {
        VStack(spacing: 8) {

          //          labelImage

          Text(timeText)
            .font(.system(.caption, design: .rounded, weight: .medium))

          RingSlider(
            value: ringBinding,
            stride: 0.25,
            valueRange: 0...max(1, duration),
            primaryTickMark: {
              RoundedRectangle(cornerRadius: 8)
                .frame(width: 2)
                .foregroundStyle(.primary)
                .padding(.vertical, 10)
            },
            secondaryTickMark: {
              RoundedRectangle(cornerRadius: 8)
                .frame(width: 2)
                .foregroundStyle(.secondary)
                .padding(.vertical, 15)
            }
          )
          .frame(height: 60)
          .foregroundStyle(.primary)

          HStack(spacing: 8) {
           
            if isSet {
              Button {
                onClear()
              } label: {
                Image(systemName: "xmark")
              }
              .tint(.red)
              .buttonStyle(.bordered)
            } else {
              Button {
                onSetToCurrent()
              } label: {
                Image(systemName: "pin")
              }
              .tint(.secondary)
            }
          }
        }
        .padding(.vertical, 8)
      }

      private func formatTime(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        let millis = Int((seconds - Double(totalSeconds)) * 1000)

        if hours > 0 {
          return String(
            format: "%d:%02d:%02d.%03d",
            hours,
            minutes,
            secs,
            millis
          )
        } else {
          return String(format: "%d:%02d.%03d", minutes, secs, millis)
        }
      }
    }

  }

  // MARK: - NormalModeControls

  struct NormalModeControls: View {
    let model: PlayerModel
    let onEnterRepeatMode: () -> Void

    var body: some View {
      HStack(spacing: 24) {

        RepeatEntryButton(
          isActive: model.isLoopingEnabled && model.canRepeat,
          hasRepeatPoints: model.repeatStartTime != nil
            || model.repeatEndTime != nil,
          onTap: onEnterRepeatMode
        )
      }
    }
  }

}

#if DEBUG

  import SwiftData
  #Preview {
    let container = try! ModelContainer(
      for: VideoItem.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let downloadManager = DownloadManager(modelContainer: container)
    let historyService = VideoItemService(
      modelContext: container.mainContext,
      downloadManager: downloadManager
    )

    let item = VideoItem(
      videoID: "oRc4sndVaWo",
      url: "https://www.youtube.com/watch?v=oRc4sndVaWo",
      title: "Preview Video"
    )

    return NavigationStack {
      PlayerView(videoItem: item)
    }
    .modelContainer(container)
    .environment(downloadManager)
    .environment(historyService)
  }

#endif
