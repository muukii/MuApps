import SwiftUI

struct ContentView: View {

  @AppStorage("currentPage") private var currentPage = LightScene.solarField.rawValue
  @AppStorage("hasSeenLightIntroduction") private var hasSeenLightIntroduction = false

  @Environment(AppContainer.self) private var appContainer
  @Environment(\.scenePhase) private var scenePhase

  @State private var isInterfaceVisible = false
  @State private var isSceneBrowserVisible = false
  @State private var isAdjustmentVisible = false
  @State private var isTimerPresented = false
  @State private var lightTimer = LightTimer()
  @State private var interfaceHideTask: Task<Void, Never>?

  private let interfaceHideDelay: Duration = .seconds(6)

  private var selectedScene: LightScene {
    LightScene(rawValue: currentPage) ?? .solarField
  }

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        Color.black

        Carousel(
          selection: Binding(
            get: { currentPage },
            set: { newValue in
              guard let newValue else { return }
              currentPage = newValue
            }
          ),
          isScrollEnabled: isSceneBrowserVisible,
          margin: isSceneBrowserVisible
            ? Self.sceneBrowserMargin(for: proxy.size.width)
            : 0
        ) {
          ForEach(LightScene.allCases) { scene in
            LightSceneContent(
              scene: scene,
              isActive: scene == selectedScene
                && !lightTimer.isExpired
                && scenePhase == .active,
              isBrowsing: isSceneBrowserVisible,
              isAdjustmentVisible: $isAdjustmentVisible
            )
            .allowsHitTesting(!isSceneBrowserVisible)
            .ignoresSafeArea()
            .id(scene.rawValue)
          }
          .padding(.vertical, isSceneBrowserVisible ? 128 : 0)
        }
        .contentShape(Rectangle())
        .gesture(
          TapGesture().onEnded(revealInterface),
          isEnabled: hasSeenLightIntroduction
            && !lightTimer.isExpired
            && !isAdjustmentVisible
            && !isInterfaceVisible
            && !isSceneBrowserVisible
        )
        .simultaneousGesture(
          LongPressGesture(minimumDuration: 0.45).onEnded { _ in
            guard hasSeenLightIntroduction, !lightTimer.isExpired else { return }
            openSceneBrowser()
          }
        )
        .allowsHitTesting(!lightTimer.isExpired)

        if lightTimer.isExpired {
          LightRestView(onWake: lightTimer.wake)
            .transition(.opacity)
        } else if !hasSeenLightIntroduction {
          LightIntroductionView {
            hasSeenLightIntroduction = true
            revealInterface()
          }
          .transition(.opacity.combined(with: .blurReplace))
        } else if !isAdjustmentVisible && (isInterfaceVisible || isSceneBrowserVisible) {
          LightInterfaceOverlay(
            scene: selectedScene,
            isBrowsingScenes: isSceneBrowserVisible,
            isTimerRunning: lightTimer.isRunning,
            onOpenScenes: openSceneBrowser,
            onOpenAdjustment: openAdjustment,
            onOpenTimer: openTimer,
            onFinishBrowsing: finishSceneBrowsing,
            onDismissInterface: hideInterface
          )
          .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
        }
      }
      .animation(.smooth, value: hasSeenLightIntroduction)
      .animation(.smooth, value: isInterfaceVisible)
      .animation(
        .spring(duration: 0.44, bounce: 0.06),
        value: isSceneBrowserVisible
      )
      .animation(.smooth, value: isAdjustmentVisible)
      .animation(.easeInOut(duration: 0.8), value: lightTimer.isExpired)
    }
    .sheet(isPresented: $isTimerPresented, onDismiss: revealInterface) {
      LightTimerView(timer: lightTimer)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
    .onChange(of: currentPage) { _, _ in
      isAdjustmentVisible = false
      if !isSceneBrowserVisible {
        revealInterface()
      }
    }
    .onChange(of: isAdjustmentVisible) { wasVisible, isVisible in
      if wasVisible && !isVisible && !isTimerPresented {
        revealInterface()
      }
    }
    .onChange(of: lightTimer.isExpired, initial: true) { _, isExpired in
      appContainer.setLightEmissionActive(!isExpired)
      if isExpired {
        interfaceHideTask?.cancel()
        isInterfaceVisible = false
        isSceneBrowserVisible = false
        isAdjustmentVisible = false
        isTimerPresented = false
      }
    }
    .onChange(of: scenePhase) { _, newPhase in
      if newPhase == .active {
        lightTimer.reconcile()
      }
    }
    .onAppear {
      appContainer.setScenePhase(scenePhase)
      if LightScene(rawValue: currentPage) == nil {
        currentPage = LightScene.solarField.rawValue
      }
      if hasSeenLightIntroduction {
        revealInterface()
      }
    }
    .onDisappear {
      interfaceHideTask?.cancel()
    }
  }

  private static func sceneBrowserMargin(for width: CGFloat) -> CGFloat {
    return min(max(width * 0.16, 56), 180)
  }

  private func openSceneBrowser() {
    interfaceHideTask?.cancel()
    isAdjustmentVisible = false
    isInterfaceVisible = true
    isSceneBrowserVisible = true
  }

  private func finishSceneBrowsing() {
    isSceneBrowserVisible = false
    revealInterface()
  }

  private func openAdjustment() {
    interfaceHideTask?.cancel()
    isInterfaceVisible = false
    isSceneBrowserVisible = false
    isAdjustmentVisible = true
  }

  private func openTimer() {
    interfaceHideTask?.cancel()
    isTimerPresented = true
  }

  private func hideInterface() {
    interfaceHideTask?.cancel()
    isInterfaceVisible = false
  }

  private func revealInterface() {
    guard hasSeenLightIntroduction, !lightTimer.isExpired else { return }

    isInterfaceVisible = true
    scheduleInterfaceHide()
  }

  private func scheduleInterfaceHide() {
    interfaceHideTask?.cancel()
    interfaceHideTask = Task {
      do {
        try await Task.sleep(for: interfaceHideDelay)
        guard !Task.isCancelled, !isSceneBrowserVisible, !isAdjustmentVisible,
              !isTimerPresented else { return }
        isInterfaceVisible = false
      } catch {
        // Cancellation is expected whenever the interface is used again.
      }
    }
  }
}

