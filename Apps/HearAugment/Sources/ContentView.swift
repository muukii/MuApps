import MuDesignSystem
import AVFoundation
import SwiftUI
import UIKit

struct ContentView: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var viewModel = HearAugmentViewModel()

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          ListeningPanel(viewModel: viewModel)
          PresetGrid(viewModel: viewModel)
          EffectChainPanel(viewModel: viewModel)
          TuningPanel(viewModel: viewModel)
          BufferPanel(viewModel: viewModel)
          InputPanel(viewModel: viewModel)
          SafetyPanel()
        }
        .padding(20)
      }
      .background(MuColors.background)
      .navigationTitle("Hear Augment")
      .task {
        await viewModel.prepare()
      }
      .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
        viewModel.refreshAudioRoute()
      }
      .onChange(of: scenePhase) { _, newPhase in
        if newPhase == .background {
          viewModel.stopListening()
        }
      }
    }
  }
}

private struct ListeningPanel: View {
  let viewModel: HearAugmentViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .center, spacing: 14) {
        ZStack {
          Circle()
            .fill(statusColor.opacity(0.16))
          Image(systemName: statusIcon)
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(statusColor)
        }
        .frame(width: 54, height: 54)

        VStack(alignment: .leading, spacing: 4) {
          Text(statusTitle)
            .font(MuFonts.title())
            .minimumScaleFactor(0.8)
          Text(viewModel.selectedChainTitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Text(viewModel.selectedChainSubtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer(minLength: 8)

        Text(viewModel.elapsedTimeText)
          .font(.system(.title2, design: .rounded, weight: .semibold))
          .monospacedDigit()
      }

      Button {
        Task {
          await viewModel.toggleListening()
        }
      } label: {
        Label(
          viewModel.isListening ? "Stop Listening" : "Start Listening",
          systemImage: viewModel.isListening ? "stop.fill" : "ear.and.waveform"
        )
        .frame(maxWidth: .infinity, minHeight: 48)
      }
      .buttonStyle(.borderedProminent)
      .disabled(viewModel.isPermissionDenied)

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
        .buttonStyle(.bordered)
      }

      if viewModel.isHeadphoneOutput == false {
        Label("Connect headphones before listening to reduce feedback risk.", systemImage: "headphones")
          .font(.footnote)
          .foregroundStyle(.orange)
      }
    }
    .sectionSurface()
  }

  private var statusTitle: String {
    if viewModel.isListening {
      return "Listening"
    }

    if viewModel.isPermissionDenied {
      return "Microphone Needed"
    }

    return "Ready"
  }

  private var statusIcon: String {
    if viewModel.isListening {
      return "ear.fill"
    }

    if viewModel.isPermissionDenied {
      return "mic.slash.fill"
    }

    return "waveform"
  }

  private var statusColor: Color {
    if viewModel.isPermissionDenied {
      return .red
    }

    if let accentName = viewModel.selectedPreset?.accentName {
      return hearAugmentColor(for: accentName)
    }

    return MuColors.primary
  }

  private func openSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }
}

private struct PresetGrid: View {
  let viewModel: HearAugmentViewModel

  private let columns = [
    GridItem(.flexible(), spacing: 12),
    GridItem(.flexible(), spacing: 12),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionTitle("Presets", systemImage: "square.grid.2x2")

      LazyVGrid(columns: columns, spacing: 12) {
        ForEach(viewModel.allPresets) { preset in
          PresetButton(viewModel: viewModel, preset: preset)
        }
      }
    }
  }
}

private struct PresetButton: View {
  let viewModel: HearAugmentViewModel
  let preset: AudioEffectChainPreset

  var body: some View {
    let isSelected = viewModel.selectedPresetID == preset.id
    let tint = hearAugmentColor(for: preset.accentName)

    Button {
      viewModel.selectPreset(id: preset.id)
    } label: {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Image(systemName: preset.symbolName)
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(isSelected ? tint : .secondary)
            .frame(width: 24, height: 24)

          Spacer(minLength: 0)

          if isSelected {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(tint)
          }
        }

        VStack(alignment: .leading, spacing: 3) {
          Text(preset.name)
            .font(.headline)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
          Text(preset.subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
        }
      }
      .padding(14)
      .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
      .background(
        isSelected ? tint.opacity(0.14) : Color.secondary.opacity(0.08),
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(isSelected ? tint.opacity(0.65) : Color.secondary.opacity(0.12), lineWidth: 1)
      }
    }
    .buttonStyle(.plain)
    .contextMenu {
      if preset.kind == .custom {
        Button(role: .destructive) {
          viewModel.deleteCustomPreset(id: preset.id)
        } label: {
          Label("Delete", systemImage: "trash")
        }
      }
    }
  }
}

