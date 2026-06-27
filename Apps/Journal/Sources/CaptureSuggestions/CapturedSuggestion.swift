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
  case photo(id: UUID, imageURL: URL, date: Date?)
  case song(id: UUID, title: String?, artist: String?, album: String?, artworkURL: URL?)
  case podcast(id: UUID, episode: String?, show: String?, artworkURL: URL?)
  case media(id: UUID, title: String?, artist: String?, album: String?)
  case workout(id: UUID, name: String?, activeEnergyKilocalories: Double?, distanceMeters: Double?, dateInterval: DateInterval?)
  case location(id: UUID, place: String?, city: String?, coordinate: Coordinate?, date: Date?)
  case motion(id: UUID, steps: Int, dateInterval: DateInterval?)
  case contact(id: UUID, name: String, photoURL: URL?)
  case reflection(id: UUID, prompt: String)

  public var id: UUID {
    switch self {
    case .photo(let id, _, _),
      .song(let id, _, _, _, _),
      .podcast(let id, _, _, _),
      .media(let id, _, _, _),
      .workout(let id, _, _, _, _),
      .location(let id, _, _, _, _),
      .motion(let id, _, _),
      .contact(let id, _, _),
      .reflection(let id, _):
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

  /// Pulls every content type this demo knows about out of a picked suggestion and
  /// flattens them into value-type `SuggestionElement`s.
  ///
  /// `JournalingSuggestion.content(forType:)` is the single entry point: you ask for
  /// a concrete asset type and get back the matching items. The framework exposes
  /// many more types (`Video`, `LivePhoto`, `StateOfMind`, `WorkoutGroup`, …); this
  /// resolves a representative breadth to show how each maps to journaling material.
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

    for photo in await suggestion.content(forType: JournalingSuggestion.Photo.self) {
      elements.append(.photo(id: UUID(), imageURL: photo.photo, date: photo.date))
    }

    for song in await suggestion.content(forType: JournalingSuggestion.Song.self) {
      elements.append(
        .song(
          id: UUID(),
          title: song.song,
          artist: song.artist,
          album: song.album,
          artworkURL: song.artwork
        )
      )
    }

    for podcast in await suggestion.content(forType: JournalingSuggestion.Podcast.self) {
      elements.append(
        .podcast(id: UUID(), episode: podcast.episode, show: podcast.show, artworkURL: podcast.artwork)
      )
    }

    for media in await suggestion.content(forType: JournalingSuggestion.GenericMedia.self) {
      elements.append(.media(id: UUID(), title: media.title, artist: media.artist, album: media.album))
    }

    for workout in await suggestion.content(forType: JournalingSuggestion.Workout.self) {
      let details = workout.details
      elements.append(
        .workout(
          id: UUID(),
          name: details?.localizedName,
          activeEnergyKilocalories: details?.activeEnergyBurned?.doubleValue(for: .kilocalorie()),
          distanceMeters: details?.distance?.doubleValue(for: .meter()),
          dateInterval: details?.date
        )
      )
    }

    for location in await suggestion.content(forType: JournalingSuggestion.Location.self) {
      let coordinate = location.location.map {
        Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
      }
      elements.append(
        .location(id: UUID(), place: location.place, city: location.city, coordinate: coordinate, date: location.date)
      )
    }

    for motion in await suggestion.content(forType: JournalingSuggestion.MotionActivity.self) {
      elements.append(.motion(id: UUID(), steps: motion.steps, dateInterval: motion.date))
    }

    for contact in await suggestion.content(forType: JournalingSuggestion.Contact.self) {
      elements.append(.contact(id: UUID(), name: contact.name, photoURL: contact.photo))
    }

    for reflection in await suggestion.content(forType: JournalingSuggestion.Reflection.self) {
      elements.append(.reflection(id: UUID(), prompt: reflection.prompt))
    }

    return CapturedSuggestion(
      title: suggestion.title,
      dateInterval: suggestion.date,
      elements: elements
    )
  }
}
#endif
