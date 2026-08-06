import JournalVault
import MuColor
import SwiftUI
#if canImport(UIKit)
  import UIKit
#endif

/// Suggestion preview source for either an unsaved draft or saved authored JSON.
public struct SuggestionContentSource: Equatable, Sendable {
  public let suggestion: SuggestionCardPayload?
  public let fileURL: URL?
  public let fileRevision: Int
  public let mediaFileURLsByResourceID: [UUID: URL]

  public init(
    suggestion: SuggestionCardPayload? = nil,
    fileURL: URL? = nil,
    fileRevision: Int = 0,
    mediaFileURLsByResourceID: [UUID: URL] = [:]
  ) {
    self.suggestion = suggestion
    self.fileURL = fileURL
    self.fileRevision = fileRevision
    self.mediaFileURLsByResourceID = mediaFileURLsByResourceID
  }
}

/// Renders a captured Journaling Suggestion and its persisted media resources.
struct SuggestionContentView: View {

  /// Visual treatment owned by Journaling Suggestion content.
  struct Style {
    let preset: EntryContentStyle

    init(_ preset: EntryContentStyle) {
      self.preset = preset
    }

    var additionalElementLimit: Int {
      switch preset {
      case .detail, .share:
        return .max
      case .composer, .overview:
        return 2
      }
    }

    var mediaContentMode: ContentMode {
      switch preset {
      case .overview, .detail, .share:
        return .fit
      case .composer:
        return .fill
      }
    }

    var titleFont: Font {
      preset == .share
        ? .system(size: 52, weight: .bold)
        : .title3.weight(.semibold)
    }

    var subtitleFont: Font {
      preset == .share ? .system(size: 26, weight: .medium) : .caption
    }

    var mediaAspectRatio: CGFloat { 1 }

    var showsFullTitle: Bool {
      preset == .detail || preset == .share
    }

    var contentPadding: CGFloat {
      preset == .share ? 36 : 16
    }

    var minimumHeight: CGFloat? {
      preset == .detail ? 120 : nil
    }
  }

  let suggestion: SuggestionContentSource
  let style: Style
  @State private var state: ContentMediaLoadState<SuggestionCardPayload> =
    .idle

  var body: some View {
    content
      .task(
        id: ContentFileLoadID(
          fileURL: suggestion.fileURL,
          fileRevision: suggestion.fileRevision
        )
      ) {
        await loadSuggestion()
      }
  }

  @ViewBuilder
  private var content: some View {
    let resolvedSuggestion = suggestion.suggestion ?? state.loadedPayload

    if let resolvedSuggestion {
      SuggestionContentHero(
        content: SuggestionDisplayContent(
          suggestion: resolvedSuggestion,
          mediaFileURLsByResourceID: suggestion.mediaFileURLsByResourceID,
          additionalElementLimit: style.additionalElementLimit
        ),
        style: style
      )
    } else if state.isLoading {
      SuggestionContentLoading(padding: style.contentPadding)
    } else {
      SuggestionContentPlaceholder(style: style)
    }
  }

  @MainActor
  private func loadSuggestion() async {
    guard suggestion.suggestion == nil else {
      state = .idle
      return
    }

    guard let fileURL = suggestion.fileURL else {
      state = .unavailable
      return
    }

    guard await ContentMediaFileReader.fileExists(at: fileURL) else {
      state = .unavailable
      return
    }

    state = .loading
    guard let data = await ContentMediaFileReader.data(from: fileURL),
      let payload = SuggestionCardPayload.decode(from: data),
      Task.isCancelled == false
    else {
      state = .unavailable
      return
    }

    state = .loaded(payload)
  }
}

private struct SuggestionContentHero: View {

  let content: SuggestionDisplayContent
  let style: SuggestionContentView.Style

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SuggestionContentCategoryLabel(
        symbolName: content.primary.symbolName,
        title: content.primary.categoryTitle
      )

      if let imageFileURL = content.primary.imageFileURL {
        SuggestionContentMediaImage(
          fileURL: imageFileURL,
          imageStyle: content.primary.imageStyle,
          style: style
        )
      }

      SuggestionContentPrimaryText(
        content: content.primary,
        contextTitle: content.contextTitle,
        fallbackDate: content.fallbackDate,
        style: style
      )