/// Keeps each shader scene in a stable view identity while the carousel changes mode.
private struct LightSceneContent: View {

  let scene: LightScene
  let isActive: Bool
  let isBrowsing: Bool
  @Binding var isAdjustmentVisible: Bool

  var body: some View {
    sceneBody
      .clipShape(
        RoundedRectangle(
          cornerRadius: isBrowsing ? 30 : 0,
          style: .continuous
        )
      )
      .overlay {
        RoundedRectangle(
          cornerRadius: isBrowsing ? 30 : 0,
          style: .continuous
        )
        .stroke(.white.opacity(isBrowsing ? 0.18 : 0), lineWidth: 1)
      }
      .animation(.spring(duration: 0.44, bounce: 0.06), value: isBrowsing)
  }

  @ViewBuilder
  private var sceneBody: some View {
    switch scene {
    case .solarField:
      PatternSolarField(
        isActive: isActive,
        isAdjustmentVisible: $isAdjustmentVisible
      )
    case .ambientFog:
      PatternAmbientFog(
        isActive: isActive,
        isAdjustmentVisible: $isAdjustmentVisible
      )
    case .aurora:
      PatternAurora(
        isActive: isActive,
        isAdjustmentVisible: $isAdjustmentVisible
      )
    case .plasma:
      PatternPlasma(
        isActive: isActive,
        isAdjustmentVisible: $isAdjustmentVisible
      )
    case .firelight:
      PatternFire(
        isActive: isActive,
        isAdjustmentVisible: $isAdjustmentVisible
      )
    case .smoke:
      PatternSmoke(
        isActive: isActive,
        isAdjustmentVisible: $isAdjustmentVisible
      )
    }
  }
}

/// The transient top label and bottom controls shown over the light canvas.
private struct LightInterfaceOverlay: View {

  let scene: LightScene
  let isBrowsingScenes: Bool
  let isTimerRunning: Bool
  let onOpenScenes: @MainActor @Sendable () -> Void
  let onOpenAdjustment: @MainActor @Sendable () -> Void
  let onOpenTimer: @MainActor @Sendable () -> Void
  let onFinishBrowsing: @MainActor @Sendable () -> Void
  let onDismissInterface: @MainActor @Sendable () -> Void

