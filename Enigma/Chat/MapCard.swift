import AppKit
import MapKit
import SwiftUI

/// A numbered pin on a reply's map card.
struct MapPin: Equatable, Sendable, Identifiable {
  let number: Int
  let place: MapPlace
  var id: String { place.id }
}

/// The map card under a reply whose evidence included places (spec §6.6).
enum MapCard {
  static let height: CGFloat = 190
  /// The sources panel's row corners.
  static let cornerRadius: CGFloat = 6

  /// Spec §6.6: places named in the reply, in first-mention order; all places when none match.
  /// A name matches as whole words, ignoring case, diacritics and a leading "The". Where one
  /// name sits inside a longer one the reply names ("Joe's Pizza" in "Joe's Pizza Broadway"),
  /// only the longer one counts there.
  static func pins(for places: [MapPlace], reply: String) -> [MapPin] {
    let text = words(reply)
    let occurrences = places.map { place in ranges(of: nameWords(place.name), in: text) }
    var mentions: [(index: Int, start: Int)] = []
    for (index, ranges) in occurrences.enumerated() {
      let first = ranges.first { range in
        !occurrences.enumerated().contains { other, otherRanges in
          other != index && otherRanges.contains {
            $0.count > range.count && $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound
          }
        }
      }
      if let first { mentions.append((index, first.lowerBound)) }
    }
    guard !mentions.isEmpty else {
      return places.enumerated().map { MapPin(number: $0.offset + 1, place: $0.element) }
    }
    return mentions.sorted { ($0.start, $0.index) < ($1.start, $1.index) }
      .enumerated().map { MapPin(number: $0.offset + 1, place: places[$0.element.index]) }
  }

  static func label(count: Int) -> String {
    count == 1 ? "Map of 1 place" : "Map of \(count) places"
  }

  /// "‹n›, ‹name›", plus "‹d› away" near the user.
  static func pinLabel(_ pin: MapPin, units: MeasurementUnits) -> String {
    let label = "\(pin.number), \(pin.place.name)"
    guard let meters = pin.place.distanceMeters else { return label }
    return label + ", " + PlaceSearch.distance(meters, units: units) + " away"
  }

  /// A map rect that fits every pin with a margin, at least about 1 km across, never wider than
  /// the world (pins on opposite sides of the Pacific would otherwise overflow the span).
  static func rect(for pins: [MapPin]) -> MKMapRect {
    let points = pins.map { MKMapPoint(CLLocationCoordinate2D(latitude: $0.place.coordinate.latitude,
                                                               longitude: $0.place.coordinate.longitude)) }
    guard let first = points.first else { return .world }
    let union = points.dropFirst().reduce(MKMapRect(origin: first, size: MKMapSize(width: 0, height: 0))) {
      $0.union(MKMapRect(origin: $1, size: MKMapSize(width: 0, height: 0)))
    }
    let minimum = 1_000 * MKMapPointsPerMeterAtLatitude(first.coordinate.latitude)
    let width = max(union.width * 1.5, minimum), height = max(union.height * 1.5, minimum)
    let padded = MKMapRect(x: union.midX - width / 2, y: union.midY - height / 2, width: width, height: height)
    return padded.intersection(.world)
  }

  private static func words(_ text: String) -> [Substring] {
    text.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "&", with: " and ")
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
      .split { !$0.isLetter && !$0.isNumber }
  }

  /// A name's words without a leading "The"; none for a name with nothing else to match.
  private static func nameWords(_ name: String) -> [Substring] {
    let all = words(name)
    return all.first == "the" ? Array(all.dropFirst()) : all
  }

  private static func ranges(of name: [Substring], in text: [Substring]) -> [Range<Int>] {
    guard !name.isEmpty, name.count <= text.count else { return [] }
    return (0...(text.count - name.count)).compactMap { start in
      text[start..<(start + name.count)].elementsEqual(name) ? start..<(start + name.count) : nil
    }
  }
}