      if content.additionalElements.isEmpty == false
        || content.hiddenElementCount > 0
      {
        SuggestionContentAdditionalElements(
          elements: content.additionalElements,
          hiddenElementCount: content.hiddenElementCount
        )
      }
    }
    .padding(style.contentPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct SuggestionContentMediaImage: View {

  let fileURL: URL
  let imageStyle: SuggestionElementImageStyle
  let style: SuggestionContentView.Style
  @State private var image: UIImage?

  var body: some View {
    content
      .task(id: fileURL) {
        await loadImage()
      }
  }

  @ViewBuilder
  private var content: some View {
    switch imageStyle {
    case .media:
      if let image {

        Image(uiImage: image)
          .resizable()
          .aspectRatio(
            image.contentAspectRatio,
            contentMode: style.mediaContentMode
          )

      } else {
        ContentMediaPlaceholder(
          systemImage: "photo",
          aspectRatio: style.mediaAspectRatio
        )
      }

    case .icon:
      ZStack {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(.appOnSecondaryContainer.opacity(0.08))

        if let image {
          Image(uiImage: image)
            .resizable()
            .scaledToFill()
        } else {
          Image(systemName: "photo")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.appOnSecondaryContainer.opacity(0.42))
        }
      }
      .frame(width: 56, height: 56)
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
  }

  @MainActor
  private func loadImage() async {
    image = nil
    let loadedImage = await ContentMediaFileReader.image(at: fileURL)
    guard Task.isCancelled == false else {
      return
    }

    image = loadedImage
  }
}

private enum SuggestionElementImageStyle: Hashable {
  case media
  case icon
}

private struct SuggestionContentCategoryLabel: View {

  let symbolName: String
  let title: String

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: symbolName)
        .imageScale(.medium)

      Text(title)
        .lineLimit(1)
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(.appOnSecondaryContainer.opacity(0.66))
  }
}

private struct SuggestionContentPrimaryText: View {

  let content: SuggestionElementDisplayContent
  let contextTitle: String?
  let fallbackDate: Date?
  let style: SuggestionContentView.Style

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(content.title)
        .font(style.titleFont)
        .lineLimit(titleLineLimit)
        .foregroundStyle(.appOnSecondaryContainer)

      if let subtitle = content.subtitle {
        Text(subtitle)
          .font(style.subtitleFont.weight(.semibold))
          .lineLimit(2)
          .foregroundStyle(.appOnSecondaryContainer.opacity(0.72))
      }

      if let metadata = content.metadata {
        Text(metadata)
          .font(.caption.weight(.medium))
          .lineLimit(2)
          .foregroundStyle(.appOnSecondaryContainer.opacity(0.58))
      }

      if let contextTitle {
        Text(contextTitle)
          .font(.caption.weight(.medium))
          .lineLimit(1)
          .foregroundStyle(.appOnSecondaryContainer.opacity(0.48))
      }

      if let date = content.date ?? fallbackDate {
        Text(date, format: .dateTime.month().day().hour().minute())
          .font(.caption.weight(.medium))
          .lineLimit(1)
          .foregroundStyle(.appOnSecondaryContainer.opacity(0.58))
      }
    }
  }

  private var titleLineLimit: Int? {
    style.showsFullTitle ? nil : content.titleLineLimit
  }
}

private struct SuggestionContentAdditionalElements: View {

  let elements: [SuggestionElementDisplayContent]
  let hiddenElementCount: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(elements) { element in
        SuggestionElementPreviewRow(content: element)
      }

      if hiddenElementCount > 0 {
        Text("+ \(hiddenElementCount) more")
          .font(.caption.weight(.medium))
          .lineLimit(1)
          .foregroundStyle(.appOnSecondaryContainer.opacity(0.54))
      }
    }
  }
}

private struct SuggestionElementPreviewRow: View {

  let content: SuggestionElementDisplayContent

  var body: some View {
    Label {
      Text(content.compactSummary)
        .lineLimit(1)
    } icon: {
      Image(systemName: content.symbolName)
    }
    .font(.caption.weight(.medium))
    .foregroundStyle(.appOnSecondaryContainer.opacity(0.72))
  }
}

private struct SuggestionContentLoading: View {

  let padding: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SuggestionContentCategoryLabel(
        symbolName: "sparkles",
        title: "Journaling Suggestion"
      )

