import AppIntents
import SwiftUI
import WidgetKit

@main
struct CodexPetWidgets: WidgetBundle {
  var body: some Widget {
    CodexPetWidget()
  }
}

struct CodexPetWidget: Widget {
  private let kind = "app.muukii.codexpet.widget"

  var body: some WidgetConfiguration {
    AppIntentConfiguration(
      kind: kind,
      intent: CodexPetWidgetIntent.self,
      provider: CodexPetWidgetProvider()
    ) { entry in
      CodexPetWidgetView(entry: entry)
    }
    .configurationDisplayName("Codex Pet")
    .description("Show a Codex pet pose on your Home Screen or Lock Screen.")
    .supportedFamilies([
      .systemSmall,
      .systemMedium,
      .accessoryCircular,
      .accessoryRectangular,
    ])
  }
}

/// Widget configuration that chooses the bundled pet and the pose to show.
struct CodexPetWidgetIntent: WidgetConfigurationIntent {
  static var title: LocalizedStringResource {
    "Codex Pet"
  }

  static var description: IntentDescription {
    IntentDescription("Choose a Codex pet and pose.")
  }

  @Parameter(title: "Pet", default: .mofuMonkey)
  var pet: CodexPetWidgetPet

  @Parameter(title: "Pose", default: .idle)
  var pose: CodexPetWidgetPose
}

/// Pet choices exposed to WidgetKit's edit sheet.
enum CodexPetWidgetPet: String, AppEnum {
  case mofuMonkey
  case mofuMonkeyDot

  static var typeDisplayRepresentation: TypeDisplayRepresentation {
    "Pet"
  }

  static var caseDisplayRepresentations: [CodexPetWidgetPet: DisplayRepresentation] {
    [
      .mofuMonkey: "Mofu Monkey",
      .mofuMonkeyDot: "Mofu Monkey Dot",
    ]
  }

  var pet: CodexPet {
    switch self {
    case .mofuMonkey:
      CodexPet.builtInPets[0]
    case .mofuMonkeyDot:
      CodexPet.builtInPets[1]
    }
  }
}

/// Pose choices exposed to WidgetKit's edit sheet.
enum CodexPetWidgetPose: String, CaseIterable, AppEnum {
  case idle
  case runningRight
  case runningLeft
  case waving
  case jumping
  case failed
  case waiting
  case running
  case review

  static var typeDisplayRepresentation: TypeDisplayRepresentation {
    "Pose"
  }

  static var caseDisplayRepresentations: [CodexPetWidgetPose: DisplayRepresentation] {
    [
      .idle: "Idle",
      .runningRight: "Running Right",
      .runningLeft: "Running Left",
      .waving: "Waving",
      .jumping: "Jumping",
      .failed: "Failed",
      .waiting: "Waiting",
      .running: "Working",
      .review: "Reviewing",
    ]
  }

  var animation: CodexPetAnimation {
    switch self {
    case .idle:
      .idle
    case .runningRight:
      .runningRight
    case .runningLeft:
      .runningLeft
    case .waving:
      .waving
    case .jumping:
      .jumping
    case .failed:
      .failed
    case .waiting:
      .waiting
    case .running:
      .running
    case .review:
      .review
    }
  }
}

struct CodexPetWidgetEntry: TimelineEntry {
  let date: Date
  let pet: CodexPet
  let animation: CodexPetAnimation
  let frameIndex: Int

  static let placeholder = CodexPetWidgetEntry(
    date: Date(),
    pet: CodexPet.builtInPets[0],
    animation: .idle,
    frameIndex: CodexPetAnimation.idle.staticFrameIndex
  )
}

struct CodexPetWidgetProvider: AppIntentTimelineProvider {
  func placeholder(in context: Context) -> CodexPetWidgetEntry {
    .placeholder
  }

  func snapshot(
    for configuration: CodexPetWidgetIntent,
    in context: Context
  ) async -> CodexPetWidgetEntry {
    entry(for: configuration, date: Date())
  }

  func timeline(
    for configuration: CodexPetWidgetIntent,
    in context: Context
  ) async -> Timeline<CodexPetWidgetEntry> {
    Timeline(
      entries: [
        entry(for: configuration, date: Date()),
      ],
      policy: .never
    )
  }

  private func entry(
    for configuration: CodexPetWidgetIntent,
    date: Date
  ) -> CodexPetWidgetEntry {
    let animation = configuration.pose.animation

    return CodexPetWidgetEntry(
      date: date,
      pet: configuration.pet.pet,
      animation: animation,
      frameIndex: animation.staticFrameIndex
    )
  }
}

struct CodexPetWidgetView: View {
  @Environment(\.widgetFamily) private var family

  let entry: CodexPetWidgetEntry

  var body: some View {
    Group {
      switch family {
      case .systemMedium:
        mediumWidget
      case .accessoryCircular:
        accessoryCircularWidget
      case .accessoryRectangular:
        accessoryRectangularWidget
      default:
        smallWidget
      }
    }
    .containerBackground(for: .widget) {
      CodexPetPalette.stage
    }
  }

  private var smallWidget: some View {
    VStack(spacing: 8) {
      Spacer(minLength: 0)
      petImage(maxWidth: 108)
      Text(entry.animation.title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(CodexPetPalette.controlText)
    }
    .padding(12)
  }

  private var mediumWidget: some View {
    HStack(spacing: 16) {
      petImage(maxWidth: 128)

      VStack(alignment: .leading, spacing: 6) {
        Text(entry.pet.displayName)
          .font(.headline.weight(.bold))
          .foregroundStyle(CodexPetPalette.controlText)
          .lineLimit(1)

        Text(entry.animation.title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(CodexPetPalette.accent)

        Text("Codex Pet")
          .font(.caption)
          .foregroundStyle(CodexPetPalette.secondaryText)
      }

      Spacer(minLength: 0)
    }
    .padding(16)
  }

  private var accessoryCircularWidget: some View {
    petImage(maxWidth: 48)
      .padding(4)
  }

  private var accessoryRectangularWidget: some View {
    HStack(spacing: 8) {
      petImage(maxWidth: 48)

      VStack(alignment: .leading, spacing: 1) {
        Text(entry.pet.pickerTitle)
          .font(.caption.weight(.semibold))
          .lineLimit(1)

        Text(entry.animation.title)
          .font(.caption2)
          .lineLimit(1)
      }
    }
  }

  @ViewBuilder
  private func petImage(maxWidth: CGFloat) -> some View {
    if let image = CodexPetSpriteSheet(pet: entry.pet)?.frame(
      for: entry.animation,
      at: entry.frameIndex
    ) {
      Image(uiImage: image)
        .resizable()
        .interpolation(entry.pet.renderingStyle.interpolation)
        .antialiased(entry.pet.renderingStyle == .soft)
        .scaledToFit()
        .frame(maxWidth: maxWidth)
        .accessibilityLabel(entry.pet.displayName)
    } else {
      Image(systemName: "questionmark.app.dashed")
        .font(.title)
        .foregroundStyle(CodexPetPalette.secondaryText)
        .accessibilityLabel("Missing pet asset")
    }
  }
}

#Preview(as: .systemSmall) {
  CodexPetWidget()
} timeline: {
  CodexPetWidgetEntry.placeholder
}

#Preview(as: .systemMedium) {
  CodexPetWidget()
} timeline: {
  CodexPetWidgetEntry(
    date: Date(),
    pet: CodexPet.builtInPets[1],
    animation: .review,
    frameIndex: CodexPetAnimation.review.staticFrameIndex
  )
}