  var body: some View {
    ZStack {
      LightInterfaceLegibilityLayer()

      VStack(alignment: .leading, spacing: 0) {
        SceneIdentityView(scene: scene)
          .allowsHitTesting(false)

        // Only the empty canvas dismisses the interface. Keeping this gesture
        // out of the control region prevents a dock button tap from also
        // triggering the background dismissal recognizer.
        Color.clear
          .contentShape(Rectangle())
          .onTapGesture(perform: onDismissInterface)
          .allowsHitTesting(!isBrowsingScenes)
          .frame(minHeight: 24)

        if isBrowsingScenes {
          SceneBrowserDock(onDone: onFinishBrowsing)
        } else {
          LightDock(
            isTimerRunning: isTimerRunning,
            onOpenScenes: onOpenScenes,
            onOpenAdjustment: onOpenAdjustment,
            onOpenTimer: onOpenTimer
          )
        }
      }
      .safeAreaPadding(.horizontal, 20)
      .safeAreaPadding(.vertical, 18)
      .frame(maxWidth: 720)
      .frame(maxWidth: .infinity)
    }
  }
}

/// Darkens only the interface edges, leaving the center of the light untouched.
private struct LightInterfaceLegibilityLayer: View {

  var body: some View {
    VStack(spacing: 0) {
      LinearGradient(
        colors: [.black.opacity(0.52), .black.opacity(0)],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(height: 180)

      Spacer(minLength: 0)

      LinearGradient(
        colors: [.black.opacity(0), .black.opacity(0.52)],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(height: 190)
    }
    .ignoresSafeArea()
    .allowsHitTesting(false)
  }
}

/// The current scene's ordered position, name, and material description.
private struct SceneIdentityView: View {

  let scene: LightScene

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(scene.positionText)
        .font(.caption.monospacedDigit().weight(.semibold))
        .tracking(1.4)
        .foregroundStyle(.white.opacity(0.66))

      Text(scene.title)
        .font(.system(.title2, design: .serif, weight: .medium))
        .foregroundStyle(Color(red: 0.97, green: 0.96, blue: 0.93))

      Text(scene.summary)
        .font(.subheadline)
        .foregroundStyle(.white.opacity(0.7))
    }
    .shadow(color: .black.opacity(0.55), radius: 12, y: 2)
  }
}

/// The three root actions Calm Light exposes without covering the artwork.
private struct LightDock: View {

  let isTimerRunning: Bool
  let onOpenScenes: @MainActor @Sendable () -> Void
  let onOpenAdjustment: @MainActor @Sendable () -> Void
  let onOpenTimer: @MainActor @Sendable () -> Void

  var body: some View {
    HStack(spacing: 0) {
      LightDockButton(
        title: "Scenes",
        systemImage: "square.stack.3d.up",
        action: onOpenScenes
      )

      LightDockButton(
        title: "Adjust",
        systemImage: "circle.grid.cross",
        action: onOpenAdjustment
      )

      LightDockButton(
        title: "Timer",
        systemImage: isTimerRunning ? "timer.circle.fill" : "timer",
        isActive: isTimerRunning,
        action: onOpenTimer
      )
    }
    .padding(6)
    .frame(maxWidth: 360)
    .background(.black.opacity(0.2), in: Capsule())
    .glassEffect(.regular.interactive(), in: .capsule)
    .frame(maxWidth: .infinity)
  }
}

/// One equally-sized action inside the Light Dock.
private struct LightDockButton: View {

  let title: LocalizedStringResource
  let systemImage: String
  var isActive = false
  let action: @MainActor @Sendable () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 4) {
        Image(systemName: systemImage)
          .font(.body.weight(.medium))
          .symbolEffect(.pulse, value: isActive)

        Text(title)
          .font(.caption.weight(.medium))
      }
      .foregroundStyle(isActive ? Color.orange : .white)
      .frame(maxWidth: .infinity, minHeight: 52)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

/// Controls shown while the full-size carousel itself acts as the scene picker.
private struct SceneBrowserDock: View {

  let onDone: @MainActor @Sendable () -> Void

  var body: some View {
    HStack(spacing: 16) {
      Label("Swipe to choose a light", systemImage: "arrow.left.and.right")
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.white.opacity(0.78))

      Spacer(minLength: 8)

      Button("Done", action: onDone)
        .buttonStyle(.glassProminent)
    }
    .padding(8)
    .padding(.leading, 10)
    .frame(maxWidth: 520)
    .background(.black.opacity(0.2), in: Capsule())
    .glassEffect(.regular, in: .capsule)
    .frame(maxWidth: .infinity)
  }
}