      ProgressView()
        .controlSize(.small)
        .tint(.secondary)
    }
    .padding(padding)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct SuggestionContentPlaceholder: View {

  let style: SuggestionContentView.Style

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SuggestionContentCategoryLabel(
        symbolName: "sparkles",
        title: "Journaling Suggestion"
      )

      Text("Suggestion")
        .font(style.titleFont)
        .foregroundStyle(.secondary)
    }
    .padding(style.contentPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct SuggestionDisplayContent: Equatable {
  let primary: SuggestionElementDisplayContent
  let contextTitle: String?
  let fallbackDate: Date?
  let additionalElements: [SuggestionElementDisplayContent]
  let hiddenElementCount: Int

  init(
    suggestion: SuggestionCardPayload,
    mediaFileURLsByResourceID: [UUID: URL],
    additionalElementLimit: Int
  ) {
    let title = SuggestionText.cleaned(suggestion.title)
    let elementDisplays = suggestion.elements.map { element in
      element.displayContent(
        in: suggestion,
        mediaFileURLsByResourceID: mediaFileURLsByResourceID
      )
    }
    let primary =
      elementDisplays.first
      ?? .emptySuggestion(title: title, date: suggestion.dateInterval?.start)
    let additionalElements = Array(
      elementDisplays.dropFirst().prefix(additionalElementLimit)
    )

    self.primary = primary
    self.contextTitle = Self.contextTitle(title, primaryTitle: primary.title)
    self.fallbackDate = suggestion.dateInterval?.start
    self.additionalElements = additionalElements
    self.hiddenElementCount = max(
      0,
      elementDisplays.dropFirst().count - additionalElements.count
    )
  }

  private static func contextTitle(
    _ suggestionTitle: String?,
    primaryTitle: String
  ) -> String? {
    guard let suggestionTitle else {
      return nil
    }

    let normalizedSuggestionTitle = suggestionTitle.trimmingCharacters(
      in: .whitespacesAndNewlines
    ).lowercased()
    let normalizedPrimaryTitle = primaryTitle.trimmingCharacters(
      in: .whitespacesAndNewlines
    ).lowercased()

    return normalizedSuggestionTitle == normalizedPrimaryTitle
      ? nil : suggestionTitle
  }
}

private struct SuggestionElementDisplayContent: Identifiable, Equatable {
  let id: UUID
  let categoryTitle: String
  let symbolName: String
  let title: String
  let subtitle: String?
  let metadata: String?
  let date: Date?
  let titleLineLimit: Int
  let imageFileURL: URL?
  let imageStyle: SuggestionElementImageStyle

  init(
    id: UUID,
    categoryTitle: String,
    symbolName: String,
    title: String,
    subtitle: String?,
    metadata: String?,
    date: Date?,
    titleLineLimit: Int,
    imageFileURL: URL? = nil,
    imageStyle: SuggestionElementImageStyle = .media
  ) {
    self.id = id
    self.categoryTitle = categoryTitle
    self.symbolName = symbolName
    self.title = title
    self.subtitle = subtitle
    self.metadata = metadata
    self.date = date
    self.titleLineLimit = titleLineLimit
    self.imageFileURL = imageFileURL
    self.imageStyle = imageStyle
  }

  var compactSummary: String {
    SuggestionText.joined([title, subtitle, metadata]) ?? title
  }

  static func emptySuggestion(title: String?, date: Date?) -> Self {
    SuggestionElementDisplayContent(
      id: UUID(),
      categoryTitle: "Journaling Suggestion",
      symbolName: "sparkles",
      title: title ?? "Suggestion",
      subtitle: nil,
      metadata: nil,
      date: date,
      titleLineLimit: 3
    )
  }
}

private enum SuggestionText {

  static func cleaned(_ value: String?) -> String? {
    guard let value else {
      return nil
    }

    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  static func joined(_ parts: [String?]) -> String? {
    let values = parts.compactMap(cleaned)

    guard values.isEmpty == false else {
      return nil
    }

    return values.joined(separator: " - ")
  }
}

extension SuggestionCardElement {

  fileprivate func displayContent(
    in suggestion: SuggestionCardPayload,
    mediaFileURLsByResourceID: [UUID: URL]
  ) -> SuggestionElementDisplayContent {
    switch self {
    case .contact(let id, let name, _):
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "Contact",
        symbolName: symbolName,
        title: SuggestionText.cleaned(name) ?? "Contact",
        subtitle: nil,
        metadata: nil,
        date: nil,
        titleLineLimit: 2,
        imageFileURL: dominantImageFileURL(
          in: suggestion,
          mediaFileURLsByResourceID: mediaFileURLsByResourceID,
          preferredKinds: [.contactPhoto]
        ),
        imageStyle: .icon
      )

    case .eventPoster(
      let id,
      let title,
      _,
      let eventStart,
      _,
      let isHost,
      let placeName
    ):
      let cleanedTitle = SuggestionText.cleaned(title)
      let cleanedPlaceName = SuggestionText.cleaned(placeName)
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "Event",
        symbolName: symbolName,
        title: cleanedTitle ?? cleanedPlaceName ?? "Event",
        subtitle: cleanedTitle == nil ? nil : cleanedPlaceName,
        metadata: isHost == true ? "Hosting" : nil,
        date: eventStart,
        titleLineLimit: 2,
        imageFileURL: dominantImageFileURL(
          in: suggestion,
          mediaFileURLsByResourceID: mediaFileURLsByResourceID,
          preferredKinds: [.eventPosterImage]
        )
      )

    case .genericMedia(let id, let title, let artist, let album, let date, _):
      let cleanedTitle = SuggestionText.cleaned(title)
      let cleanedAlbum = SuggestionText.cleaned(album)
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "Media",
        symbolName: symbolName,
        title: cleanedTitle ?? cleanedAlbum ?? "Media",
        subtitle: SuggestionText.joined([
          artist, cleanedTitle == cleanedAlbum ? nil : cleanedAlbum,
        ]),
        metadata: nil,
        date: date,
        titleLineLimit: 2,
        imageFileURL: dominantImageFileURL(
          in: suggestion,
          mediaFileURLsByResourceID: mediaFileURLsByResourceID,
          preferredKinds: [.genericMediaAppIcon]
        ),
        imageStyle: .icon
      )

    case .livePhoto(let id, _, _, let date):
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "Live Photo",
        symbolName: symbolName,
        title: "Live Photo",
        subtitle: nil,
        metadata: nil,
        date: date,
        titleLineLimit: 2,
        imageFileURL: dominantImageFileURL(
          in: suggestion,
          mediaFileURLsByResourceID: mediaFileURLsByResourceID,
          preferredKinds: [.livePhotoImage]
        )
      )

    case .location(let id, let location):
      let place = SuggestionText.cleaned(location.place)
      let city = SuggestionText.cleaned(location.city)
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "Place",
        symbolName: symbolName,
        title: place ?? city ?? "Place",
        subtitle: place == nil || place == city ? nil : city,
        metadata: location.isWorkLocation == true ? "Work" : nil,
        date: location.date,
        titleLineLimit: 2
      )

    case .locationGroup(let id, let locations):
      let names = locations.compactMap {
        SuggestionText.joined([$0.place, $0.city])
      }
      let count = locations.count
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "Places",
        symbolName: symbolName,
        title: names.first ?? "\(count) places",
        subtitle: count > 1 ? "\(count) places" : nil,
        metadata: nil,
        date: locations.compactMap(\.date).min(),
        titleLineLimit: 2
      )

    case .motion(let id, let steps, let dateInterval, _, let movementType):
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "Motion",
        symbolName: symbolName,
        title: "\(steps) steps",
        subtitle: movementType?.displayTitle,
        metadata: dateInterval?.duration.formattedDuration,
        date: dateInterval?.start,
        titleLineLimit: 2,
        imageFileURL: dominantImageFileURL(
          in: suggestion,
          mediaFileURLsByResourceID: mediaFileURLsByResourceID,
          preferredKinds: [.motionIcon]
        ),
        imageStyle: .icon
      )

    case .photo(let id, _, let date):
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "Photo",
        symbolName: symbolName,
        title: "Photo",
        subtitle: nil,
        metadata: nil,
        date: date,
        titleLineLimit: 2,
        imageFileURL: dominantImageFileURL(
          in: suggestion,
          mediaFileURLsByResourceID: mediaFileURLsByResourceID,
          preferredKinds: [.photoImage]
        )
      )

    case .podcast(let id, let episode, let show, _, let date):
      let cleanedEpisode = SuggestionText.cleaned(episode)
      let cleanedShow = SuggestionText.cleaned(show)
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "Podcast",
        symbolName: symbolName,
        title: cleanedEpisode ?? cleanedShow ?? "Podcast",
        subtitle: cleanedEpisode == nil ? nil : cleanedShow,
        metadata: nil,
        date: date,
        titleLineLimit: 2,
        imageFileURL: dominantImageFileURL(
          in: suggestion,
          mediaFileURLsByResourceID: mediaFileURLsByResourceID,
          preferredKinds: [.podcastArtwork]
        )
      )

    case .reflection(let id, let prompt):
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "Reflection",
        symbolName: symbolName,
        title: SuggestionText.cleaned(prompt) ?? "Reflection",
        subtitle: nil,
        metadata: nil,
        date: nil,
        titleLineLimit: 4
      )

    case .song(let id, let title, let artist, let album, _, let date):
      let cleanedTitle = SuggestionText.cleaned(title)
      let cleanedAlbum = SuggestionText.cleaned(album)
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "Song",
        symbolName: symbolName,
        title: cleanedTitle ?? "Song",
        subtitle: SuggestionText.joined([
          artist, cleanedTitle == cleanedAlbum ? nil : cleanedAlbum,
        ]),
        metadata: nil,
        date: date,
        titleLineLimit: 2,
        imageFileURL: dominantImageFileURL(
          in: suggestion,
          mediaFileURLsByResourceID: mediaFileURLsByResourceID,
          preferredKinds: [.songArtwork]
        )
      )

    case .stateOfMind(let id, let value, _):
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "State of Mind",
        symbolName: symbolName,
        title: value.displayTitle,
        subtitle:
          "Valence \(value.valence.formatted(.number.precision(.fractionLength(2))))",
        metadata: value.displayMetadata,
        date: value.date,
        titleLineLimit: 2,
        imageFileURL: dominantImageFileURL(
          in: suggestion,
          mediaFileURLsByResourceID: mediaFileURLsByResourceID,
          preferredKinds: [.stateOfMindIcon]
        ),
        imageStyle: .icon
      )

    case .video(let id, _, let date):
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "Video",
        symbolName: symbolName,
        title: "Video",
        subtitle: nil,
        metadata: nil,
        date: date,
        titleLineLimit: 2
      )

    case .workout(let id, let workout):
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "Workout",
        symbolName: symbolName,
        title: workout.displayTitle,
        subtitle: workout.displaySubtitle,
        metadata: workout.displayMetadata,
        date: workout.details?.dateInterval?.start,
        titleLineLimit: 2,
        imageFileURL: dominantImageFileURL(
          in: suggestion,
          mediaFileURLsByResourceID: mediaFileURLsByResourceID,
          preferredKinds: [.workoutIcon]
        ),
        imageStyle: .icon
      )

    case .workoutGroup(let id, let group):
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "Workouts",
        symbolName: symbolName,
        title: group.displayTitle,
        subtitle: group.displaySubtitle,
        metadata: group.displayMetadata,
        date: group.workouts.compactMap { $0.details?.dateInterval?.start }
          .min(),
        titleLineLimit: 2,
        imageFileURL: dominantImageFileURL(
          in: suggestion,
          mediaFileURLsByResourceID: mediaFileURLsByResourceID,
          preferredKinds: [.workoutGroupIcon]
        ),
        imageStyle: .icon
      )
    }
  }

  private func dominantImageFileURL(
    in suggestion: SuggestionCardPayload,
    mediaFileURLsByResourceID: [UUID: URL],
    preferredKinds: [SuggestionCardMediaResource.Kind]
  ) -> URL? {
    for kind in preferredKinds {
      if let media = suggestion.mediaResources.first(where: {
        $0.elementID == id && $0.kind == kind
      }) {
        if let resourceID = media.resourceID,
          let fileURL = mediaFileURLsByResourceID[resourceID],
          fileURL.isFileURL
        {
          return fileURL
        }

        if let fallbackURL = fallbackImageFileURL(for: kind) {
          return fallbackURL
        }
      }
    }

    for kind in preferredKinds {
      if let fallbackURL = fallbackImageFileURL(for: kind) {
        return fallbackURL
      }
    }

    return nil
  }

  private func fallbackImageFileURL(for kind: SuggestionCardMediaResource.Kind)
    -> URL?
  {
    let fileURL: URL?
    // Keep the payload pattern at the top level. Xcode Preview's design-time
    // rewriter can otherwise turn a nested tuple pattern into an expression.
    switch self {
    case .contact(_, _, let photoURL) where kind == .contactPhoto:
      fileURL = photoURL
    case .eventPoster(_, _, let imageURL, _, _, _, _)
      where kind == .eventPosterImage:
      fileURL = imageURL
    case .genericMedia(_, _, _, _, _, let appIconURL)
      where kind == .genericMediaAppIcon:
      fileURL = appIconURL
    case .livePhoto(_, let imageURL, _, _)
      where kind == .livePhotoImage:
      fileURL = imageURL
    case .motion(_, _, _, let iconURL, _)
      where kind == .motionIcon:
      fileURL = iconURL
    case .photo(_, let imageURL, _)
      where kind == .photoImage:
      fileURL = imageURL
    case .podcast(_, _, _, let artworkURL, _)
      where kind == .podcastArtwork:
      fileURL = artworkURL
    case .song(_, _, _, _, let artworkURL, _)
      where kind == .songArtwork:
      fileURL = artworkURL
    case .stateOfMind(_, _, let iconURL)
      where kind == .stateOfMindIcon:
      fileURL = iconURL
    case .workout(_, let workout)
      where kind == .workoutIcon:
      fileURL = workout.iconURL
    case .workoutGroup(_, let group)
      where kind == .workoutGroupIcon:
      fileURL = group.iconURL
    default:
      fileURL = nil
    }

    guard let fileURL, fileURL.isFileURL else {
      return nil
    }

    return fileURL
  }

  fileprivate var symbolName: String {
    switch self {
    case .contact:
      return "person.crop.circle"
    case .eventPoster:
      return "calendar.badge.clock"
    case .genericMedia:
      return "play.rectangle"
    case .livePhoto:
      return "livephoto"
    case .location:
      return "mappin.and.ellipse"
    case .locationGroup:
      return "map"
    case .motion:
      return "figure.walk"
    case .photo:
      return "photo"
    case .podcast:
      return "podcasts"
    case .reflection:
      return "quote.bubble"
    case .song:
      return "music.note"
    case .stateOfMind:
      return "heart.text.square"
    case .video:
      return "video"
    case .workout:
      return "figure.run"
    case .workoutGroup:
      return "figure.mixed.cardio"
    }
  }
}

