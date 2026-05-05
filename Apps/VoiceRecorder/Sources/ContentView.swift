import MuDesignSystem
import AVFoundation
import SwiftUI
import UIKit

struct ContentView: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var viewModel = VoiceRecorderViewModel()

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 18) {
          appHeader
          AlertStack(viewModel: viewModel, openSettings: openSettings)
          StudioConsole(viewModel: viewModel)
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
      }
      .background(pageBackground)
      .navigationTitle("")
      .navigationBarTitleDisplayMode(.inline)
      .task {
        await viewModel.prepare()
      }
      .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
        viewModel.refreshAudioInputs()
      }
      .onChange(of: scenePhase) { _, newPhase in
        if newPhase == .background {
          viewModel.stopAll()
        }
      }
    }
  }

  private var pageBackground: some View {
    LinearGradient(
      colors: [
        Color(.systemBackground),
        Color(.secondarySystemBackground),
      ],
      startPoint: .top,
      endPoint: .bottom
    )
    .ignoresSafeArea()
  }

  private var appHeader: some View {
    HStack(spacing: 12) {
      Image(systemName: "waveform")
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 42, height: 42)
        .background(MuColors.primary, in: Circle())

      VStack(alignment: .leading, spacing: 2) {
        Text("Voice Recorder")
          .font(.system(size: 28, weight: .bold, design: .rounded))
          .lineLimit(1)
          .minimumScaleFactor(0.8)
        Text("Live input. Adjustable delay. No clips saved.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 0)
    }
  }

  private func openSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }
}

private struct AlertStack: View {
  let viewModel: VoiceRecorderViewModel
  let openSettings: () -> Void

  var body: some View {
    if let errorMessage = viewModel.errorMessage {
      StatusBanner(errorMessage, systemImage: "exclamationmark.triangle.fill", tint: .red)
    }

    if viewModel.isPermissionDenied {
      VStack(alignment: .leading, spacing: 12) {
        StatusBanner("Microphone permission is required.", systemImage: "mic.slash.fill", tint: .red)

        Button {
          openSettings()
        } label: {
          Label("Open Settings", systemImage: "gear")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
      }
    }
  }
}

private struct StudioConsole: View {
  let viewModel: VoiceRecorderViewModel

  var body: some View {
    VStack(spacing: 20) {
      ConsoleStatus(viewModel: viewModel)
      StreamingDeck(viewModel: viewModel)

      Divider()

      TranscriptionDeck(viewModel: viewModel)

      Divider()

      MicrophoneDeck(viewModel: viewModel)

      Divider()

      DelayDeck(viewModel: viewModel)
    }
    .padding(18)
    .frame(maxWidth: .infinity)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    )
  }
}

private struct ConsoleStatus: View {
  let viewModel: VoiceRecorderViewModel

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: statusIcon)
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(statusColor)
        .frame(width: 42, height: 42)
        .background(statusColor.opacity(0.12), in: Circle())

      VStack(alignment: .leading, spacing: 3) {
        Text(statusTitle)
          .font(.headline)
        Text(statusSubtitle)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 0)

      Text(viewModel.outputRouteName)
        .font(.caption)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }
  }
}

private struct StreamingDeck: View {
  let viewModel: VoiceRecorderViewModel

  var body: some View {
    VStack(spacing: 18) {
      StreamDurationHeader(viewModel: viewModel)
      LiveInputLevelMeter(viewModel: viewModel)
      StreamControlButton(viewModel: viewModel)
    }
  }
}

private struct StreamDurationHeader: View {
  let viewModel: VoiceRecorderViewModel

  var body: some View {
    VStack(spacing: 4) {
      Text(viewModel.isStreaming ? "Streaming" : "Ready")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(statusColor)
      Text(viewModel.streamDurationText)
        .font(.system(size: 58, weight: .bold, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.72)
    }
  }
}

private struct LiveInputLevelMeter: View {
  let viewModel: VoiceRecorderViewModel

  var body: some View {
    LevelMeter(
      level: viewModel.audioLevel,
      isActive: viewModel.isStreaming,
      tint: statusColor
    )
  }
}

private struct StreamControlButton: View {
  let viewModel: VoiceRecorderViewModel

