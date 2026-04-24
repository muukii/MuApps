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
        VStack(alignment: .leading, spacing: 24) {
          statusHeader
          microphoneSection
          recordingSection
          playbackSection
          monitorSection
        }
        .padding(20)
      }
      .background(MuColors.background)
      .navigationTitle("Voice Recorder")
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

  private var statusHeader: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        Image(systemName: statusIcon)
          .font(.system(size: 28, weight: .semibold))
          .foregroundStyle(statusColor)
          .frame(width: 38, height: 38)

        VStack(alignment: .leading, spacing: 3) {
          Text(statusTitle)
            .font(MuFonts.title())
          Text(statusSubtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }

        Spacer(minLength: 0)
      }

      if let errorMessage = viewModel.errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.footnote)
          .foregroundStyle(.red)
      }

      if viewModel.isPermissionDenied {
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

  private var microphoneSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionTitle("Microphone", systemImage: "mic")

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
        routeRow(title: "Selected", value: viewModel.selectedInputName)
        routeRow(title: "Active Input", value: viewModel.activeInputName)
        routeRow(title: "Output", value: viewModel.outputRouteName)
      }
    }
    .sectionSurface()
  }

  private var recordingSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      sectionTitle("Record", systemImage: "record.circle")

      HStack(spacing: 20) {
        Button {
          Task {
            await viewModel.toggleRecording()
          }
        } label: {
          ZStack {
            Circle()
              .fill(viewModel.isRecording ? Color.red : MuColors.primary)
            Image(systemName: viewModel.isRecording ? "stop.fill" : "mic.fill")
              .font(.system(size: 34, weight: .bold))
              .foregroundStyle(.white)
          }
          .frame(width: 88, height: 88)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isPermissionDenied)

        VStack(alignment: .leading, spacing: 8) {
          Text(viewModel.isRecording ? "Recording" : "Ready")
            .font(.headline)
          Text(viewModel.recordingDurationText)
            .font(.system(size: 36, weight: .bold, design: .rounded))
            .monospacedDigit()

          GeometryReader { proxy in
            ZStack(alignment: .leading) {
              Capsule()
                .fill(Color.secondary.opacity(0.18))
              Capsule()
                .fill(viewModel.isRecording ? Color.red : MuColors.primary)
                .frame(width: max(proxy.size.width * CGFloat(viewModel.audioLevel), 4))
            }
          }
          .frame(height: 8)
        }
      }
    }
    .sectionSurface()
  }

  private var playbackSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      sectionTitle("Playback", systemImage: "play.circle")

      HStack(spacing: 12) {
        Button {
          viewModel.togglePlayback()
        } label: {
          Label(viewModel.isPlaying ? "Stop" : "Play", systemImage: viewModel.isPlaying ? "stop.fill" : "play.fill")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(viewModel.hasRecording == false || viewModel.isRecording)

        Text(viewModel.hasRecording ? viewModel.lastRecordingDurationText : "--:--")
          .font(.system(.title3, design: .rounded, weight: .semibold))
          .monospacedDigit()
          .foregroundStyle(viewModel.hasRecording ? .primary : .secondary)
      }

      ProgressView(value: viewModel.playbackProgress)
        .opacity(viewModel.hasRecording ? 1 : 0.35)
    }
    .sectionSurface()
  }

  private var monitorSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      sectionTitle("Delay Monitor", systemImage: "ear")

      HStack {
        Text("Delay")
        Spacer()
        Text(String(format: "%.2fs", viewModel.monitorDelay))
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }

      Slider(value: monitorDelayBinding, in: 0.15...2.0, step: 0.05)

      Button {
        Task {
          await viewModel.toggleMonitoring()
        }
      } label: {
        Label(
          viewModel.isMonitoring ? "Stop Monitor" : "Start Monitor",
          systemImage: viewModel.isMonitoring ? "stop.fill" : "ear.and.waveform"
        )
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .disabled(viewModel.isRecording || viewModel.isPermissionDenied)

      Label("Monitor mode uses Device Microphone and sends the delayed signal to the current headphone route.", systemImage: "info.circle")
        .font(.footnote)
        .foregroundStyle(.secondary)

      if viewModel.isHeadphoneOutput == false {
        Label("Connect headphones or AirPods before monitoring to avoid speaker feedback.", systemImage: "headphones")
          .font(.footnote)
          .foregroundStyle(.orange)
      }
    }
    .sectionSurface()
  }

  private var inputSelection: Binding<String> {
    Binding(
      get: { viewModel.selectedInputID },
      set: { viewModel.selectInput(id: $0) }
    )
  }

  private var monitorDelayBinding: Binding<Double> {
    Binding(
      get: { viewModel.monitorDelay },
      set: { viewModel.monitorDelay = $0 }
    )
  }

  private var statusTitle: String {
    if viewModel.isRecording {
      return "Recording"
    }

    if viewModel.isPlaying {
      return "Playing"
    }

    if viewModel.isMonitoring {
      return "Monitoring"
    }

    return "Ready"
  }

  private var statusSubtitle: String {
    if viewModel.isPermissionDenied {
      return "Microphone permission is required."
    }

    if viewModel.isMonitoring {
      return "Device microphone is forced in delay mode."
    }

    if viewModel.hasRecording {
      return "Last clip is ready to play."
    }

    return "Select a microphone and record a clip."
  }

  private var statusIcon: String {
    if viewModel.isRecording {
      return "record.circle.fill"
    }

    if viewModel.isPlaying {
      return "play.circle.fill"
    }

    if viewModel.isMonitoring {
      return "ear.fill"
    }

    return "waveform"
  }

  private var statusColor: Color {
    if viewModel.isRecording {
      return .red
    }

    if viewModel.isMonitoring {
      return .orange
    }

    return MuColors.primary
  }

  private func sectionTitle(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
      .font(.headline)
  }

  private func routeRow(title: String, value: String) -> some View {
    HStack {
      Text(title)
        .foregroundStyle(.secondary)
      Spacer(minLength: 12)
      Text(value)
        .multilineTextAlignment(.trailing)
    }
    .font(.footnote)
  }

  private func openSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }
}

private extension View {
  func sectionSurface() -> some View {
    self
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

#Preview {
  ContentView()
}