/// Opens places in Apple Maps: the place itself when MapKit finds its identifier in time,
/// otherwise a pin at its coordinate with its name. Inert in the test host.
enum MapCardOpener {
  static let lookUpTime: Duration = .seconds(2)

  @MainActor static func appleMaps(_ places: [MapPlace]) async {
    guard !TestHost.isActive else { return }
    // Started together, read in pin order.
    let lookUps = places.map { place in Task { @MainActor in await mapItem(for: place) } }
    var items: [MKMapItem] = []
    for lookUp in lookUps { items.append(await lookUp.value.item) }
    if items.count == 1 {
      _ = await items[0].openInMaps()
    } else if !items.isEmpty {
      _ = await MKMapItem.openMaps(with: items)
    }
  }

  @MainActor private static func mapItem(for place: MapPlace) async -> MapItemBox {
    if let identifier = MKMapItem.Identifier(rawValue: place.id) {
      let request = MKMapItemRequest(mapItemIdentifier: identifier)
      let found: MapItemBox? = await lookUp(within: lookUpTime, start: { finish in
        request.getMapItem { item, _ in finish(item.map(MapItemBox.init)) }
      }, cancel: { request.cancel() })
      if let found { return found }
    }
    let item = MKMapItem(location: CLLocation(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude),
                         address: nil)
    item.name = place.name
    return MapItemBox(item: item)
  }

  /// Starts a lookup and returns its answer, or nil once `limit` passes, whichever comes first.
  /// MapKit never calls back a request cancelled while loading, so the timer resumes the wait
  /// itself rather than relying on the cancelled request to answer.
  @MainActor static func lookUp<T: Sendable>(within limit: Duration,
                                             start: @MainActor (@escaping @MainActor (T?) -> Void) -> Void,
                                             cancel: @escaping @MainActor () -> Void) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
      MainActor.assumeIsolated {
        let once = ResumeOnce()
        let timer = Task { @MainActor in
          try? await Task.sleep(for: limit)
          guard once.claim() else { return }
          cancel()
          continuation.resume(returning: nil)
        }
        start { value in
          guard once.claim() else { return }
          timer.cancel()
          continuation.resume(returning: value)
        }
      }
    }
  }
}

/// Lets only the first of a lookup's answer and its timer resume the wait.
@MainActor private final class ResumeOnce {
  private var claimed = false
  func claim() -> Bool {
    guard !claimed else { return false }
    claimed = true
    return true
  }
}

/// MapKit's items aren't `Sendable`; this moves them between main-actor tasks only.
private struct MapItemBox: @unchecked Sendable { let item: MKMapItem }

/// One Open in Maps at a time: clicks while one is looking places up are ignored.
@MainActor final class MapCardOpening {
  private(set) var isRunning = false

  func run(_ work: @MainActor () async -> Void) async {
    guard !isRunning else { return }
    isRunning = true
    defer { isRunning = false }
    await work()
  }
}

/// What the card's buttons do, through an opener tests replace.
struct MapCardActions {
  let pins: [MapPin]
  let open: @MainActor ([MapPlace]) async -> Void
  let opening: MapCardOpening

  /// Open in Maps: every pin, in pin order.
  @MainActor func openAll() async { await opening.run { await open(pins.map(\.place)) } }
  /// A pin: that place alone.
  @MainActor func open(_ pin: MapPin) async { await opening.run { await open([pin.place]) } }
}

/// A still Apple map with numbered pins and an Open in Maps button. The live `Map` exists only
/// while the card is on screen, and never in the test host, which gets a placeholder of the same
/// size and labels so no tiles load.
struct MapCardView: View {
  static var drawsLiveMap: Bool { !TestHost.isActive }

  let pins: [MapPin]
  var units: MeasurementUnits = .current
  var open: @MainActor ([MapPlace]) async -> Void = MapCardOpener.appleMaps
  @Environment(\.enigmaPalette) private var palette
  @State private var isOnScreen = false
  @State private var opening = MapCardOpening()

