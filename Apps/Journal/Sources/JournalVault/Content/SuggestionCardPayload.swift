import Foundation

/// A durable snapshot of one Apple Journaling Suggestion selected by the user.
///
/// The app never stores the private signals iOS used to prepare suggestions.
/// This value contains only the suggestion content returned by the system picker
/// after the user chose it. It is intentionally framework-free so the vault
/// store, widgets, and shared preview UI can render saved suggestion cards
/// without linking the device-only `JournalingSuggestions` framework.
public struct SuggestionCardPayload: Codable, Sendable, Equatable {

  /// System-provided title for the selected suggestion.
  public var title: String

  /// Time span associated with the suggestion, when the system provided one.
  public var dateInterval: DateInterval?

  /// Resolved suggestion elements preserved as stable value data.
  public var elements: [SuggestionCardElement]

  /// Media files copied from suggestion elements into the card attachment.
  ///
  /// The element cases keep the system-returned metadata. This collection records
  /// which element media was successfully copied into vault-owned
  /// `AttachmentResource` rows, so synced cards can render from durable files
  /// instead of relying on transient picker URLs.
  public var mediaResources: [SuggestionCardMediaResource]

  public init(
    title: String,
    dateInterval: DateInterval?,
    elements: [SuggestionCardElement],
    mediaResources: [SuggestionCardMediaResource] = []
  ) {
    self.title = title
    self.dateInterval = dateInterval
    self.elements = elements
    self.mediaResources = mediaResources
  }

  private enum CodingKeys: String, CodingKey {
    case title
    case dateInterval
    case elements
    case mediaResources
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.title = try container.decode(String.self, forKey: .title)
    self.dateInterval = try container.decodeIfPresent(DateInterval.self, forKey: .dateInterval)
    self.elements = try container.decode([SuggestionCardElement].self, forKey: .elements)
    self.mediaResources = try container.decodeIfPresent(
      [SuggestionCardMediaResource].self,
      forKey: .mediaResources
    ) ?? []
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(title, forKey: .title)
    try container.encodeIfPresent(dateInterval, forKey: .dateInterval)
    try container.encode(elements, forKey: .elements)
    try container.encode(mediaResources, forKey: .mediaResources)
  }

  /// Whether the selected suggestion contained no resolvable elements.
  public var isEmpty: Bool {
    elements.isEmpty
  }

  /// Encodes the payload for the card's `.suggestion` authored JSON resource.
  public func encodedData() throws -> Data {
    try JSONEncoder().encode(self)
  }

  /// Decodes a suggestion payload from the card's `.suggestion` authored JSON resource.
  public static func decode(from data: Data) -> SuggestionCardPayload? {
    return try? JSONDecoder().decode(SuggestionCardPayload.self, from: data)
  }
}

/// A vault-owned media file copied from a suggestion element.
///
/// `id` is the stable logical identity of this media item inside the suggestion
/// payload. `resourceID` points at the concrete `AttachmentResource` row when
/// the file was successfully copied into the vault; it remains `nil` when the
/// source URL was unavailable at save time.
public struct SuggestionCardMediaResource: Identifiable, Codable, Sendable, Equatable {
  public var id: UUID
  public var elementID: UUID
  public var kind: Kind
  public var resourceID: UUID?
  public var contentType: String?

  public init(
    id: UUID = UUID(),
    elementID: UUID,
    kind: Kind,
    resourceID: UUID? = nil,
    contentType: String? = nil
  ) {
    self.id = id
    self.elementID = elementID
    self.kind = kind
    self.resourceID = resourceID
    self.contentType = contentType
  }
}

extension SuggestionCardMediaResource {

  /// The role this media played in the original suggestion element.
  public enum Kind: String, Codable, Sendable, Equatable, CaseIterable {
    case contactPhoto
    case eventPosterImage
    case genericMediaAppIcon
    case livePhotoImage
    case livePhotoVideo
    case motionIcon
    case photoImage
    case podcastArtwork
    case songArtwork
    case stateOfMindIcon
    case video
    case workoutIcon
    case workoutGroupIcon
  }
}

/// One selected piece of a Journaling Suggestion.
///
/// The cases intentionally mirror the different content shapes iOS can return:
/// raster media references, media metadata, activity summaries, places, people,
/// and reflection prompts are not interchangeable fields in a flat bag.
public enum SuggestionCardElement: Identifiable, Codable, Sendable, Equatable {
  case contact(id: UUID, name: String, photoURL: URL?)
  case eventPoster(
    id: UUID,
    title: String,
    imageURL: URL?,
    eventStart: Date?,
    eventEnd: Date?,
    isHost: Bool?,
    placeName: String?
  )
  case genericMedia(
    id: UUID,
    title: String?,
    artist: String?,
    album: String?,
    date: Date?,
    appIconURL: URL?
  )
  case livePhoto(id: UUID, imageURL: URL, videoURL: URL, date: Date?)
  case location(id: UUID, value: SuggestionCardLocation)
  case locationGroup(id: UUID, locations: [SuggestionCardLocation])
  case motion(
    id: UUID,
    steps: Int,
    dateInterval: DateInterval?,
    iconURL: URL?,
    movementType: SuggestionCardMotionMovement?
  )
  case photo(id: UUID, imageURL: URL, date: Date?)
  case podcast(id: UUID, episode: String?, show: String?, artworkURL: URL?, date: Date?)
  case reflection(id: UUID, prompt: String)
  case song(id: UUID, title: String?, artist: String?, album: String?, artworkURL: URL?, date: Date?)
  case stateOfMind(id: UUID, value: SuggestionCardStateOfMind, iconURL: URL?)
  case video(id: UUID, videoURL: URL, date: Date?)
  case workout(id: UUID, value: SuggestionCardWorkout)
  case workoutGroup(id: UUID, value: SuggestionCardWorkoutGroup)