  var body: some View {
    HStack(spacing: 18) {
      Spacer(minLength: 0)

      Button {
        Task {
          await viewModel.toggleStreaming()
        }
      } label: {
        ZStack {
          Circle()
            .stroke(statusColor.opacity(0.18), lineWidth: 16)
          Circle()
            .fill(statusColor)
            .shadow(color: statusColor.opacity(0.28), radius: 18, x: 0, y: 10)
          Image(systemName: viewModel.isStreaming ? "stop.fill" : "dot.radiowaves.left.and.right")
            .font(.system(size: 38, weight: .bold))
            .foregroundStyle(.white)
        }
        .frame(width: 116, height: 116)
      }
      .buttonStyle(.plain)
      .disabled(viewModel.isPermissionDenied)
      .accessibilityLabel(viewModel.isStreaming ? "Stop Streaming" : "Start Streaming")

      Spacer(minLength: 0)
    }
  }
}

private struct TranscriptionDeck: View {
  let viewModel: VoiceRecorderViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      DeckHeader("Transcript", systemImage: "text.bubble.fill", detail: viewModel.transcriptionStatus.displayText)

      if viewModel.transcriptItems.isEmpty {
        ZStack(alignment: .bottomLeading) {
          Text(viewModel.transcriptionStatus.detailText)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .bottomLeading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      } else {
        ZStack(alignment: .bottomLeading) {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(viewModel.transcriptItems.suffix(4)) { item in
              DissolvingTranscriptText(item: item)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .bottomLeading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
    }
  }
}

private struct MicrophoneDeck: View {
  let viewModel: VoiceRecorderViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      DeckHeader("Input", systemImage: "mic.fill", detail: viewModel.selectedInputName)

      Picker("Input", selection: inputSelection) {
        ForEach(viewModel.inputDevices) { device in
          Label(device.name, systemImage: device.isBluetooth ? "airpodspro" : "iphone")
            .tag(device.id)
        }
      }
      .pickerStyle(.menu)
      .disabled(viewModel.canSelectInput == false || viewModel.inputDevices.isEmpty)

      if viewModel.inputDevices.isEmpty {
        Text("Connect a microphone or grant microphone access.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      } else {
        RouteRow(title: "Active Input", value: viewModel.activeInputName)
        RouteRow(title: "Output", value: viewModel.outputRouteName)
      }
    }
  }
}

private struct DelayDeck: View {
  let viewModel: VoiceRecorderViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      DeckHeader("Delay", systemImage: "ear.fill", detail: String(format: "%.2fs", viewModel.monitorDelay))

      Slider(value: monitorDelayBinding, in: 0.15...2.0, step: 0.05)