/// First-run product introduction layered directly over the live Solar Field.
private struct LightIntroductionView: View {

  let onBegin: @MainActor @Sendable () -> Void

  var body: some View {
    ZStack(alignment: .bottom) {
      LinearGradient(
        stops: [
          .init(color: .black.opacity(0.08), location: 0),
          .init(color: .black.opacity(0.22), location: 0.45),
          .init(color: .black.opacity(0.92), location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 10) {
          Text("CALM LIGHT")
            .font(.caption.weight(.semibold))
            .tracking(2.4)
            .foregroundStyle(.white.opacity(0.68))

          Text("Set down your screen.\nLet it glow.")
            .font(.system(.largeTitle, design: .serif, weight: .medium))
            .foregroundStyle(Color(red: 0.97, green: 0.96, blue: 0.93))

          Text("Choose a scene, shape its light, and let a timer end the glow quietly.")
            .font(.body)
            .foregroundStyle(.white.opacity(0.72))
            .fixedSize(horizontal: false, vertical: true)
        }

        IntroductionFeatureStrip()

        Button(action: onBegin) {
          Text("Begin")
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
      }
      .padding(26)
      .frame(maxWidth: 560, alignment: .leading)
      .safeAreaPadding(.bottom, 12)
      .frame(maxWidth: .infinity)
    }
  }
}

/// Three concrete capabilities introduced before the live controls appear.
private struct IntroductionFeatureStrip: View {

  var body: some View {
    ViewThatFits {
      HStack(spacing: 20) {
        IntroductionFeature(title: "Scenes", systemImage: "square.stack.3d.up")
        IntroductionFeature(title: "Adjust", systemImage: "circle.grid.cross")
        IntroductionFeature(title: "Timer", systemImage: "timer")
      }

      VStack(alignment: .leading, spacing: 12) {
        IntroductionFeature(title: "Scenes", systemImage: "square.stack.3d.up")
        IntroductionFeature(title: "Adjust", systemImage: "circle.grid.cross")
        IntroductionFeature(title: "Timer", systemImage: "timer")
      }
    }
  }
}

/// A single concise capability in the first-run feature strip.
private struct IntroductionFeature: View {

  let title: LocalizedStringResource
  let systemImage: String

  var body: some View {
    Label(title, systemImage: systemImage)
      .font(.subheadline.weight(.medium))
      .foregroundStyle(.white.opacity(0.82))
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Timer configuration and current countdown.
private struct LightTimerView: View {

  let timer: LightTimer

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      VStack(spacing: 26) {
        TimerStatusView(endDate: timer.endDate)

        HStack(spacing: 10) {
          ForEach(LightTimer.Preset.allCases) { preset in
            Button {
              timer.start(preset)
              dismiss()
            } label: {
              Text(preset.title)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 42)
            }
            .buttonStyle(.glass)
          }
        }

        if timer.isRunning {
          Button("Stop Timer", role: .destructive) {
            timer.cancel()
            dismiss()
          }
        }

        Text("When time ends, the light turns off and the screen can sleep.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .padding(24)
      .frame(maxWidth: 560, maxHeight: .infinity)
      .frame(maxWidth: .infinity)
      .navigationTitle("Light Timer")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }
}

/// Timer icon and live countdown, isolated so only this region updates each second.
private struct TimerStatusView: View {

  let endDate: Date?

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: endDate == nil ? "moon.stars" : "timer.circle.fill")
        .font(.system(size: 40, weight: .light))
        .foregroundStyle(.tint)

      if let endDate {
        Text(endDate, style: .timer)
          .font(.system(.largeTitle, design: .monospaced, weight: .medium))
          .monospacedDigit()
      } else {
        Text("Let the light end on its own")
          .font(.title3.weight(.medium))
      }
    }
  }
}

/// Black resting state entered when the light timer reaches zero.
private struct LightRestView: View {

  let onWake: @MainActor @Sendable () -> Void

  var body: some View {
    Button(action: onWake) {
      VStack(spacing: 12) {
        Image(systemName: "moon.zzz")
          .font(.system(size: 34, weight: .light))

        Text("Light off")
          .font(.system(.title2, design: .serif, weight: .medium))

        Text("Tap to wake")
          .font(.footnote)
      }
      .foregroundStyle(.white.opacity(0.48))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(.black)
  }
}

#Preview("First Launch") {
  ContentView()
    .environment(AppContainer())
}