extension SuggestionCardMotionMovement {

  fileprivate var displayTitle: String {
    switch self {
    case .running:
      return "Running"
    case .walking:
      return "Walking"
    case .runningWalking:
      return "Running and walking"
    }
  }
}

extension SuggestionCardStateOfMind {

  fileprivate var displayTitle: String {
    if valence >= 0.33 {
      return "Pleasant"
    } else if valence <= -0.33 {
      return "Unpleasant"
    } else {
      return "State of Mind"
    }
  }

  fileprivate var displayMetadata: String? {
    let values = [
      labelRawValues.isEmpty ? nil : "\(labelRawValues.count) labels",
      associationRawValues.isEmpty
        ? nil : "\(associationRawValues.count) associations",
    ]

    return SuggestionText.joined(values)
  }
}

extension SuggestionCardWorkout {

  fileprivate var displayTitle: String {
    SuggestionText.cleaned(details?.localizedName) ?? "Workout"
  }

  fileprivate var displaySubtitle: String? {
    SuggestionText.joined([
      details?.activeEnergyKilocalories.map(Self.kilocalorieText),
      details?.distanceMeters.map(Self.distanceText),
    ])
  }

  fileprivate var displayMetadata: String? {
    details?.averageHeartRateBeatsPerMinute.map(Self.heartRateText)
  }

