//
//  Display.swift
//  AmbientLight
//
//  Created by Hiroshi Kimura on 2026/02/12.
//

import SwiftUI

/// Hosts one rendered light scene and its scene-local adjustment controls.
///
/// `ContentView` owns which scene and root control mode are active. `Display`
/// retains ownership of the scene's fine-tuning sheet because its parameters
/// remain local to the concrete pattern view.
struct Display<Content: View, SettingsContent: View>: View {

  let scene: LightScene
  let isActive: Bool
  let content: Content
  let settingsContent: SettingsContent
  let matrixX: MatrixBinding
  let matrixY: MatrixBinding
  let usesEdgeGradientMask: Bool

  @Binding var isAdjustmentVisible: Bool

  @State private var showsSettings = false
  @State private var isDragging = false
  @State private var hideTask: Task<Void, Never>?

  private let hideDelay: Duration = .seconds(4)

  init(
    scene: LightScene = .ambientFog,
    isActive: Bool = true,
    isAdjustmentVisible: Binding<Bool> = .constant(false),
    matrixX: MatrixBinding,
    matrixY: MatrixBinding,
    usesEdgeGradientMask: Bool = true,
    @ViewBuilder content: () -> Content,
    @ViewBuilder settingsContent: () -> SettingsContent
  ) {
    self.scene = scene
    self.isActive = isActive
    _isAdjustmentVisible = isAdjustmentVisible
    self.matrixX = matrixX
    self.matrixY = matrixY
    self.usesEdgeGradientMask = usesEdgeGradientMask
    self.content = content()
    self.settingsContent = settingsContent()
  }

  var body: some View {
    ZStack {
      renderedLight

      if isActive {
        AdjustmentOverlay(
          scene: scene,
          matrixX: matrixX,
          matrixY: matrixY,
          isDragging: $isDragging,
          isVisible: $isAdjustmentVisible,
          onOpenFineTune: openFineTune,
          onDone: finishAdjustment
        )
      }
    }
    .onChange(of: isActive) { _, isActive in
      if !isActive {
        hideTask?.cancel()
        isAdjustmentVisible = false
      }
    }
    .onChange(of: isAdjustmentVisible) { _, isVisible in
      guard isActive else { return }

      if isVisible {
        scheduleHide()
      } else {
        hideTask?.cancel()
      }
    }
    .onChange(of: isDragging) { _, isDragging in
      guard isActive else { return }

      if isDragging {
        hideTask?.cancel()
      } else if isAdjustmentVisible {
        scheduleHide()
      }
    }
    .sensoryFeedback(.impact, trigger: isActive && isAdjustmentVisible)
    .sheet(isPresented: $showsSettings) {
      SceneSettingsView(scene: scene) {
        settingsContent
      }
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
    }
    .onDisappear {
      hideTask?.cancel()
    }
  }

  @ViewBuilder
  private var renderedLight: some View {
    if usesEdgeGradientMask {
      EdgeGradientMask {
        content
      }
      .allowedDynamicRange(.high)
    } else {
      content
        .allowedDynamicRange(.high)
    }
  }

  private func openFineTune() {
    hideTask?.cancel()
    isAdjustmentVisible = false
    showsSettings = true
  }

  private func finishAdjustment() {
    hideTask?.cancel()
    isAdjustmentVisible = false
  }

  private func scheduleHide() {
    hideTask?.cancel()
    hideTask = Task {
      do {
        try await Task.sleep(for: hideDelay)
        guard !Task.isCancelled else { return }
        isAdjustmentVisible = false
      } catch {
        // Cancellation is expected while the person is still adjusting the light.
      }
    }
  }
}

/// The two-axis quick adjustment and its temporary explanatory chrome.
private struct AdjustmentOverlay: View {

  let scene: LightScene
  let matrixX: MatrixBinding
  let matrixY: MatrixBinding
  @Binding var isDragging: Bool
  @Binding var isVisible: Bool
  let onOpenFineTune: @MainActor @Sendable () -> Void
  let onDone: @MainActor @Sendable () -> Void

  var body: some View {
    ZStack {
      Color.black
        .opacity(isVisible ? 0.28 : 0)
        .ignoresSafeArea()
        .allowsHitTesting(false)

      MatrixControl(
        matrixX: matrixX,
        matrixY: matrixY,
        isDragging: $isDragging,
        isVisible: $isVisible
      )
      .frame(maxWidth: 560, maxHeight: 560)
      .padding(36)

      if isVisible {
        AdjustmentChrome(
          hint: scene.adjustmentHint,
          onOpenFineTune: onOpenFineTune,
          onDone: onDone
        )
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
      }
    }
    .animation(.easeInOut(duration: 0.24), value: isVisible)
  }
}

/// Labels and actions around the otherwise gesture-driven matrix control.
private struct AdjustmentChrome: View {

  let hint: LocalizedStringResource
  let onOpenFineTune: @MainActor @Sendable () -> Void
  let onDone: @MainActor @Sendable () -> Void

  var body: some View {
    VStack(spacing: 20) {
      Label(hint, systemImage: "hand.draw")
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.white.opacity(0.84))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.2), in: Capsule())
        .glassEffect(.regular, in: .capsule)

      Spacer(minLength: 0)

      HStack(spacing: 10) {
        Button("Fine Tune", systemImage: "slider.horizontal.3", action: onOpenFineTune)
          .buttonStyle(.glass)

        Button("Done", action: onDone)
          .buttonStyle(.glassProminent)
      }
    }
    .safeAreaPadding(.horizontal, 20)
    .safeAreaPadding(.vertical, 18)
    .frame(maxWidth: 720)
    .frame(maxWidth: .infinity)
  }
}

/// Scene-local parameters shown from the global Adjust experience.
private struct SceneSettingsView<EmbeddedContent: View>: View {

  let scene: LightScene
  let embeddedContent: EmbeddedContent

  @Environment(\.dismiss) private var dismiss

  init(
    scene: LightScene,
    @ViewBuilder embeddedContent: () -> EmbeddedContent
  ) {
    self.scene = scene
    self.embeddedContent = embeddedContent()
  }

  var body: some View {
    NavigationStack {
      List {
        Section("Fine Tune") {
          embeddedContent
        }
      }
      .navigationTitle(Text(scene.title))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }
}
