import Foundation

// MARK: - Value

/// An app-domain snapshot of a single Journaling Suggestion the user picked.
///
/// `JournalingSuggestion` is not `Sendable`, and each piece of content it carries
/// has to be pulled asynchronously through `content(forType:)`. This is the
/// flattened, value-type result the journaling UI actually renders — the host
/// decides which elements become a `Card`, attachments, or a writing prompt.
public struct CapturedSuggestion: Sendable, Equatable {
  public var title: String
  public var dateInterval: DateInterval?
  public var elements: [SuggestionElement]

  public init(
    title: String,
    dateInterval: DateInterval?,
    elements: [SuggestionElement]
  ) {
    self.title = title
    self.dateInterval = dateInterval
    self.elements = elements
  }

  public var isEmpty: Bool { elements.isEmpty }
}

/// One resolved piece of a suggestion. The cases carry genuinely different shapes
/// (a photo is a file URL, a song is metadata, a workout is health quantities), so
/// the rendering UI `switch`es over them — this is not a flat data bag.
public enum SuggestionElement: Identifiable, Sendable, Equatable {
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
  case location(id: UUID, value: CapturedSuggestionLocation)
  case locationGroup(id: UUID, locations: [CapturedSuggestionLocation])
  case motion(
    id: UUID,
    steps: Int,
    dateInterval: DateInterval?,
    iconURL: URL?,
    movementType: CapturedSuggestionMovementType?
  )
  case photo(id: UUID, imageURL: URL, date: Date?)
  case podcast(id: UUID, episode: String?, show: String?, artworkURL: URL?, date: Date?)
  case reflection(id: UUID, prompt: String)
  case song(id: UUID, title: String?, artist: String?, album: String?, artworkURL: URL?, date: Date?)
  case stateOfMind(id: UUID, value: CapturedSuggestionStateOfMind, iconURL: URL?)
  case video(id: UUID, videoURL: URL, date: Date?)
  case workout(id: UUID, value: CapturedSuggestionWorkout)
  case workoutGroup(id: UUID, value: CapturedSuggestionWorkoutGroup)

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

/// A plain, `Sendable` latitude/longitude pair. `CLLocationCoordinate2D` is neither
/// `Sendable` nor `Equatable`, so it is unpacked here for the value model.
public struct Coordinate: Sendable, Equatable {
  public var latitude: Double
  public var longitude: Double

  public init(latitude: Double, longitude: Double) {
    self.latitude = latitude
    self.longitude = longitude
  }
}

/// A place mentioned inside a captured suggestion.
///
/// This is not the same as the card's creation location. It describes a place
/// the system surfaced as part of the selected suggestion.
public struct CapturedSuggestionLocation: Sendable, Equatable {
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

/// Movement classifier returned by the system for a motion suggestion.
public enum CapturedSuggestionMovementType: String, Sendable, Equatable {
  case running
  case walking
  case runningWalking
}

/// Stable subset of `JournalingSuggestion.Workout.Details`.
public struct CapturedSuggestionWorkoutDetails: Sendable, Equatable {
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
public struct CapturedSuggestionWorkout: Sendable, Equatable {
  public var details: CapturedSuggestionWorkoutDetails?
  public var iconURL: URL?
  public var route: [Coordinate]

  public init(
    details: CapturedSuggestionWorkoutDetails?,
    iconURL: URL?,
    route: [Coordinate]
  ) {
    self.details = details
    self.iconURL = iconURL
    self.route = route
  }
}

/// Summary data for a grouped workout suggestion.
public struct CapturedSuggestionWorkoutGroup: Sendable, Equatable {
  public var workouts: [CapturedSuggestionWorkout]
  public var iconURL: URL?
  public var activeEnergyKilocalories: Double?
  public var averageHeartRateBeatsPerMinute: Double?
  public var duration: TimeInterval?