      if viewModel.isHeadphoneOutput == false {
        StatusBanner(
          "Connect headphones or AirPods before streaming to avoid speaker feedback.",
          systemImage: "headphones",
          tint: .orange
        )
      } else {
        Label("Live stream uses the selected input and current headphone route.", systemImage: "info.circle")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private extension MicrophoneDeck {
  private var inputSelection: Binding<String> {
    Binding(
      get: { viewModel.selectedInputID },
      set: { viewModel.selectInput(id: $0) }
    )
  }
}

private extension DelayDeck {
  private var monitorDelayBinding: Binding<Double> {
    Binding(
      get: { viewModel.monitorDelay },
      set: { viewModel.monitorDelay = $0 }
    )
  }
}

private extension ConsoleStatus {
  private var statusTitle: String {
    if viewModel.isStreaming {
      return "Streaming"
    }

    return "Ready"
  }

  private var statusSubtitle: String {
    if viewModel.isPermissionDenied {
      return "Microphone permission is required."
    }

    if viewModel.isStreaming {
      return "Live input is flowing through the delay chain."
    }

    return "Select an input and start the live stream."
  }

  private var statusIcon: String {
    if viewModel.isStreaming {
      return "waveform.circle.fill"
    }

    return "waveform"
  }

  private var statusColor: Color {
    if viewModel.isStreaming {
      return .green
    }

    return MuColors.primary
  }
}

private extension StreamDurationHeader {
  private var statusColor: Color {
    streamStatusColor(isStreaming: viewModel.isStreaming)
  }
}

private extension LiveInputLevelMeter {
  private var statusColor: Color {
    streamStatusColor(isStreaming: viewModel.isStreaming)
  }
}

private extension StreamControlButton {
  private var statusColor: Color {
    streamStatusColor(isStreaming: viewModel.isStreaming)
  }
}

private struct DeckHeader: View {
  let title: String
  let systemImage: String
  let detail: String

  init(_ title: String, systemImage: String, detail: String) {
    self.title = title
    self.systemImage = systemImage
    self.detail = detail
  }

  var body: some View {
    HStack(spacing: 10) {
      Label(title, systemImage: systemImage)
        .font(.headline)

      Spacer(minLength: 0)

      Text(detail)
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
    }
  }
}

private struct StatusBanner: View {
  let text: String
  let systemImage: String
  let tint: Color

  init(_ text: String, systemImage: String, tint: Color) {
    self.text = text
    self.systemImage = systemImage
    self.tint = tint
  }

  var body: some View {
    Label(text, systemImage: systemImage)
      .font(.footnote)
      .foregroundStyle(tint)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

private struct RouteRow: View {
  let title: String
  let value: String

  var body: some View {
    HStack {
      Text(title)
        .foregroundStyle(.secondary)
      Spacer(minLength: 12)
      Text(value)
        .multilineTextAlignment(.trailing)
    }
    .font(.footnote)
  }
}

private func streamStatusColor(isStreaming: Bool) -> Color {
  if isStreaming {
    return .green
  }

  return MuColors.primary
}

private struct LevelMeter: View {
  let level: Float
  let isActive: Bool
  let tint: Color

  private let barCount = 26

  var body: some View {
    HStack(alignment: .center, spacing: 4) {
      ForEach(0..<barCount, id: \.self) { index in
        Capsule()
          .fill(barFill(for: index))
          .frame(maxWidth: .infinity)
          .frame(height: barHeight(for: index))
      }
    }
    .frame(height: 54)
    .padding(.horizontal, 2)
  }

  private func barFill(for index: Int) -> Color {
    guard isActive else {
      return Color.secondary.opacity(0.22)
    }

    let threshold = Float(index + 1) / Float(barCount)
    return threshold <= max(level, 0.08) ? tint : tint.opacity(0.18)
  }

  private func barHeight(for index: Int) -> CGFloat {
    let progress = CGFloat(index) / CGFloat(max(barCount - 1, 1))
    let envelope = 0.35 + (sin(progress * .pi * 3.6) + 1) * 0.24
    let activity = CGFloat(isActive ? max(level, 0.12) : 0.18)
    return 10 + (44 * min(max(envelope * activity + 0.18, 0.16), 1))
  }
}

private struct DissolvingTranscriptText: View {
  let item: LiveTranscriptItem
  @State private var isDissolving = false

  var body: some View {
    Group {
      if isDissolving {
        TimelineView(.animation) { context in
          dissolvingText(now: context.date)
        }
      } else {
        transcriptText
          .accessibilityLabel(item.text)
      }
    }
    .task(id: item.id) {
      await waitForDissolve()
    }
  }

  private func dissolvingText(now: Date) -> some View {
    let progress = item.dissolveProgress(now: now)
    let elapsed = Float(now.timeIntervalSince(item.createdAt))

    return transcriptText
      .visualEffect { content, geometry in
        content
          .layerEffect(
            ShaderLibrary.smokeDissolve(
              .float(Float(progress)),
              .float(elapsed),
              .float2(Float(geometry.size.width), Float(geometry.size.height))
            ),
            maxSampleOffset: CGSize(width: 24, height: 36)
          )
      }
      .opacity(1 - (progress * 0.18))
      .animation(.easeOut(duration: 0.25), value: progress)
      .accessibilityLabel(item.text)
  }

  private func waitForDissolve() async {
    let now = Date()
    guard item.dissolveProgress(now: now) <= 0.01 else {
      isDissolving = true
      return
    }

    let lifetime = max(item.expiresAt.timeIntervalSince(item.createdAt), 0.1)
    let dissolveStart = item.createdAt.addingTimeInterval(lifetime * 0.48)
    let delay = max(dissolveStart.timeIntervalSince(now), 0)
    try? await Task.sleep(for: .milliseconds(Int(delay * 1_000)))

    guard Task.isCancelled == false else { return }
    isDissolving = true
  }

  private var transcriptText: some View {
    Text(item.text)
      .font(.system(.title3, design: .rounded, weight: .semibold))
      .lineLimit(3)
      .multilineTextAlignment(.leading)
      .padding(.vertical, 10)
      .padding(.horizontal, 3)
  }
}

#Preview {
  ContentView()
}