  var actions: MapCardActions { MapCardActions(pins: pins, open: open, opening: opening) }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: MapCard.cornerRadius, style: .continuous)
    VStack(alignment: .trailing, spacing: 4) {
      Group {
        if Self.drawsLiveMap && isOnScreen {
          liveMap
        } else {
          placeholder
        }
      }
      .frame(maxWidth: .infinity)
      .frame(height: MapCard.height)
      .clipShape(shape)
      .overlay { EnigmaEdgeStroke(shape: shape, edge: .hairline) }
      .onScrollVisibilityChange(threshold: 0.01) { isOnScreen = $0 }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(MapCard.label(count: pins.count))
      .enigmaTestMarker("Map card")
      Button("Open in Maps") { Task { await actions.openAll() } }
        .enigmaButtonStyle(.text)
        .accessibilityLabel("Open in Maps")
        .enigmaTestMarker("Open in Maps")
    }
    .frame(maxWidth: .infinity)
  }

  private var liveMap: some View {
    // No pan or zoom, so the map never takes the chat's scrolling; Apple's logo and legal link
    // are the Map's own and nothing covers them.
    Map(initialPosition: .rect(MapCard.rect(for: pins)), interactionModes: []) {
      ForEach(pins) { pin in
        Annotation(pin.place.name, coordinate: CLLocationCoordinate2D(latitude: pin.place.coordinate.latitude,
                                                                      longitude: pin.place.coordinate.longitude)) {
          MapPinButton(pin: pin, label: MapCard.pinLabel(pin, units: units)) { Task { await actions.open(pin) } }
        }
        // The pins' numbers and VoiceOver labels name the places; titles would crowd a small map.
        .annotationTitles(.hidden)
      }
    }
    .mapStyle(.standard)
    .mapControls {}
    .overlay { MapScrollPassThrough() }
  }

  /// In the app, a plain surface while the card is off screen; in the test host, the pins too.
  @ViewBuilder private var placeholder: some View {
    if Self.drawsLiveMap {
      palette.surface.color.accessibilityHidden(true)
    } else {
      testPlaceholder
    }
  }

  private var testPlaceholder: some View {
    ZStack {
      palette.surface.color
      HStack(spacing: 8) {
        ForEach(pins) { pin in
          MapPinButton(pin: pin, label: MapCard.pinLabel(pin, units: units)) { Task { await actions.open(pin) } }
        }
      }
      .padding(12)
    }
  }
}

private struct MapPinButton: View {
  let pin: MapPin
  let label: String
  let action: () -> Void
  @Environment(\.enigmaPalette) private var palette
  @FocusState private var isFocused: Bool

  var body: some View {
    Button(action: action) {
      Text("\(pin.number)")
        .font(EnigmaTypography.mono(11))
        .fontWeight(.semibold)
        .foregroundStyle(palette.background.color)
        .frame(width: 22, height: 22)
        .background(Circle().fill(palette.textPrimary.color))
        .overlay(Circle().strokeBorder(palette.surface.color, lineWidth: 1.5))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .focused($isFocused)
    .focusEffectDisabled()
    .enigmaFocusRing(isFocused, palette: palette, cornerRadius: 11, outset: 2)
    .help(pin.place.name)
    .accessibilityLabel(label)
    .enigmaTestMarker(label)
    .accessibilityHint("Opens in Apple Maps")
  }
}

/// Lets scroll-wheel events over the map reach the chat's scroll view and every other event
/// reach the map, so its pins and legal link still take clicks.
struct MapScrollPassThrough: NSViewRepresentable {
  static func takes(_ type: NSEvent.EventType) -> Bool { type == .scrollWheel }

  func makeNSView(context: Context) -> PassThroughView { PassThroughView() }
  func updateNSView(_ view: PassThroughView, context: Context) {}

  final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
      guard let type = NSApp.currentEvent?.type, MapScrollPassThrough.takes(type) else { return nil }
      return super.hitTest(point)
    }

    override func scrollWheel(with event: NSEvent) {
      if let scrollView = enclosingScrollView {
        scrollView.scrollWheel(with: event)
      } else {
        super.scrollWheel(with: event)
      }
    }

    override func isAccessibilityElement() -> Bool { false }
  }
}
