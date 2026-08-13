import SwiftUI

struct ContentView: View {
  @State private var selectedPet: CodexPet
  @State private var spriteSheet: CodexPetSpriteSheet?
  @State private var selectedAnimation: CodexPetAnimation = .idle
  @State private var playbackSpeed: Double = 1

  init() {
    let initialPet = CodexPet.builtInPets[0]
    _selectedPet = State(initialValue: initialPet)
    _spriteSheet = State(initialValue: CodexPetSpriteSheet(pet: initialPet))
  }

  var body: some View {
    VStack(spacing: 0) {
      header

      Divider()
        .opacity(0.4)

      AnimatedPetStage(
        spriteSheet: spriteSheet,
        animation: selectedAnimation,
        playbackSpeed: playbackSpeed
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      controls
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .background(.regularMaterial)
    }
    .background(CodexPetPalette.background)
    .onChange(of: selectedPet) { _, newPet in
      spriteSheet = CodexPetSpriteSheet(pet: newPet)
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Codex Pet")
          .font(.system(.title2, design: .rounded, weight: .bold))
          .foregroundStyle(CodexPetPalette.controlText)
        Text(selectedPet.description)
          .font(.callout)
          .foregroundStyle(CodexPetPalette.secondaryText)
      }

      Picker("Pet", selection: $selectedPet) {
        ForEach(CodexPet.builtInPets) { pet in
          Text(pet.pickerTitle)
            .tag(pet)
        }
      }
      .pickerStyle(.segmented)
      .frame(maxWidth: 360, alignment: .leading)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 14)
  }

  private var controls: some View {
    VStack(spacing: 14) {
      AnimationPicker(selection: $selectedAnimation)

      HStack(spacing: 12) {
        Image(systemName: "speedometer")
          .foregroundStyle(CodexPetPalette.accent)
          .frame(width: 28)

        Slider(value: $playbackSpeed, in: 0.25...2, step: 0.25)

        Text(playbackSpeed.formatted(.number.precision(.fractionLength(2))) + "x")
          .font(.system(.callout, design: .monospaced, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 56, alignment: .trailing)
      }
    }
  }
}

private struct AnimatedPetStage: View {
  let spriteSheet: CodexPetSpriteSheet?
  let animation: CodexPetAnimation
  let playbackSpeed: Double

  var body: some View {
    GeometryReader { proxy in
      TimelineView(.animation(minimumInterval: 1 / 24)) { context in
        let frameIndex = frameIndex(at: context.date)
        let stageOffset = offset(in: proxy.size, at: context.date)
        let bobOffset = idleBobOffset(at: context.date)

        ZStack {
          stageBackdrop

          if let spriteSheet, let image = spriteSheet.frame(for: animation, at: frameIndex) {
            Image(uiImage: image)
              .resizable()
              .interpolation(spriteSheet.pet.renderingStyle.interpolation)
              .antialiased(spriteSheet.pet.renderingStyle == .soft)
              .scaledToFit()
              .frame(width: petWidth(in: proxy.size))
              .offset(
                x: stageOffset.width,
                y: stageOffset.height + bobOffset
              )
              .animation(.spring(response: 0.42, dampingFraction: 0.82), value: animation)
              .accessibilityLabel(spriteSheet.pet.displayName)
          } else {
            ContentUnavailableView(
              "Pet asset missing",
              systemImage: "questionmark.app.dashed"
            )
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  private var stageBackdrop: some View {
    ZStack {
      CodexPetPalette.stage

      VStack {
        Spacer()

        Capsule()
          .fill(CodexPetPalette.ground)
          .frame(width: 220, height: 8)
          .opacity(animation == .jumping ? 0.25 : 0.5)
          .padding(.bottom, 54)
      }
    }
  }

  private func frameIndex(at date: Date) -> Int {
    let framesPerSecond = animation.framesPerSecond * playbackSpeed
    return Int(date.timeIntervalSinceReferenceDate * framesPerSecond) % CodexPetSpriteSheet.Geometry.codexPet.columns
  }

  private func petWidth(in size: CGSize) -> CGFloat {
    min(size.width * 0.42, size.height * 0.62, 260)
  }

  private func offset(in size: CGSize, at date: Date) -> CGSize {
    let travelWidth = max(0, size.width - petWidth(in: size) - 48)
    let phase = (date.timeIntervalSinceReferenceDate * 0.16 * playbackSpeed).truncatingRemainder(dividingBy: 1)

    switch animation {
    case .runningRight:
      return CGSize(width: -travelWidth / 2 + travelWidth * phase, height: 14)
    case .runningLeft:
      return CGSize(width: travelWidth / 2 - travelWidth * phase, height: 14)
    case .jumping:
      let jump = abs(sin(date.timeIntervalSinceReferenceDate * 3.6 * playbackSpeed))
      return CGSize(width: 0, height: -92 * jump)
    case .failed:
      return CGSize(width: 0, height: 22)
    default:
      return .zero
    }
  }

  private func idleBobOffset(at date: Date) -> CGFloat {
    switch animation {
    case .runningLeft, .runningRight, .jumping:
      0
    default:
      sin(date.timeIntervalSinceReferenceDate * 2.2 * playbackSpeed) * 5
    }
  }
}

private struct AnimationPicker: View {
  @Binding var selection: CodexPetAnimation

  private let columns = [
    GridItem(.adaptive(minimum: 84), spacing: 8),
  ]

  var body: some View {
    LazyVGrid(columns: columns, spacing: 8) {
      ForEach(CodexPetAnimation.allCases) { animation in
        Button {
          withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            selection = animation
          }
        } label: {
          VStack(spacing: 6) {
            Image(systemName: animation.systemImageName)
              .font(.system(size: 17, weight: .semibold))
            Text(animation.title)
              .font(.caption.weight(.semibold))
          }
          .foregroundStyle(selection == animation ? Color.white : CodexPetPalette.controlText)
          .frame(maxWidth: .infinity)
          .frame(height: 58)
          .background(selection == animation ? CodexPetPalette.accent : CodexPetPalette.control)
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(animation.title)
      }
    }
  }
}
