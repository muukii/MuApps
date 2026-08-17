import AppUIComponents
import JournalVault
import MapKit
import MuColor
import SwiftUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

private let savedLocationsMapHeaderHeight: CGFloat = 136
private let savedLocationsMapCornerRadius: CGFloat = 22
private let savedLocationsMapPreviewPadding: CGFloat = 16

/// Stable display value for one saved card's geographic annotation.
///
/// Map views intentionally receive this detached value instead of live SwiftData
/// models. The selected-vault query owns observation; map rendering only needs a
/// card identity, coordinate, and creation time.
struct VaultSavedLocationPin: Identifiable, Hashable {
  let id: UUID
  let coordinate: JournalVault.Coordinate
  let createdAt: Date
}

/// Tappable geographic header shown before the saved-card day sections.
struct VaultSavedLocationsMapNavigationHeader: View {

  let pins: [VaultSavedLocationPin]
  let transitionNamespace: Namespace.ID

  var body: some View {
    NavigationLink(value: SavedListNavigationRoute.locations) {
      VaultSavedLocationsMapHeader(pins: pins)
    }
    .buttonStyle(.plain)
    .appMatchedTransitionSource(
      id: VaultSavedLocationsMapTransition.id,
      in: transitionNamespace
    )
    .accessibilityLabel("Open Map")
    .accessibilityValue(
      Text(
        "Saved locations: \(pins.count)",
        comment:
          "Accessibility value for the saved-entry map; the variable is the number of location pins."
      )
    )
  }
}

/// Compact, zoomed-in map that keeps the saved cards visible below it.
private struct VaultSavedLocationsMapHeader: View {

  @Environment(\.appPalette) private var palette

  let pins: [VaultSavedLocationPin]

  var body: some View {
    VaultSavedLocationsPlatformMap(
      pins: pins,
      markerColor: palette.tint,
      glyphColor: palette.onTint,
      presentation: .header
    )
    .allowsHitTesting(false)
    .overlay(alignment: .topTrailing) {
      Image(systemName: "arrow.up.left.and.arrow.down.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.appOnPrimaryContainer)
        .frame(width: 32, height: 32)
        .background(.appPrimaryContainer.opacity(0.94), in: Circle())
        .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
        .padding(10)
        .accessibilityHidden(true)
    }
    .frame(height: savedLocationsMapHeaderHeight)
    .clipShape(
      .rect(cornerRadius: savedLocationsMapCornerRadius, style: .continuous)
    )
    .overlay {
      RoundedRectangle(
        cornerRadius: savedLocationsMapCornerRadius,
        style: .continuous
      )
      .stroke(.appOnPrimaryContainer.opacity(0.12), lineWidth: 1)
    }
    .contentShape(
      .rect(cornerRadius: savedLocationsMapCornerRadius, style: .continuous)
    )
  }
}

/// Interactive overview that initially frames every saved-card location pin.
struct VaultSavedLocationsMapView: View {

  @Environment(\.appPalette) private var palette

  let pins: [VaultSavedLocationPin]