private struct EffectChainPanel: View {
  let viewModel: HearAugmentViewModel
  @State private var customPresetName = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        sectionTitle("Effect Chain", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
        Spacer()
        Menu {
          ForEach(AudioEffectType.allCases) { type in
            Button {
              viewModel.addEffect(type)
            } label: {
              Label(type.title, systemImage: type.symbolName)
            }
          }
        } label: {
          Label("Add", systemImage: "plus")
        }
        .buttonStyle(.bordered)
        .disabled(viewModel.canAddEffect == false)
      }

      if viewModel.effectChain.isEmpty {
        Text("Bypass")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 10)
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(viewModel.effectChain.enumerated()), id: \.element.id) { index, node in
            EffectRow(viewModel: viewModel, node: node, index: index)

            if index < viewModel.effectChain.count - 1 {
              Divider()
            }
          }
        }
      }

      HStack(spacing: 10) {
        TextField("Preset Name", text: $customPresetName)
          .textFieldStyle(.roundedBorder)
          .submitLabel(.done)

        Button {
          viewModel.saveCurrentChain(named: customPresetName)
          customPresetName = ""
        } label: {
          Label("Save", systemImage: "tray.and.arrow.down")
        }
        .buttonStyle(.bordered)
        .disabled(viewModel.effectChain.isEmpty)
      }
    }
    .sectionSurface()
  }
}

private struct EffectRow: View {
  let viewModel: HearAugmentViewModel
  let node: AudioEffectNode
  let index: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        Image(systemName: node.type.symbolName)
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(rowTint)
          .frame(width: 24, height: 24)

        VStack(alignment: .leading, spacing: 2) {
          Text(node.type.title)
            .font(.headline)
          Text(node.type.subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer(minLength: 8)

        Toggle("", isOn: enabledBinding)
          .labelsHidden()

        iconButton("chevron.up", "Move Up") {
          viewModel.moveEffect(id: node.id, offset: -1)
        }
        .disabled(index == 0)

        iconButton("chevron.down", "Move Down") {
          viewModel.moveEffect(id: node.id, offset: 1)
        }
        .disabled(index >= viewModel.effectChain.count - 1)

        iconButton("trash", "Remove") {
          viewModel.removeEffect(id: node.id)
        }
      }

      parameterSlider(
        title: "Amount",
        value: doubleBinding(\.amount),
        displayValue: percentText(node.amount)
      )

      parameterSlider(
        title: node.type.parameterAName,
        value: doubleBinding(\.parameterA),
        displayValue: percentText(node.parameterA)
      )

      parameterSlider(
        title: node.type.parameterBName,
        value: doubleBinding(\.parameterB),
        displayValue: percentText(node.parameterB)
      )
    }
    .padding(.vertical, 14)
  }

  private var rowTint: Color {
    if let accentName = viewModel.selectedPreset?.accentName {
      return hearAugmentColor(for: accentName)
    }

    return MuColors.primary
  }

  private var enabledBinding: Binding<Bool> {
    Binding {
      viewModel.effectChain.first(where: { $0.id == node.id })?.isEnabled ?? false
    } set: { value in
      guard var updatedNode = viewModel.effectChain.first(where: { $0.id == node.id }) else { return }
      updatedNode.isEnabled = value
      viewModel.replaceEffect(updatedNode)
    }
  }

  private func doubleBinding(_ keyPath: WritableKeyPath<AudioEffectNode, Double>) -> Binding<Double> {
    Binding {
      viewModel.effectChain.first(where: { $0.id == node.id })?[keyPath: keyPath] ?? 0
    } set: { value in
      guard var updatedNode = viewModel.effectChain.first(where: { $0.id == node.id }) else { return }
      updatedNode[keyPath: keyPath] = value
      viewModel.replaceEffect(updatedNode)
    }
  }

  private func parameterSlider(
    title: String,
    value: Binding<Double>,
    displayValue: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(title)
        Spacer()
        Text(displayValue)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      .font(.caption)

      Slider(value: value, in: 0...1)
    }
  }

  private func iconButton(
    _ systemImage: String,
    _ accessibilityLabel: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 15, weight: .semibold))
        .frame(width: 30, height: 30)
    }
    .buttonStyle(.borderless)
    .accessibilityLabel(accessibilityLabel)
  }
}