  public init(
    workouts: [CapturedSuggestionWorkout],
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
public struct CapturedSuggestionStateOfMind: Sendable, Equatable {
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

// MARK: - Resolution

// `JournalingSuggestions` and `HealthKit` exist only in the device SDK; on the
// Simulator this whole extension compiles out and the picker is never reachable.
//
// `JournalingSuggestions` is also absent from the Mac (Designed for iPad) runtime,
// so it is `@_weakLinked` — autolinking it weakly lets the app launch on Mac where
// the dylib is missing (a strong link would fail in dyld at launch). Its symbols
// are only ever touched from the picker's completion handler, which never runs on
// Mac. `HealthKit` is present in the Mac iOSSupport runtime, so it links normally.
#if canImport(JournalingSuggestions)
import CoreLocation
import HealthKit
@_weakLinked import JournalingSuggestions

extension CapturedSuggestion {

  /// Pulls every supported content type out of a picked suggestion and flattens
  /// it into value-type `SuggestionElement`s.
  ///
  /// `JournalingSuggestion.content(forType:)` is the single entry point: you ask for
  /// a concrete asset type and get back the matching items. This resolver keeps
  /// the app's value model aligned with all public suggestion asset shapes we
  /// currently know how to represent.
  ///
  /// `JournalingSuggestion` is not `Sendable`, and `content(forType:)` is a
  /// nonisolated `async` call from a library-evolution module. The picker delivers
  /// the suggestion on the main actor, so this stays `@MainActor` for a same-actor
  /// hand-off at the call site; taking it as `sending` puts it in a disconnected
  /// region so the repeated off-actor `content(forType:)` `await`s don't trip
  /// region-isolation data-race diagnostics.
  @MainActor
  public static func resolve(from suggestion: sending JournalingSuggestion) async -> CapturedSuggestion {
    var elements: [SuggestionElement] = []

    for contact in await suggestion.content(forType: JournalingSuggestion.Contact.self) {
      elements.append(.contact(id: UUID(), name: contact.name, photoURL: contact.photo))
    }

    for eventPoster in await suggestion.content(forType: JournalingSuggestion.EventPoster.self) {
      elements.append(
        .eventPoster(
          id: UUID(),
          title: String(eventPoster.title.characters),
          imageURL: eventPoster.image,
          eventStart: eventPoster.eventStart,
          eventEnd: eventPoster.eventEnd,
          isHost: eventPoster.isHost,
          placeName: eventPoster.placeName
        )
      )
    }

    for media in await suggestion.content(forType: JournalingSuggestion.GenericMedia.self) {
      elements.append(
        .genericMedia(
          id: UUID(),
          title: media.title,
          artist: media.artist,
          album: media.album,
          date: media.date,
          appIconURL: media.appIcon
        )
      )
    }

    for livePhoto in await suggestion.content(forType: JournalingSuggestion.LivePhoto.self) {
      elements.append(
        .livePhoto(
          id: UUID(),
          imageURL: livePhoto.image,
          videoURL: livePhoto.video,
          date: livePhoto.date
        )
      )
    }

    for location in await suggestion.content(forType: JournalingSuggestion.Location.self) {
      elements.append(.location(id: UUID(), value: capturedLocation(from: location)))
    }

    for locationGroup in await suggestion.content(forType: JournalingSuggestion.LocationGroup.self) {
      elements.append(
        .locationGroup(
          id: UUID(),
          locations: locationGroup.locations.map { capturedLocation(from: $0) }
        )
      )
    }

    for motion in await suggestion.content(forType: JournalingSuggestion.MotionActivity.self) {
      elements.append(
        .motion(
          id: UUID(),
          steps: motion.steps,
          dateInterval: motion.date,
          iconURL: motion.icon,
          movementType: capturedMovementType(from: motion.movementType)
        )
      )
    }

    for photo in await suggestion.content(forType: JournalingSuggestion.Photo.self) {
      elements.append(.photo(id: UUID(), imageURL: photo.photo, date: photo.date))
    }

    for podcast in await suggestion.content(forType: JournalingSuggestion.Podcast.self) {
      elements.append(
        .podcast(
          id: UUID(),
          episode: podcast.episode,
          show: podcast.show,
          artworkURL: podcast.artwork,
          date: podcast.date
        )
      )
    }

    for reflection in await suggestion.content(forType: JournalingSuggestion.Reflection.self) {
      elements.append(.reflection(id: UUID(), prompt: reflection.prompt))
    }

    for song in await suggestion.content(forType: JournalingSuggestion.Song.self) {
      elements.append(
        .song(
          id: UUID(),
          title: song.song,
          artist: song.artist,
          album: song.album,
          artworkURL: song.artwork,
          date: song.date
        )
      )
    }

    for stateOfMind in await suggestion.content(forType: JournalingSuggestion.StateOfMind.self) {
      elements.append(
        .stateOfMind(
          id: UUID(),
          value: capturedStateOfMind(from: stateOfMind.state),
          iconURL: stateOfMind.icon
        )
      )
    }

    for video in await suggestion.content(forType: JournalingSuggestion.Video.self) {
      elements.append(.video(id: UUID(), videoURL: video.url, date: video.date))
    }

    for workout in await suggestion.content(forType: JournalingSuggestion.Workout.self) {
      elements.append(.workout(id: UUID(), value: capturedWorkout(from: workout)))
    }

    for workoutGroup in await suggestion.content(forType: JournalingSuggestion.WorkoutGroup.self) {
      elements.append(
        .workoutGroup(
          id: UUID(),
          value: CapturedSuggestionWorkoutGroup(
            workouts: workoutGroup.workouts.map { capturedWorkout(from: $0) },
            iconURL: workoutGroup.icon,
            activeEnergyKilocalories: workoutGroup.activeEnergyBurned?.doubleValue(for: .kilocalorie()),
            averageHeartRateBeatsPerMinute: workoutGroup.averageHeartRate?.doubleValue(for: heartRateUnit),
            duration: workoutGroup.duration
          )
        )
      )
    }

    return CapturedSuggestion(
      title: suggestion.title,
      dateInterval: suggestion.date,
      elements: elements
    )
  }

  private static var heartRateUnit: HKUnit {
    HKUnit.count().unitDivided(by: HKUnit.minute())
  }

  private static func capturedLocation(
    from location: JournalingSuggestion.Location
  ) -> CapturedSuggestionLocation {
    CapturedSuggestionLocation(
      place: location.place,
      city: location.city,
      coordinate: location.location.map {
        Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
      },
      date: location.date,
      isWorkLocation: location.isWorkLocation
    )
  }

  private static func capturedMovementType(
    from movementType: JournalingSuggestion.MotionActivity.MovementType?
  ) -> CapturedSuggestionMovementType? {
    guard let movementType else { return nil }

    if movementType == .running {
      return .running
    }

    if movementType == .walking {
      return .walking
    }

    if movementType == .runningWalking {
      return .runningWalking
    }

    return nil
  }

  private static func capturedWorkout(
    from workout: JournalingSuggestion.Workout
  ) -> CapturedSuggestionWorkout {
    CapturedSuggestionWorkout(
      details: workout.details.map { capturedWorkoutDetails(from: $0) },
      iconURL: workout.icon,
      route: (workout.route ?? []).map {
        Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
      }
    )
  }

  private static func capturedWorkoutDetails(
    from details: JournalingSuggestion.Workout.Details
  ) -> CapturedSuggestionWorkoutDetails {
    CapturedSuggestionWorkoutDetails(
      activityTypeRawValue: details.activityType.rawValue,
      localizedName: details.localizedName,
      activeEnergyKilocalories: details.activeEnergyBurned?.doubleValue(for: .kilocalorie()),
      distanceMeters: details.distance?.doubleValue(for: .meter()),
      averageHeartRateBeatsPerMinute: details.averageHeartRate?.doubleValue(for: heartRateUnit),
      dateInterval: details.date
    )
  }

  private static func capturedStateOfMind(
    from state: HKStateOfMind
  ) -> CapturedSuggestionStateOfMind {
    CapturedSuggestionStateOfMind(
      date: state.startDate,
      kindRawValue: state.kind.rawValue,
      valence: state.valence,
      valenceClassificationRawValue: state.valenceClassification.rawValue,
      labelRawValues: state.labels.map(\.rawValue),
      associationRawValues: state.associations.map(\.rawValue)
    )
  }
}
#endif