  public var id: UUID {
    switch self {
    case .contact(let id, _, _),
      .eventPoster(let id, _, _, _, _, _, _),
      .genericMedia(let id, _, _, _, _, _),
      .livePhoto(let id, _, _, _),
      .location(let id, _),
      .locationGroup(let id, _),
      .motion(let id, _, _, _, _),
      .photo(let id, _, _),
      .podcast(let id, _, _, _, _),
      .reflection(let id, _),
      .song(let id, _, _, _, _, _),
      .stateOfMind(let id, _, _),
      .video(let id, _, _),
      .workout(let id, _),
      .workoutGroup(let id, _):
      return id
    }
  }
}

/// Location details returned by a suggestion.
///
/// This is separate from `Card.location`: that field records where the user
/// created the card, while this value records a place that the system suggestion
/// itself mentioned.
public struct SuggestionCardLocation: Codable, Sendable, Equatable {
  public var place: String?
  public var city: String?
  public var coordinate: Coordinate?
  public var date: Date?
  public var isWorkLocation: Bool?

  public init(
    place: String?,
    city: String?,
    coordinate: Coordinate?,
    date: Date?,
    isWorkLocation: Bool?
  ) {
    self.place = place
    self.city = city
    self.coordinate = coordinate
    self.date = date
    self.isWorkLocation = isWorkLocation
  }
}

/// Movement classifier returned by `JournalingSuggestion.MotionActivity`.
public enum SuggestionCardMotionMovement: String, Codable, Sendable, Equatable {
  case running
  case walking
  case runningWalking
}

/// Stable subset of `JournalingSuggestion.Workout.Details`.
///
/// HealthKit objects are not stored directly. Quantities are converted into
/// display-ready base units, and enum values are stored by raw value so widgets
/// and sync code do not need HealthKit.
public struct SuggestionCardWorkoutDetails: Codable, Sendable, Equatable {
  public var activityTypeRawValue: UInt
  public var localizedName: String?
  public var activeEnergyKilocalories: Double?
  public var distanceMeters: Double?
  public var averageHeartRateBeatsPerMinute: Double?
  public var dateInterval: DateInterval?

  public init(
    activityTypeRawValue: UInt,
    localizedName: String?,
    activeEnergyKilocalories: Double?,
    distanceMeters: Double?,
    averageHeartRateBeatsPerMinute: Double?,
    dateInterval: DateInterval?
  ) {
    self.activityTypeRawValue = activityTypeRawValue
    self.localizedName = localizedName
    self.activeEnergyKilocalories = activeEnergyKilocalories
    self.distanceMeters = distanceMeters
    self.averageHeartRateBeatsPerMinute = averageHeartRateBeatsPerMinute
    self.dateInterval = dateInterval
  }
}

/// Stable subset of a workout suggestion, including optional route points.
public struct SuggestionCardWorkout: Codable, Sendable, Equatable {
  public var details: SuggestionCardWorkoutDetails?
  public var iconURL: URL?
  public var route: [Coordinate]

  public init(
    details: SuggestionCardWorkoutDetails?,
    iconURL: URL?,
    route: [Coordinate]
  ) {
    self.details = details
    self.iconURL = iconURL
    self.route = route
  }
}

/// Summary data for a grouped workout suggestion.
public struct SuggestionCardWorkoutGroup: Codable, Sendable, Equatable {
  public var workouts: [SuggestionCardWorkout]
  public var iconURL: URL?
  public var activeEnergyKilocalories: Double?
  public var averageHeartRateBeatsPerMinute: Double?
  public var duration: TimeInterval?

  public init(
    workouts: [SuggestionCardWorkout],
    iconURL: URL?,
    activeEnergyKilocalories: Double?,
    averageHeartRateBeatsPerMinute: Double?,
    duration: TimeInterval?
  ) {
    self.workouts = workouts
    self.iconURL = iconURL
    self.activeEnergyKilocalories = activeEnergyKilocalories
    self.averageHeartRateBeatsPerMinute = averageHeartRateBeatsPerMinute
    self.duration = duration
  }
}

/// Stable subset of a HealthKit state-of-mind sample.
///
/// The HealthKit sample itself and SwiftUI gradient backgrounds are not stored.
/// Raw values keep the saved card independent from HealthKit while preserving the
/// user's selected feeling dimensions.
public struct SuggestionCardStateOfMind: Codable, Sendable, Equatable {
  public var date: Date
  public var kindRawValue: Int
  public var valence: Double
  public var valenceClassificationRawValue: Int
  public var labelRawValues: [Int]
  public var associationRawValues: [Int]

  public init(
    date: Date,
    kindRawValue: Int,
    valence: Double,
    valenceClassificationRawValue: Int,
    labelRawValues: [Int],
    associationRawValues: [Int]
  ) {
    self.date = date
    self.kindRawValue = kindRawValue
    self.valence = valence
    self.valenceClassificationRawValue = valenceClassificationRawValue
    self.labelRawValues = labelRawValues
    self.associationRawValues = associationRawValues
  }
}