private struct TuningPanel: View {
  let viewModel: HearAugmentViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      sectionTitle("Tuning", systemImage: "dial.medium")

      sliderRow(
        title: "Chain Intensity",
        value: intensityBinding,
        range: 0...1,
        displayValue: "\(Int((viewModel.intensity * 100).rounded()))%"
      )

      sliderRow(
        title: "Output",
        value: outputBinding,
        range: 0.2...1.2,
        displayValue: "\(Int((viewModel.outputLevel * 100).rounded()))%"
      )
    }
    .sectionSurface()
  }

  private var intensityBinding: Binding<Double> {
    Binding(
      get: { viewModel.intensity },
      set: { viewModel.intensity = $0 }
    )
  }

  private var outputBinding: Binding<Double> {
    Binding(
      get: { viewModel.outputLevel },
      set: { viewModel.outputLevel = $0 }
    )
  }
}

private struct BufferPanel: View {
  let viewModel: HearAugmentViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionTitle("Buffer", systemImage: "memorychip")

      Picker("Buffer", selection: bufferSizeSelection) {
        ForEach(AudioBufferSizeOption.allCases) { option in
          Text(option.title)
            .tag(option)
        }
      }
      .pickerStyle(.segmented)
      .disabled(viewModel.canSelectAudioBufferSize == false)

      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text(viewModel.selectedAudioBufferSize.subtitle)
            .font(.subheadline)
          Text(viewModel.audioBufferDescription)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }

        Spacer(minLength: 12)

        if viewModel.canSelectAudioBufferSize == false {
          Label("Stop to change", systemImage: "lock.fill")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
    }
    .sectionSurface()
  }

  private var bufferSizeSelection: Binding<AudioBufferSizeOption> {
    Binding(
      get: { viewModel.selectedAudioBufferSize },
      set: { viewModel.selectedAudioBufferSize = $0 }
    )
  }
}

private struct InputPanel: View {
  let viewModel: HearAugmentViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionTitle("Audio Route", systemImage: "mic")

      Picker("Input", selection: inputSelection) {
        ForEach(viewModel.inputDevices) { device in
          Label(device.name, systemImage: device.isBluetooth ? "airpodspro" : "iphone")
            .tag(device.id)
        }
      }
      .pickerStyle(.menu)
      .disabled(viewModel.canSelectInput == false || viewModel.inputDevices.isEmpty)

      if viewModel.inputDevices.isEmpty {
        Text("Microphone access or an available input is required.")
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

  private var inputSelection: Binding<String> {
    Binding(
      get: { viewModel.selectedInputID },
      set: { viewModel.selectInput(id: $0) }
    )
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
}

private struct SafetyPanel: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      sectionTitle("Hearing Safety", systemImage: "ear")
      Text("Start with low device volume. Hear Augment is an audio AR prototype for creative listening and is not a medical hearing device.")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .sectionSurface()
  }
}

private func sliderRow(
  title: String,
  value: Binding<Double>,
  range: ClosedRange<Double>,
  displayValue: String
) -> some View {
  VStack(alignment: .leading, spacing: 8) {
    HStack {
      Text(title)
      Spacer()
      Text(displayValue)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
    .font(.subheadline)

    Slider(value: value, in: range)
  }
}

private func sectionTitle(_ title: String, systemImage: String) -> some View {
  Label(title, systemImage: systemImage)
    .font(.headline)
}

private func percentText(_ value: Double) -> String {
  "\(Int((value * 100).rounded()))%"
}

private func hearAugmentColor(for accentName: String) -> Color {
  switch accentName {
  case "blue":
    return .blue
  case "green":
    return .green
  case "pink":
    return .pink
  case "purple":
    return .purple
  case "cyan":
    return .cyan
  case "orange":
    return .orange
  case "indigo":
    return .indigo
  case "mint":
    return .mint
  case "teal":
    return .teal
  default:
    return MuColors.primary
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