  var body: some View {
    VaultSavedLocationsPlatformMap(
      pins: pins,
      markerColor: palette.tint,
      glyphColor: palette.onTint,
      presentation: .overview
    )
    .ignoresSafeArea()
    .navigationTitle("Map")
    .appInlineNavigationTitle()
  }
}

#if canImport(UIKit)
  /// Platform representable protocol used by the clustered map on iOS.
  private typealias VaultSavedLocationsMapRepresentable = UIViewRepresentable
  /// Platform color consumed by MapKit annotation views on iOS.
  private typealias VaultSavedLocationsMapPlatformColor = UIColor
#else
  /// Platform representable protocol used by the clustered map on macOS.
  private typealias VaultSavedLocationsMapRepresentable = NSViewRepresentable
  /// Platform color consumed by MapKit annotation views on macOS.
  private typealias VaultSavedLocationsMapPlatformColor = NSColor
#endif

/// Native MapKit bridge shared by the compact Home header and full overview.
///
/// The presentation owns MapKit interaction and camera policy. SwiftUI keeps
/// navigation and chrome outside this bridge, so the header remains a passive
/// `NavigationLink` label while the overview retains direct map interaction.
private struct VaultSavedLocationsPlatformMap:
  VaultSavedLocationsMapRepresentable
{

  /// Selects the map surface's interaction and camera ownership.
  ///
  /// `.header` follows the newest visible pin without accepting gestures.
  /// `.overview` fits the first non-empty dataset once, then preserves the
  /// user's camera while cards or filters update the annotations.
  enum Presentation: Sendable {
    case header
    case overview
  }

  let pins: [VaultSavedLocationPin]
  let markerColor: Color
  let glyphColor: Color
  let presentation: Presentation

  func makeCoordinator() -> VaultSavedLocationsMapCoordinator {
    VaultSavedLocationsMapCoordinator()
  }

  #if canImport(UIKit)
    func makeUIView(context: Context) -> MKMapView {
      makeMapView(context: context)
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
      update(mapView, context: context)
    }

    static func dismantleUIView(
      _ mapView: MKMapView,
      coordinator: VaultSavedLocationsMapCoordinator
    ) {
      mapView.delegate = nil
    }
  #else
    func makeNSView(context: Context) -> MKMapView {
      makeMapView(context: context)
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
      update(mapView, context: context)
    }

    static func dismantleNSView(
      _ mapView: MKMapView,
      coordinator: VaultSavedLocationsMapCoordinator
    ) {
      mapView.delegate = nil
    }
  #endif

  private func makeMapView(context: Context) -> MKMapView {
    let mapView = MKMapView(frame: .zero)
    context.coordinator.install(on: mapView)
    update(mapView, context: context)
    return mapView
  }

  private func update(_ mapView: MKMapView, context: Context) {
    context.coordinator.update(
      pins: pins,
      markerColor: platformColor(markerColor),
      glyphColor: platformColor(glyphColor),
      presentation: presentation,
      on: mapView
    )
  }

  private func platformColor(_ color: Color)
    -> VaultSavedLocationsMapPlatformColor
  {
    #if canImport(UIKit)
      UIColor(color)
    #else
      NSColor(color)
    #endif
  }
}

/// MapKit delegate and annotation store shared by both saved-locations maps.
@MainActor
private final class VaultSavedLocationsMapCoordinator: NSObject,
  MKMapViewDelegate
{

  private static let pinReuseIdentifier = "VaultSavedLocationPin"
  private static let clusteringIdentifier = "VaultSavedLocation"
  private static let overviewEdgePadding: CGFloat = 48

  private var annotationsByID: [UUID: VaultSavedLocationMapPoint] = [:]
  private var hasFittedInitialPins = false
  private var lastHeaderFocus: HeaderFocus?
  private var markerColor: VaultSavedLocationsMapPlatformColor
  private var glyphColor: VaultSavedLocationsMapPlatformColor

  override init() {
    #if canImport(UIKit)
      markerColor = .systemBlue
      glyphColor = .white
    #else
      markerColor = .controlAccentColor
      glyphColor = .white
    #endif
    super.init()
  }

  func install(on mapView: MKMapView) {
    mapView.delegate = self
    mapView.preferredConfiguration = MKStandardMapConfiguration(
      elevationStyle: .flat
    )
    mapView.register(
      VaultSavedLocationMarkerAnnotationView.self,
      forAnnotationViewWithReuseIdentifier: Self.pinReuseIdentifier
    )
    mapView.register(
      VaultSavedLocationClusterAnnotationView.self,
      forAnnotationViewWithReuseIdentifier:
        MKMapViewDefaultClusterAnnotationViewReuseIdentifier
    )
  }

  func update(
    pins: [VaultSavedLocationPin],
    markerColor: VaultSavedLocationsMapPlatformColor,
    glyphColor: VaultSavedLocationsMapPlatformColor,
    presentation: VaultSavedLocationsPlatformMap.Presentation,
    on mapView: MKMapView
  ) {
    self.markerColor = markerColor
    self.glyphColor = glyphColor
    configureInteraction(for: presentation, on: mapView)

    let desiredIDs = Set(pins.map(\.id))
    let removedAnnotations = annotationsByID.compactMap { id, annotation in
      desiredIDs.contains(id) ? nil : annotation
    }
    for annotation in removedAnnotations {
      annotationsByID[annotation.id] = nil
    }
    mapView.removeAnnotations(removedAnnotations)

    var newAnnotations: [VaultSavedLocationMapPoint] = []
    for pin in pins {
      if let annotation = annotationsByID[pin.id] {
        annotation.update(from: pin)
      } else {
        let annotation = VaultSavedLocationMapPoint(pin: pin)
        annotationsByID[pin.id] = annotation
        newAnnotations.append(annotation)
      }
    }
    mapView.addAnnotations(newAnnotations)
    refreshVisibleAnnotationViews(on: mapView)

    switch presentation {
    case .header:
      recenterHeaderIfNeeded(for: pins.first, on: mapView)
    case .overview:
      guard hasFittedInitialPins == false, pins.isEmpty == false else { return }
      fitInitialPins(pins, on: mapView)
      hasFittedInitialPins = true
    }
  }

  private func configureInteraction(
    for presentation: VaultSavedLocationsPlatformMap.Presentation,
    on mapView: MKMapView
  ) {
    switch presentation {
    case .header:
      mapView.isScrollEnabled = false
      mapView.isZoomEnabled = false
      mapView.isPitchEnabled = false
      mapView.isRotateEnabled = false
      mapView.showsCompass = false
      mapView.showsScale = false
      #if canImport(AppKit)
        mapView.showsZoomControls = false
        mapView.showsPitchControl = false
      #endif
    case .overview:
      mapView.isScrollEnabled = true
      mapView.isZoomEnabled = true
      mapView.isPitchEnabled = true
      mapView.isRotateEnabled = true
    }
  }

  private func recenterHeaderIfNeeded(
    for pin: VaultSavedLocationPin?,
    on mapView: MKMapView
  ) {
    guard let pin else { return }

    let focus = HeaderFocus(pin: pin)
    guard focus != lastHeaderFocus else { return }

    mapView.setRegion(
      VaultSavedLocationsMapCamera.headerRegion(for: pin),
      animated: false
    )
    lastHeaderFocus = focus
  }

  func mapView(
    _ mapView: MKMapView,
    viewFor annotation: any MKAnnotation
  ) -> MKAnnotationView? {
    guard annotation is MKUserLocation == false else { return nil }

    if let cluster = annotation as? MKClusterAnnotation {
      guard
        let view = mapView.dequeueReusableAnnotationView(
          withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier,
          for: cluster
        ) as? VaultSavedLocationClusterAnnotationView
      else {
        return nil
      }
      configure(view, for: cluster)
      return view
    }

    guard let point = annotation as? VaultSavedLocationMapPoint,
      let view = mapView.dequeueReusableAnnotationView(
        withIdentifier: Self.pinReuseIdentifier,
        for: point
      ) as? VaultSavedLocationMarkerAnnotationView
    else {
      return nil
    }
    configure(view, for: point)
    return view
  }

  private func configure(
    _ view: MKMarkerAnnotationView,
    for annotation: any MKAnnotation
  ) {
    view.markerTintColor = markerColor
    view.glyphTintColor = glyphColor
    view.canShowCallout = false
    view.collisionMode = .circle

    if let cluster = annotation as? MKClusterAnnotation {
      view.clusteringIdentifier = nil
      view.displayPriority = .required
      view.glyphImage = nil
      view.glyphText = cluster.memberAnnotations.count.formatted()
      setAccessibilityLabel(
        String(localized: "Saved entries: \(cluster.memberAnnotations.count)"),
        on: view
      )
    } else {
      view.clusteringIdentifier = Self.clusteringIdentifier
      view.displayPriority = .defaultHigh
      view.glyphText = nil
      #if canImport(UIKit)
        view.glyphImage = UIImage(systemName: "mappin")
      #else
        view.glyphImage = NSImage(
          systemSymbolName: "mappin",
          accessibilityDescription: String(localized: "Saved Entry")
        )
      #endif
      setAccessibilityLabel(String(localized: "Saved Entry"), on: view)
    }
  }

  private func refreshVisibleAnnotationViews(on mapView: MKMapView) {
    for annotation in mapView.annotations {
      guard let view = mapView.view(for: annotation) as? MKMarkerAnnotationView
      else {
        continue
      }
      configure(view, for: annotation)
    }
  }

  private func fitInitialPins(
    _ pins: [VaultSavedLocationPin],
    on mapView: MKMapView
  ) {
    if pins.count == 1, let pin = pins.first {
      mapView.setRegion(
        VaultSavedLocationsMapCamera.singlePinRegion(for: pin),
        animated: false
      )
      return
    }

    guard let mapRect = VaultSavedLocationsMapCamera.overviewMapRect(for: pins)
    else {
      return
    }

    #if canImport(UIKit)
      let edgePadding = UIEdgeInsets(
        top: Self.overviewEdgePadding,
        left: Self.overviewEdgePadding,
        bottom: Self.overviewEdgePadding,
        right: Self.overviewEdgePadding
      )
    #else
      let edgePadding = NSEdgeInsets(
        top: Self.overviewEdgePadding,
        left: Self.overviewEdgePadding,
        bottom: Self.overviewEdgePadding,
        right: Self.overviewEdgePadding
      )
    #endif
    mapView.setVisibleMapRect(
      mapRect,
      edgePadding: edgePadding,
      animated: false
    )
  }

  private func setAccessibilityLabel(
    _ label: String,
    on view: MKAnnotationView
  ) {
    #if canImport(UIKit)
      view.accessibilityLabel = label
    #else
      view.setAccessibilityLabel(label)
    #endif
  }

  /// Header camera input that changes only when its visible newest pin changes.
  private struct HeaderFocus: Equatable {
    let id: UUID
    let latitude: CLLocationDegrees
    let longitude: CLLocationDegrees

    init(pin: VaultSavedLocationPin) {
      id = pin.id
      latitude = pin.coordinate.latitude
      longitude = pin.coordinate.longitude
    }
  }
}

/// Mutable MapKit annotation retained across SwiftUI representable updates.
private nonisolated final class VaultSavedLocationMapPoint: MKPointAnnotation {

  let id: UUID
  private(set) var createdAt: Date

  init(pin: VaultSavedLocationPin) {
    id = pin.id
    createdAt = pin.createdAt
    super.init()
    update(from: pin)
  }

  func update(from pin: VaultSavedLocationPin) {
    if coordinate.latitude != pin.coordinate.latitude
      || coordinate.longitude != pin.coordinate.longitude
    {
      coordinate = pin.coordinate.clCoordinate
    }
    createdAt = pin.createdAt
    title = String(localized: "Saved Entry")
  }
}

/// Reusable marker view that opts each saved-card annotation into clustering.
private final class VaultSavedLocationMarkerAnnotationView:
  MKMarkerAnnotationView
{

  override init(
    annotation: (any MKAnnotation)?,
    reuseIdentifier: String?
  ) {
    super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
    clusteringIdentifier = "VaultSavedLocation"
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    clusteringIdentifier = "VaultSavedLocation"
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    clusteringIdentifier = "VaultSavedLocation"
    glyphImage = nil
    glyphText = nil
  }
}

/// Count marker produced automatically when saved-card annotations collide.
private final class VaultSavedLocationClusterAnnotationView:
  MKMarkerAnnotationView
{

  override func prepareForDisplay() {
    super.prepareForDisplay()
    clusteringIdentifier = nil
    glyphImage = nil
    if let cluster = annotation as? MKClusterAnnotation {
      let memberCount = cluster.memberAnnotations.count
      let accessibilityLabel = String(
        localized: "Saved entries: \(memberCount)"
      )
      glyphText = memberCount.formatted()
      #if canImport(UIKit)
        self.accessibilityLabel = accessibilityLabel
      #else
        setAccessibilityLabel(accessibilityLabel)
      #endif
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    glyphImage = nil
    glyphText = nil
  }
}

/// Camera policies for the zoomed header and the all-pins overview.
private enum VaultSavedLocationsMapCamera {

  private static let headerSpanMeters: CLLocationDistance = 1_200
  private static let minimumOverviewSpanMeters: CLLocationDistance = 1_200
  private static let overviewPaddingScale: Double = 1.5

  static func headerRegion(for pin: VaultSavedLocationPin) -> MKCoordinateRegion {
    MKCoordinateRegion(
      center: pin.coordinate.clCoordinate,
      latitudinalMeters: headerSpanMeters,
      longitudinalMeters: headerSpanMeters
    )
  }

  static func singlePinRegion(for pin: VaultSavedLocationPin)
    -> MKCoordinateRegion
  {
    MKCoordinateRegion(
      center: pin.coordinate.clCoordinate,
      latitudinalMeters: minimumOverviewSpanMeters,
      longitudinalMeters: minimumOverviewSpanMeters
    )
  }

  static func overviewMapRect(for pins: [VaultSavedLocationPin]) -> MKMapRect? {
    guard let firstPin = pins.first, pins.count > 1 else { return nil }

    let pinRect = pins.reduce(into: MKMapRect.null) { mapRect, pin in
      let point = MKMapPoint(pin.coordinate.clCoordinate)
      let pointRect = MKMapRect(x: point.x, y: point.y, width: 1, height: 1)
      mapRect = mapRect.union(pointRect)
    }
    let minimumSpan =
      minimumOverviewSpanMeters
      * MKMapPointsPerMeterAtLatitude(firstPin.coordinate.latitude)
    let width = max(pinRect.width * overviewPaddingScale, minimumSpan)
    let height = max(pinRect.height * overviewPaddingScale, minimumSpan)

    return MKMapRect(
      x: pinRect.midX - width / 2,
      y: pinRect.midY - height / 2,
      width: width,
      height: height
    )
  }
}

/// Stable transition identity shared by the map header and overview.
enum VaultSavedLocationsMapTransition {
  static let id = "saved-locations-map"
}

#Preview("Saved Locations Map Header") {
  PrimaryContainer(accentColor: .default) {
    ScrollView {
      VaultSavedLocationsMapHeader(
        pins: VaultSavedLocationsMapPreviewFixtures.pins
      )
      .padding(savedLocationsMapPreviewPadding)
    }
    .background(.background)
  }
}

#Preview("Saved Locations Map Overview") {
  PrimaryContainer(accentColor: .default) {
    NavigationStack {
      VaultSavedLocationsMapView(
        pins: VaultSavedLocationsMapPreviewFixtures.pins
      )
    }
  }
}