  private static func kilocalorieText(_ value: Double) -> String {
    "\(Int(value.rounded())) kcal"
  }

  private static func distanceText(_ meters: Double) -> String {
    if meters < 1000 {
      return "\(Int(meters.rounded())) m"
    }

    return String(format: "%.1f km", meters / 1000)
  }

  private static func heartRateText(_ value: Double) -> String {
    "\(Int(value.rounded())) bpm"
  }
}

extension SuggestionCardWorkoutGroup {

  fileprivate var displayTitle: String {
    workouts.count == 1 ? "Workout" : "\(workouts.count) workouts"
  }

  fileprivate var displaySubtitle: String? {
    SuggestionText.joined([
      duration?.formattedDuration,
      activeEnergyKilocalories.map { "\(Int($0.rounded())) kcal" },
    ])
  }

  fileprivate var displayMetadata: String? {
    averageHeartRateBeatsPerMinute.map { "\(Int($0.rounded())) bpm" }
  }
}

extension TimeInterval {

  fileprivate var formattedDuration: String {
    let minutes = Int((self / 60).rounded())
    if minutes < 60 {
      return "\(minutes) min"
    }

    let hours = minutes / 60
    let remainingMinutes = minutes % 60
    return remainingMinutes == 0
      ? "\(hours) hr" : "\(hours) hr \(remainingMinutes) min"
  }
}

#Preview("Suggestion Content") {
  EntryContentPreviewCanvas {
    SuggestionContentView(
      suggestion: SuggestionContentSource(),
      style: .init(.detail)
    )
  }
}