#Preview("Saved Locations Map Dense Header") {
  PrimaryContainer(accentColor: .default) {
    ScrollView {
      VaultSavedLocationsMapHeader(
        pins: VaultSavedLocationsMapPreviewFixtures.densePins
      )
      .padding(savedLocationsMapPreviewPadding)
    }
    .background(.background)
  }
}

/// In-memory locations used only to validate map composition in Preview.
private enum VaultSavedLocationsMapPreviewFixtures {

  static let pins: [VaultSavedLocationPin] = [
    VaultSavedLocationPin(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      coordinate: Coordinate(latitude: 35.6812, longitude: 139.7671),
      createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000)
    ),
    VaultSavedLocationPin(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
      coordinate: Coordinate(latitude: 35.6830, longitude: 139.7650),
      createdAt: Date(timeIntervalSinceReferenceDate: 799_996_400)
    ),
    VaultSavedLocationPin(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
      coordinate: Coordinate(latitude: 35.7148, longitude: 139.7745),
      createdAt: Date(timeIntervalSinceReferenceDate: 799_992_800)
    ),
  ]

  /// Coincident and nearby points make the native cluster marker visible when
  /// Preview happens to render the MapKit surface; this is not runtime proof.
  static let densePins: [VaultSavedLocationPin] = [
    VaultSavedLocationPin(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
      coordinate: Coordinate(latitude: 35.6812, longitude: 139.7671),
      createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000)
    ),
    VaultSavedLocationPin(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
      coordinate: Coordinate(latitude: 35.6812, longitude: 139.7671),
      createdAt: Date(timeIntervalSinceReferenceDate: 799_996_400)
    ),
    VaultSavedLocationPin(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
      coordinate: Coordinate(latitude: 35.6813, longitude: 139.7672),
      createdAt: Date(timeIntervalSinceReferenceDate: 799_992_800)
    ),
  ]
}
