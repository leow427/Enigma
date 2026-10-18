import SwiftUI

// Shared controls for the new UI. Each reads its colors from the environment's
// `enigmaPalette`, so it follows Paper and Ink. Later phases add what they need
// here rather than making local copies.

// MARK: Shared behavior

enum EnigmaControlStyle {
  /// Disabled controls fade rather than change color.
  static let disabledOpacity = 0.45
  /// The keyboard focus ring, in `accent`.
  static let focusRingWidth: CGFloat = 2
  /// Presses spring without overshoot, so a quick click never wobbles.
  static let press = EnigmaMotion.menu

  /// How much a control shrinks while pressed. Reduce Motion keeps it still.
  static func pressScale(isPressed: Bool, reduceMotion: Bool, amount: CGFloat = 0.97) -> CGFloat {
    isPressed && !reduceMotion ? amount : 1
  }
}

extension EnigmaColor {
  /// This color at `opacity`, for drawing a token at another strength.
  func withOpacity(_ opacity: Double) -> EnigmaColor {
    EnigmaColor(red: red, green: green, blue: blue, opacity: min(1, max(0, opacity)))
  }
}

/// The two kinds of line the new UI draws around and between things.
enum EnigmaEdge {
  /// Row dividers.
  case hairline
  /// Window, field, menu, and outlined-button edges.
  case border

  /// Under Increase Contrast, hairlines and borders both use `border` at
  /// double opacity.
  func color(in palette: EnigmaPalette, increasedContrast: Bool) -> EnigmaColor {
    if increasedContrast { return palette.border.withOpacity(palette.border.opacity * 2) }
    return self == .hairline ? palette.hairline : palette.border
  }
}

extension View {
  /// A rounded `accent` ring drawn `outset` points outside the view while
  /// `isVisible`. The gap keeps it visible around an `accent`-filled button.
  func enigmaFocusRing(_ isVisible: Bool, palette: EnigmaPalette,
                                   cornerRadius: CGFloat, outset: CGFloat = 3) -> some View {
    overlay {
      if isVisible {
        RoundedRectangle(cornerRadius: cornerRadius + outset, style: .continuous)
          .strokeBorder(palette.accent.color, lineWidth: EnigmaControlStyle.focusRingWidth)
          .padding(-outset)
          .allowsHitTesting(false)
      }
    }
  }
}

// MARK: Buttons

enum EnigmaButtonKind: Sendable {
  /// The one `accent`-filled button in a view.
  case primary
  /// Outlined in `border`.
  case secondary
  /// Plain text, like Back.
  case text

  func fill(in palette: EnigmaPalette, isHovered: Bool) -> EnigmaColor? {
    switch self {
    case .primary: palette.accent
    case .secondary, .text: isHovered ? palette.hover : nil
    }
  }

  func label(in palette: EnigmaPalette, isHovered: Bool) -> EnigmaColor {
    switch self {
    case .primary: palette.onAccent
    case .secondary: palette.textPrimary
    case .text: isHovered ? palette.textPrimary : palette.textSecondary
    }
  }

  var edge: EnigmaEdge? { self == .secondary ? .border : nil }

  var font: Font {
    switch self {
    case .primary: EnigmaTypography.ui(14, weight: .medium)
    case .secondary: EnigmaTypography.ui(12.5, weight: .medium)
    case .text: EnigmaTypography.ui(13, weight: .medium)
    }
  }

  var padding: EdgeInsets {
    switch self {
    case .primary: EdgeInsets(top: 9, leading: 18, bottom: 9, trailing: 18)
    case .secondary: EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12)
    case .text: EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8)
    }
  }

  var cornerRadius: CGFloat { self == .primary ? 11 : 8 }
}

/// Primary, secondary, and text buttons. Apply with `.enigmaButtonStyle(_:)`,
/// which tracks keyboard focus and replaces the system focus ring with the
/// `accent` one.
struct EnigmaButtonStyle: ButtonStyle {
  let kind: EnigmaButtonKind
  /// Whether the button has keyboard focus, from the `@FocusState` that
  /// `.enigmaButtonStyle(_:)` binds to it.
  var isFocused = false

  func makeBody(configuration: Configuration) -> some View {
    EnigmaButtonBody(kind: kind, isFocused: isFocused, configuration: configuration)
  }
}

private struct EnigmaButtonBody: View {
  let kind: EnigmaButtonKind
  let isFocused: Bool
  let configuration: ButtonStyleConfiguration
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.displayScale) private var displayScale
  @State private var isHovered = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: kind.cornerRadius, style: .continuous)
    let hovered = isHovered && isEnabled
    configuration.label
      .font(kind.font)
      .lineLimit(1)
      .foregroundStyle(kind.label(in: palette, isHovered: hovered).color)
      .padding(kind.padding)
      .background {
        if let fill = kind.fill(in: palette, isHovered: hovered) { shape.fill(fill.color) }
      }
      .overlay {
        if let edge = kind.edge {
          shape.strokeBorder(edge.color(in: palette, increasedContrast: contrast == .increased).color,
                             lineWidth: 1 / displayScale)
        }
      }
      .contentShape(shape)
      .opacity(isEnabled ? 1 : EnigmaControlStyle.disabledOpacity)
      .scaleEffect(EnigmaControlStyle.pressScale(isPressed: configuration.isPressed, reduceMotion: reduceMotion))
      .enigmaFocusRing(isFocused && isEnabled, palette: palette, cornerRadius: kind.cornerRadius)
      .animation(reduceMotion ? nil : EnigmaControlStyle.press.animation, value: configuration.isPressed)
      .onHover { isHovered = $0 }
  }
}

extension View {
  /// Styles a `Button` or `Link` as one of the new UI's buttons.
  func enigmaButtonStyle(_ kind: EnigmaButtonKind) -> some View {
    modifier(EnigmaButtonStyleModifier(kind: kind))
  }

  /// A noninteractive native marker named `name` behind this view, which hosted
  /// tests use to find and click real controls. App views supply none.
  func enigmaTestMarker(_ name: String) -> some View {
    modifier(EnigmaTestMarkerModifier(name: name))
  }
}

extension EnvironmentValues {
  /// Set only by hosted tests, as with Screen's control markers.
  @Entry var enigmaTestMarker: (@MainActor @Sendable (String) -> AnyView)? = nil
}

private struct EnigmaTestMarkerModifier: ViewModifier {
  let name: String
  @Environment(\.enigmaTestMarker) private var marker

  func body(content: Content) -> some View {
    content.background { marker?(name) }
  }
}

/// Focus comes from `@FocusState` bound to the button itself, the documented
/// way to read a control's keyboard focus, rather than from the environment
/// inside the style.
private struct EnigmaButtonStyleModifier: ViewModifier {
  let kind: EnigmaButtonKind
  @FocusState private var isFocused: Bool

  func body(content: Content) -> some View {
    content
      .buttonStyle(EnigmaButtonStyle(kind: kind, isFocused: isFocused))
      .focused($isFocused)
      .focusEffectDisabled()
  }
}

// MARK: Keycap and hint

/// A key, such as `↵` on a primary button. It takes the color of its context.
struct EnigmaKeycap: View {
  let key: String

  init(_ key: String) { self.key = key }

  var body: some View {
    Text(key)
      .font(EnigmaTypography.mono(12))
      .opacity(0.8)
      .accessibilityHidden(true)
  }
}

/// A monospace hint, like "next: pick a local model".
struct EnigmaHint: View {
  let text: String
  @Environment(\.enigmaPalette) private var palette

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(EnigmaTypography.mono(11))
      .foregroundStyle(palette.textTertiary.color)
  }
}

// MARK: Command line

/// `› command   description`, set like a terminal line. Modifier and key
/// symbols in the command use the system font, which draws them properly.
struct EnigmaCommandLine: View {
  let command: String
  let description: String
  /// Wide enough for `/screen /search /edit` in SF Mono.
  var commandWidth: CGFloat? = 166
  @Environment(\.enigmaPalette) private var palette

  /// Symbols drawn in the system font rather than the monospace one.
  static let symbols: Set<Character> = ["⌥", "⌃", "⌘", "⇧", "↵", "↑", "↓", "⎋"]

  /// `command` split into runs, each marked as symbols or plain text.
  static func runs(_ command: String) -> [(text: String, isSymbol: Bool)] {
    var runs: [(text: String, isSymbol: Bool)] = []
    for character in command {
      let isSymbol = symbols.contains(character)
      if let last = runs.last, last.isSymbol == isSymbol {
        runs[runs.count - 1].text.append(character)
      } else {
        runs.append((String(character), isSymbol))
      }
    }
    return runs
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("›").foregroundStyle(palette.textTertiary.color).accessibilityHidden(true)
      // Separate texts, so each run's font is certain: key symbols in the
      // system font, like the mockup's sans spans, and the rest in mono.
      HStack(alignment: .firstTextBaseline, spacing: 0) {
        ForEach(Array(Self.runs(command).enumerated()), id: \.offset) { _, run in
          // Non-breaking spaces, so a space at the edge of a run still takes room.
          Text(run.text.replacingOccurrences(of: " ", with: "\u{00A0}"))
            .font(run.isSymbol ? EnigmaTypography.ui(13, weight: .medium) : EnigmaTypography.mono(12, weight: .medium))
        }
      }
      .foregroundStyle(palette.accentText.color)
      .lineLimit(1)
      .frame(width: commandWidth, alignment: .leading)
      Text(description)
        .foregroundStyle(palette.textSecondary.color)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .font(EnigmaTypography.mono(12))
    .padding(.vertical, 6)
    .accessibilityElement(children: .combine)
  }
}

// MARK: Text field

/// A one-line field: an opaque `surface`, a `border` edge, and an `accent`
/// ring while focused.
struct EnigmaTextField: View {
  let placeholder: String
  @Binding var text: String
  var isSecure = false
  /// What VoiceOver calls the field, when the placeholder alone is ambiguous.
  var accessibilityLabel: String?
  var onFocusChange: (Bool) -> Void = { _ in }
  var onSubmit: () -> Void = {}
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.displayScale) private var displayScale
  @FocusState private var isFocused: Bool

  init(_ placeholder: String, text: Binding<String>, isSecure: Bool = false, accessibilityLabel: String? = nil,
       onFocusChange: @escaping (Bool) -> Void = { _ in }, onSubmit: @escaping () -> Void = {}) {
    self.placeholder = placeholder
    _text = text
    self.isSecure = isSecure
    self.accessibilityLabel = accessibilityLabel
    self.onFocusChange = onFocusChange
    self.onSubmit = onSubmit
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    ZStack(alignment: .leading) {
      if text.isEmpty {
        Text(placeholder)
          .foregroundStyle(palette.textTertiary.color)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
      field
        .textFieldStyle(.plain)
        .foregroundStyle(palette.textPrimary.color)
        .tint(palette.accent.color)
        .focused($isFocused)
        .onSubmit(onSubmit)
        .accessibilityLabel(accessibilityLabel ?? placeholder)
    }
    .font(EnigmaTypography.ui(13))
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(palette.surface.color, in: shape)
    .overlay {
      shape.strokeBorder(EnigmaEdge.border.color(in: palette, increasedContrast: contrast == .increased).color,
                         lineWidth: 1 / displayScale)
    }
    .enigmaFocusRing(isFocused, palette: palette, cornerRadius: 8, outset: 0)
    .opacity(isEnabled ? 1 : EnigmaControlStyle.disabledOpacity)
    .onChange(of: isFocused) { _, focused in onFocusChange(focused) }
  }

  @ViewBuilder private var field: some View {
    if isSecure {
      SecureField("", text: $text)
    } else {
      TextField("", text: $text)
    }
  }
}

// MARK: Rows

/// A small caption above a group of rows, like "Good fits for this Mac".
struct EnigmaSectionHeader: View {
  let title: String
  @Environment(\.enigmaPalette) private var palette

  init(_ title: String) { self.title = title }

  var body: some View {
    Text(title)
      .font(EnigmaTypography.ui(11.5, weight: .medium))
      .foregroundStyle(palette.textTertiary.color)
      .padding(.top, 20)
      .padding(.bottom, 4)
      .accessibilityAddTraits(.isHeader)
  }
}

/// The divider between rows, one pixel tall.
struct EnigmaHairline: View {
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.displayScale) private var displayScale

  var body: some View {
    Rectangle()
      .fill(EnigmaEdge.hairline.color(in: palette, increasedContrast: contrast == .increased).color)
      .frame(height: 1 / displayScale)
      .accessibilityHidden(true)
  }
}

/// The small `accentText` dot that marks the selected row.
struct EnigmaSelectionDot: View {
  let isSelected: Bool
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Circle()
      .fill(palette.accentText.color)
      .frame(width: 6, height: 6)
      .scaleEffect(isSelected || reduceMotion ? 1 : 0.3)
      .opacity(isSelected ? 1 : 0)
      // Settles without a bounce: only switches and the character bounce.
      .animation(reduceMotion ? nil : EnigmaMotion.rowEnter.animation, value: isSelected)
      .accessibilityHidden(true)
  }
}

/// A plain row with a hairline above it: a title, an optional subtitle and
/// details, optional trailing content, and an optional selection dot. With an
/// action, the whole row is a button that Tab can reach. Like `Button(action:)`,
/// the action is passed with its `action:` label; a trailing closure is always
/// the trailing content.
struct EnigmaRow<Detail: View, Trailing: View>: View {
  let title: String
  var badge: String?
  var subtitle: String?
  /// Nil hides the dot. Otherwise the row is one choice in a list.
  var selection: Bool?
  var action: (() -> Void)?
  @ViewBuilder var detail: () -> Detail
  @ViewBuilder var trailing: () -> Trailing
  @Environment(\.enigmaPalette) private var palette
  @FocusState private var isFocused: Bool

  init(_ title: String, badge: String? = nil, subtitle: String? = nil, selection: Bool? = nil,
       action: (() -> Void)? = nil, @ViewBuilder detail: @escaping () -> Detail,
       @ViewBuilder trailing: @escaping () -> Trailing) {
    self.title = title
    self.badge = badge
    self.subtitle = subtitle
    self.selection = selection
    self.action = action
    self.detail = detail
    self.trailing = trailing
  }

  /// A choice row's title is darker when selected.
  static func titleColor(selection: Bool?, in palette: EnigmaPalette) -> EnigmaColor {
    selection == false ? palette.textSecondary : palette.textPrimary
  }

  var body: some View {
    Group {
      if let action {
        Button(action: action) { content.contentShape(Rectangle()) }
          .buttonStyle(EnigmaRowButtonStyle(isFocused: isFocused))
          .focused($isFocused)
          .focusEffectDisabled()
          .accessibilityAddTraits(selection == true ? [.isSelected] : [])
      } else {
        content
      }
    }
    .overlay(alignment: .top) { EnigmaHairline() }
    .enigmaTestMarker(title)
  }

  private var content: some View {
    HStack(alignment: .center, spacing: 14) {
      if let selection {
        EnigmaSelectionDot(isSelected: selection).frame(width: 8)
      }
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(title)
            .font(EnigmaTypography.ui(13.5, weight: .medium))
            .foregroundStyle(Self.titleColor(selection: selection, in: palette).color)
          if let badge {
            Text(badge)
              .font(EnigmaTypography.mono(11))
              .foregroundStyle(palette.accentText.color)
          }
        }
        if let subtitle {
          Text(subtitle)
            .font(EnigmaTypography.ui(12))
            .foregroundStyle(palette.textSecondary.color)
            .fixedSize(horizontal: false, vertical: true)
        }
        detail()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      trailing()
    }
    .padding(.vertical, 10)
  }
}

extension EnigmaRow where Detail == EmptyView {
  init(_ title: String, badge: String? = nil, subtitle: String? = nil, selection: Bool? = nil,
       action: (() -> Void)? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
    self.init(title, badge: badge, subtitle: subtitle, selection: selection, action: action,
              detail: { EmptyView() }, trailing: trailing)
  }
}

extension EnigmaRow where Detail == EmptyView, Trailing == EmptyView {
  /// The defaulted `trailing` keeps a trailing closure from ever binding to
  /// `action`: the action always needs its label.
  init(_ title: String, badge: String? = nil, subtitle: String? = nil, selection: Bool? = nil,
       action: (() -> Void)? = nil, @ViewBuilder trailing: @escaping () -> EmptyView = { EmptyView() }) {
    self.init(title, badge: badge, subtitle: subtitle, selection: selection, action: action,
              detail: { EmptyView() }, trailing: trailing)
  }
}

/// A clickable row: a hover fill, a slight press, and the focus ring.
private struct EnigmaRowButtonStyle: ButtonStyle {
  let isFocused: Bool

  func makeBody(configuration: Configuration) -> some View {
    EnigmaRowButtonBody(isFocused: isFocused, configuration: configuration)
  }
}

private struct EnigmaRowButtonBody: View {
  let isFocused: Bool
  let configuration: ButtonStyleConfiguration
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovered = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    configuration.label
      .background {
        if isHovered && isEnabled { shape.fill(palette.hover.color).padding(.horizontal, -8) }
      }
      .opacity(isEnabled ? 1 : EnigmaControlStyle.disabledOpacity)
      .scaleEffect(EnigmaControlStyle.pressScale(isPressed: configuration.isPressed, reduceMotion: reduceMotion,
                                                 amount: 0.99))
      .overlay {
        if isFocused && isEnabled {
          shape.strokeBorder(palette.accent.color, lineWidth: EnigmaControlStyle.focusRingWidth)
            .padding(.horizontal, -8)
            .allowsHitTesting(false)
        }
      }
      .animation(reduceMotion ? nil : EnigmaControlStyle.press.animation, value: configuration.isPressed)
      .onHover { isHovered = $0 }
  }
}

// MARK: Status line

/// A monospace state, like `● connected` or `○ not connected`.
struct EnigmaStatusLine: View {
  enum Status: Equatable, Sendable {
    case on, off, busy, problem

    var glyph: String {
      switch self {
      case .on: "●"
      case .off: "○"
      case .busy: "◌"
      case .problem: "!"
      }
    }

    /// People read these, so only `on` uses the accent; the rest use readable text colors.
    func color(in palette: EnigmaPalette) -> EnigmaColor {
      switch self {
      case .on: palette.accentText
      case .off, .busy: palette.textSecondary
      case .problem: palette.textPrimary
      }
    }
  }

  let status: Status
  let text: String
  @Environment(\.enigmaPalette) private var palette

  init(_ status: Status, _ text: String) {
    self.status = status
    self.text = text
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(status.glyph).fontWeight(status == .problem ? .bold : .regular)
      Text(text).fixedSize(horizontal: false, vertical: true)
    }
    .font(EnigmaTypography.mono(11.5))
    .foregroundStyle(status.color(in: palette).color)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(text)
    .enigmaTestMarker(text)
  }
}

// MARK: Note and progress

/// Supporting text under a group of rows, in `textSecondary` because people read it.
struct EnigmaNote: View {
  let text: String
  @Environment(\.enigmaPalette) private var palette

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(EnigmaTypography.ui(12))
      .foregroundStyle(palette.textSecondary.color)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A thin progress bar: a `border` track with an `accentText` fill. A nil
/// width fills the space it's given.
struct EnigmaProgressBar: View {
  let fraction: Double
  var width: CGFloat? = 120
  var label = "Download progress"
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let clamped = min(1, max(0, fraction))
    Capsule()
      .fill(EnigmaEdge.border.color(in: palette, increasedContrast: contrast == .increased).color)
      .overlay(alignment: .leading) {
        GeometryReader { proxy in
          Capsule().fill(palette.accentText.color).frame(width: proxy.size.width * clamped)
        }
      }
      .frame(width: width, height: 4)
      .frame(maxWidth: width == nil ? .infinity : nil)
      .animation(reduceMotion ? nil : EnigmaMotion.pageChange.animation, value: clamped)
      .accessibilityElement()
      .accessibilityLabel(label)
      .accessibilityValue("\(Int(clamped * 100)) percent")
  }
}

// MARK: Choices

/// One choice in a segmented control or a menu.
struct EnigmaOption<Value: Hashable>: Identifiable {
  let value: Value
  let title: String
  var detail: String?
  var isEnabled = true

  var id: Value { value }

  init(_ value: Value, _ title: String, detail: String? = nil, isEnabled: Bool = true) {
    self.value = value
    self.title = title
    self.detail = detail
    self.isEnabled = isEnabled
  }
}

// MARK: Switch

/// An on/off switch with a spring knob. It has no visible label, since the row
/// beside it shows one, but VoiceOver reads it as a switch with `label` and
/// its value.
struct EnigmaSwitch: View {
  let label: String
  @Binding var isOn: Bool
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.displayScale) private var displayScale
  @FocusState private var isFocused: Bool

  init(_ label: String, isOn: Binding<Bool>) {
    self.label = label
    _isOn = isOn
  }

  static let trackSize = CGSize(width: 32, height: 19)
  static let knobDiameter: CGFloat = 15
  static let knobInset: CGFloat = 2
  /// How far the knob travels from off to on.
  static var knobTravel: CGFloat { trackSize.width - knobDiameter - 2 * knobInset }

  /// `accent` when on. Off, the track is the `border` color, at double
  /// opacity under Increase Contrast.
  static func trackColor(isOn: Bool, in palette: EnigmaPalette, increasedContrast: Bool) -> EnigmaColor {
    isOn ? palette.accent : EnigmaEdge.border.color(in: palette, increasedContrast: increasedContrast)
  }

  /// Off, the knob is the palette's lightest neutral, like the mockup's white
  /// knob. On the filled track it is `onAccent`, like text on the accent.
  static func knobColor(isOn: Bool, in palette: EnigmaPalette) -> EnigmaColor {
    if isOn { return palette.onAccent }
    return palette.menu.relativeLuminance >= palette.textPrimary.relativeLuminance ? palette.menu : palette.textPrimary
  }

  static func knobOffset(isOn: Bool) -> CGFloat { isOn ? knobTravel : 0 }

  /// The knob springs with a small bounce. Reduce Motion moves it instantly.
  static func knobAnimation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : EnigmaMotion.switchKnob.animation
  }

  var body: some View {
    let increased = contrast == .increased
    Button { isOn.toggle() } label: {
      Capsule()
        .fill(Self.trackColor(isOn: isOn, in: palette, increasedContrast: increased).color)
        .frame(width: Self.trackSize.width, height: Self.trackSize.height)
        .overlay(alignment: .leading) {
          Circle()
            .fill(Self.knobColor(isOn: isOn, in: palette).color)
            .overlay {
              Circle().strokeBorder(EnigmaEdge.border.color(in: palette, increasedContrast: increased).color,
                                    lineWidth: 1 / displayScale)
            }
            .frame(width: Self.knobDiameter, height: Self.knobDiameter)
            .padding(Self.knobInset)
            .offset(x: Self.knobOffset(isOn: isOn))
            .animation(Self.knobAnimation(reduceMotion: reduceMotion), value: isOn)
        }
        // The track's color changes without a bounce.
        .animation(reduceMotion ? nil : EnigmaMotion.pageChange.animation, value: isOn)
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .focused($isFocused)
    .focusEffectDisabled()
    .enigmaFocusRing(isFocused && isEnabled, palette: palette, cornerRadius: Self.trackSize.height / 2)
    .opacity(isEnabled ? 1 : EnigmaControlStyle.disabledOpacity)
    .accessibilityRepresentation {
      Toggle(label, isOn: $isOn).toggleStyle(.switch)
    }
    .enigmaTestMarker("\(label) switch")
  }
}

// MARK: Segmented text control

/// A choice between a few options written as words, like System / Paper /
/// Ink. The chosen word is darker and underlined in `accentText`.
struct EnigmaSegmentedControl<Value: Hashable>: View {
  let label: String
  @Binding var selection: Value
  let options: [EnigmaOption<Value>]
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var underline

  init(_ label: String, selection: Binding<Value>, options: [EnigmaOption<Value>]) {
    self.label = label
    _selection = selection
    self.options = options
  }

  var body: some View {
    HStack(spacing: 14) {
      ForEach(options) { option in
        EnigmaSegment(title: option.title, isSelected: option.value == selection, namespace: underline) {
          selection = option.value
        }
        .disabled(!option.isEnabled)
        .enigmaTestMarker("\(label): \(option.title)")
      }
    }
    // The underline slides without overshoot; Reduce Motion moves it at once.
    .animation(reduceMotion ? nil : EnigmaMotion.pageChange.animation, value: selection)
    .accessibilityRepresentation {
      Picker(label, selection: $selection) {
        ForEach(options) { option in Text(option.title).tag(option.value) }
      }
      .pickerStyle(.segmented)
    }
  }
}

enum EnigmaSegmentStyle {
  /// Every option is readable; the chosen one and a hovered one are darker.
  static func titleColor(isSelected: Bool, isHovered: Bool, in palette: EnigmaPalette) -> EnigmaColor {
    isSelected || isHovered ? palette.textPrimary : palette.textSecondary
  }
}

private struct EnigmaSegment: View {
  let title: String
  let isSelected: Bool
  let namespace: Namespace.ID
  let action: () -> Void
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.isEnabled) private var isEnabled
  @FocusState private var isFocused: Bool
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(EnigmaTypography.ui(13))
        .foregroundStyle(EnigmaSegmentStyle.titleColor(isSelected: isSelected, isHovered: isHovered && isEnabled,
                                                      in: palette).color)
        .padding(.vertical, 2)
        .overlay(alignment: .bottom) {
          if isSelected {
            Rectangle()
              .fill(palette.accentText.color)
              .frame(height: 1.5)
              .matchedGeometryEffect(id: "underline", in: namespace)
          }
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focused($isFocused)
    .focusEffectDisabled()
    .enigmaFocusRing(isFocused && isEnabled, palette: palette, cornerRadius: 3)
    .opacity(isEnabled ? 1 : EnigmaControlStyle.disabledOpacity)
    .onHover { isHovered = $0 }
  }
}

// MARK: Menu

/// One row of an opaque menu.
struct EnigmaMenuItem: Identifiable {
  let id: AnyHashable
  let title: String
  var detail: String?
  var isSelected = false
  var isEnabled = true
  let action: () -> Void

  /// Everything a row shows, so an open menu can tell when its rows change.
  struct Signature: Hashable {
    let id: AnyHashable
    let title: String
    let detail: String?
    let isSelected: Bool
    let isEnabled: Bool
  }

  var signature: Signature {
    Signature(id: id, title: title, detail: detail, isSelected: isSelected, isEnabled: isEnabled)
  }
}

/// A group of menu rows, with an optional caption above them.
struct EnigmaMenuSection {
  var title: String?
  var items: [EnigmaMenuItem]

  init(_ title: String? = nil, items: [EnigmaMenuItem]) {
    self.title = title
    self.items = items
  }

  /// What the sections show, for noticing changes while the menu is open.
  static func signature(of sections: [EnigmaMenuSection]) -> [[AnyHashable]] {
    sections.map { section in [AnyHashable(section.title)] + section.items.map { AnyHashable($0.signature) } }
  }

  /// Rows that pick one of `options` for `selection`, with a dot on the current one.
  static func choosing<Value: Hashable>(_ options: [EnigmaOption<Value>], selection: Binding<Value>,
                                        title: String? = nil) -> EnigmaMenuSection {
    EnigmaMenuSection(title, items: options.map { option in
      EnigmaMenuItem(id: AnyHashable(option.value), title: option.title, detail: option.detail,
                     isSelected: option.value == selection.wrappedValue, isEnabled: option.isEnabled) {
        selection.wrappedValue = option.value
      }
    })
  }
}

/// Where an open menu sits: below its trigger, or above it when there's more
/// room there, and lined up with whichever edge of the trigger keeps it in the
/// window. Offsets are from the container's matching corner.
struct EnigmaMenuPlacement: Equatable {
  static let gap: CGFloat = 4
  static let margin: CGFloat = 8
  /// Below this much room underneath, a menu opens upward if there's more room above.
  static let preferredRoomBelow: CGFloat = 220

  let opensUpward: Bool
  let alignsTrailing: Bool
  /// Taller menus scroll inside this height.
  let maximumHeight: CGFloat
  let offset: CGSize
  /// The corner the menu grows from, in the container's unit space.
  let scaleAnchor: UnitPoint

  init(anchor: CGRect, container: CGSize) {
    let below = container.height - anchor.maxY - Self.gap - Self.margin
    let above = anchor.minY - Self.gap - Self.margin
    opensUpward = below < Self.preferredRoomBelow && above > below
    alignsTrailing = anchor.midX > container.width / 2
    maximumHeight = max(0, opensUpward ? above : below)
    let x = alignsTrailing ? -(container.width - anchor.maxX) : anchor.minX
    let y = opensUpward ? -(container.height - anchor.minY + Self.gap) : anchor.maxY + Self.gap
    offset = CGSize(width: x, height: y)
    let cornerX = alignsTrailing ? anchor.maxX : anchor.minX
    let cornerY = opensUpward ? anchor.minY - Self.gap : anchor.maxY + Self.gap
    scaleAnchor = UnitPoint(x: container.width > 0 ? cornerX / container.width : 0,
                            y: container.height > 0 ? cornerY / container.height : 0)
  }

  var alignment: Alignment {
    switch (opensUpward, alignsTrailing) {
    case (false, false): .topLeading
    case (false, true): .topTrailing
    case (true, false): .bottomLeading
    case (true, true): .bottomTrailing
    }
  }
}

/// Shows one open menu above everything inside `.enigmaMenuHost()`.
@MainActor
final class EnigmaMenuPresenter: ObservableObject {
  nonisolated static let coordinateSpace = "EnigmaMenuHost"

  struct Presentation {
    let id: UUID
    let label: String
    /// The trigger's frame in the host's coordinate space.
    var anchor: CGRect
    var minimumWidth: CGFloat
    var sections: [EnigmaMenuSection]
    /// Runs whenever the menu closes, however it closes, so the trigger can
    /// take keyboard focus back.
    var onDismiss: (() -> Void)?
  }

  @Published private(set) var presentation: Presentation?

  func present(_ presentation: Presentation) { self.presentation = presentation }

  /// While menu `id` is open, its trigger keeps it in step: where the trigger
  /// is, and what the rows show.
  func update(_ id: UUID, anchor: CGRect? = nil, sections: [EnigmaMenuSection]? = nil) {
    guard var current = presentation, current.id == id else { return }
    if let anchor {
      current.anchor = anchor
      current.minimumWidth = max(anchor.width, current.minimumWidth)
    }
    if let sections { current.sections = sections }
    presentation = current
  }

  /// Closes the open menu, or only the menu `id` when one is given, and hands
  /// focus back to its trigger. A trigger that has gone away passes
  /// `restoringFocus: false`.
  func dismiss(_ id: UUID? = nil, restoringFocus: Bool = true) {
    guard let current = presentation, id == nil || current.id == id else { return }
    presentation = nil
    if restoringFocus { current.onDismiss?() }
  }
}

extension EnvironmentValues {
  /// Set by `.enigmaMenuHost()`.
  @Entry var enigmaMenuPresenter: EnigmaMenuPresenter? = nil
}

extension View {
  /// Lets the `EnigmaMenu`s inside this view open above all of it, unclipped
  /// by scroll views. Apply it once at a window or sheet root.
  func enigmaMenuHost() -> some View {
    modifier(EnigmaMenuHostModifier())
  }
}

private struct EnigmaMenuHostModifier: ViewModifier {
  @StateObject private var presenter = EnigmaMenuPresenter()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .environment(\.enigmaMenuPresenter, presenter)
      .coordinateSpace(.named(EnigmaMenuPresenter.coordinateSpace))
      .overlay {
        GeometryReader { proxy in
          ZStack {
            if let presentation = presenter.presentation {
              // A click anywhere outside closes the menu, as a native menu does.
              Button { presenter.dismiss() } label: {
                Color.clear.contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .focusable(false)
              .accessibilityHidden(true)
              let placement = EnigmaMenuPlacement(anchor: presentation.anchor, container: proxy.size)
              EnigmaMenuList(presentation: presentation, maximumHeight: placement.maximumHeight) {
                presenter.dismiss(presentation.id)
              }
              .offset(placement.offset)
              .frame(width: proxy.size.width, height: proxy.size.height, alignment: placement.alignment)
              .transition(reduceMotion ? .opacity
                : .scale(scale: 0.96, anchor: placement.scaleAnchor).combined(with: .opacity))
              .id(presentation.id)
            }
          }
          // Menus open from their trigger without overshoot. Reduce Motion fades.
          .animation(reduceMotion ? .easeOut(duration: 0.12) : EnigmaMotion.menu.animation,
                     value: presenter.presentation?.id)
        }
      }
  }
}

/// The open menu: an opaque `menu` surface with a `border` edge. Arrow keys
/// move, Return or Space picks, and Escape closes.
private struct EnigmaMenuList: View {
  let presentation: EnigmaMenuPresenter.Presentation
  let maximumHeight: CGFloat
  let dismiss: () -> Void
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.displayScale) private var displayScale
  @State private var highlighted: AnyHashable?
  @State private var contentHeight: CGFloat?
  @FocusState private var isFocused: Bool

  /// A first guess at the rows' height, until they've been measured.
  private var estimatedHeight: CGFloat {
    let items = presentation.sections.reduce(0) { $0 + $1.items.count }
    let captions = presentation.sections.filter { $0.title != nil }.count
    return CGFloat(items) * 31 + CGFloat(captions) * 22 + CGFloat(max(0, presentation.sections.count - 1)) * 9 + 10
  }

  private var enabledItems: [EnigmaMenuItem] {
    presentation.sections.flatMap(\.items).filter(\.isEnabled)
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    // The menu hugs its rows, and scrolls when they're taller than the room it has.
    ScrollView {
      rows.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
    }
    .scrollBounceBehavior(.basedOnSize)
    .frame(height: min(contentHeight ?? estimatedHeight, maximumHeight))
    .frame(minWidth: presentation.minimumWidth, maxWidth: 360, alignment: .topLeading)
    .fixedSize(horizontal: true, vertical: false)
    .background(palette.menu.color, in: shape)
    .clipShape(shape)
    .overlay {
      shape.strokeBorder(EnigmaEdge.border.color(in: palette, increasedContrast: contrast == .increased).color,
                         lineWidth: 1 / displayScale)
    }
    .focusable()
    .focused($isFocused)
    .focusEffectDisabled()
    .onAppear {
      highlighted = enabledItems.first(where: \.isSelected)?.id ?? enabledItems.first?.id
      isFocused = true
    }
    .onKeyPress(.downArrow) { move(by: 1); return .handled }
    .onKeyPress(.upArrow) { move(by: -1); return .handled }
    // Key handlers run inside a view update, so what they change waits a turn.
    .onKeyPress(.return) { Task { activateHighlighted() }; return .handled }
    .onKeyPress(.space) { Task { activateHighlighted() }; return .handled }
    .onKeyPress(.escape) { Task { dismiss() }; return .handled }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(presentation.label)
    .accessibilityAction(.escape) { dismiss() }
  }

  private var rows: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(presentation.sections.enumerated()), id: \.offset) { index, section in
        if index > 0 { EnigmaHairline().padding(.vertical, 4) }
        if let title = section.title {
          Text(title)
            .font(EnigmaTypography.ui(11.5, weight: .medium))
            .foregroundStyle(palette.textTertiary.color)
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
        }
        ForEach(section.items) { item in row(item) }
      }
    }
    .padding(5)
  }

  private func row(_ item: EnigmaMenuItem) -> some View {
    Button {
      item.action()
      dismiss()
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        EnigmaSelectionDot(isSelected: item.isSelected).frame(width: 8)
        VStack(alignment: .leading, spacing: 1) {
          Text(item.title)
            .font(EnigmaTypography.ui(13))
            .foregroundStyle(palette.textPrimary.color)
            .lineLimit(1)
          if let detail = item.detail {
            Text(detail)
              .font(EnigmaTypography.mono(11))
              .foregroundStyle(palette.textTertiary.color)
              .lineLimit(1)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background {
        if highlighted == item.id && item.isEnabled {
          RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.hover.color)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!item.isEnabled)
    .opacity(item.isEnabled ? 1 : EnigmaControlStyle.disabledOpacity)
    .onHover { if $0 { highlighted = item.id } }
    .accessibilityAddTraits(item.isSelected ? [.isSelected] : [])
    .enigmaTestMarker("Menu item \(item.title)")
  }

  private func move(by step: Int) {
    let items = enabledItems
    guard !items.isEmpty else { return }
    let current = items.firstIndex { $0.id == highlighted }
    let next = current.map { min(max($0 + step, 0), items.count - 1) } ?? (step > 0 ? 0 : items.count - 1)
    highlighted = items[next].id
  }

  private func activateHighlighted() {
    guard let item = enabledItems.first(where: { $0.id == highlighted }) else { return }
    item.action()
    dismiss()
  }
}

/// How a menu's trigger looks: outlined like a secondary button in Settings
/// rows, or plain text for places like the composer.
enum EnigmaMenuTriggerStyle: Sendable {
  case field
  case plain
}

/// A trigger that opens an opaque menu from itself, springing with
/// `EnigmaMotion.menu`. Inside `.enigmaMenuHost()` the menu draws above the
/// whole window; without a host it opens in place. Build a picker with
/// `init(_:selection:options:)`, or pass sections of items for any other menu.
struct EnigmaMenu<Label: View>: View {
  let title: String
  let sections: [EnigmaMenuSection]
  var style: EnigmaMenuTriggerStyle = .field
  var accessibilityValue: String?
  @ViewBuilder let label: () -> Label
  @Environment(\.enigmaMenuPresenter) private var presenter
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.isEnabled) private var isEnabled
  @State private var id = UUID()
  @State private var anchor: CGRect = .zero
  @State private var isOpenInPlace = false
  /// Counts the times a closed menu asked for focus back.
  @State private var focusReturnRequest = 0
  @FocusState private var isFocused: Bool

  init(_ title: String, sections: [EnigmaMenuSection], style: EnigmaMenuTriggerStyle = .field,
       accessibilityValue: String? = nil, @ViewBuilder label: @escaping () -> Label) {
    self.title = title
    self.sections = sections
    self.style = style
    self.accessibilityValue = accessibilityValue
    self.label = label
  }

  var body: some View {
    // The Button takes clicks; the focusable container around it holds focus
    // and answers Space and Return. A Button alone can't hold focus while the
    // Mac's keyboard navigation is off, and a closed menu hands focus back
    // here so the next Tab continues from the trigger.
    HStack(spacing: 0) {
      Button(action: toggle) {
        HStack(spacing: 6) {
          label()
          Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(palette.textTertiary.color)
            .accessibilityHidden(true)
        }
        .modifier(EnigmaMenuTriggerChrome(style: style, isFocused: isFocused))
      }
      .buttonStyle(.plain)
      .focusable(false)
    }
    // All interactions, not just activation, which would follow the
    // keyboard navigation setting like a Button.
    .focusable(isEnabled)
    .focused($isFocused)
    .focusEffectDisabled()
    .onKeyPress(.space) { Task { toggle() }; return .handled }
    .onKeyPress(.return) { Task { toggle() }; return .handled }
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { toggle() }
    .onGeometryChange(for: CGRect.self) { proxy in
      proxy.frame(in: .named(EnigmaMenuPresenter.coordinateSpace))
    } action: { anchor = $0 }
    .overlay(alignment: .topLeading) {
      if isOpenInPlace {
        EnigmaMenuList(presentation: presentation, maximumHeight: 320) {
          isOpenInPlace = false
          focusReturnRequest += 1
        }
        .offset(y: anchor.height + EnigmaMenuPlacement.gap)
      }
    }
    .zIndex(isOpenInPlace ? 1 : 0)
    // An open menu follows its trigger and shows its current rows.
    .onChange(of: anchor) { _, anchor in presenter?.update(id, anchor: anchor) }
    .onChange(of: EnigmaMenuSection.signature(of: sections)) { _, _ in presenter?.update(id, sections: sections) }
    .onDisappear { presenter?.dismiss(id, restoringFocus: false) }
    // Once the closing list has given focus up, it comes back here.
    .task(id: focusReturnRequest) {
      guard focusReturnRequest > 0 else { return }
      await Task.yield()
      isFocused = true
    }
    .accessibilityLabel(title)
    .accessibilityValue(accessibilityValue ?? "")
    .accessibilityHint("Opens a menu")
    .enigmaTestMarker(title)
  }

  private var presentation: EnigmaMenuPresenter.Presentation {
    let returnFocus = $focusReturnRequest
    return EnigmaMenuPresenter.Presentation(id: id, label: title, anchor: anchor,
                                            minimumWidth: max(anchor.width, 160), sections: sections,
                                            onDismiss: { returnFocus.wrappedValue += 1 })
  }

  private func toggle() {
    guard isEnabled else { return }
    guard let presenter else {
      isOpenInPlace.toggle()
      return
    }
    if presenter.presentation?.id == id {
      presenter.dismiss(id)
    } else {
      presenter.present(presentation)
    }
  }
}

/// The current choice's title, as a picker trigger shows it.
struct EnigmaMenuValueLabel: View {
  let text: String

  var body: some View {
    Text(text).lineLimit(1).truncationMode(.middle)
  }
}

extension EnigmaMenu where Label == EnigmaMenuValueLabel {
  /// A picker: the trigger shows the current choice, and the menu marks it
  /// with a dot. `placeholder` shows when nothing matches `selection`.
  init<Value: Hashable>(_ title: String, selection: Binding<Value>, options: [EnigmaOption<Value>],
                        placeholder: String = "Choose", style: EnigmaMenuTriggerStyle = .field) {
    self.init(title, selection: selection, sections: [(nil, options)], placeholder: placeholder, style: style)
  }

  /// A picker whose choices are grouped under captions, like local and cloud models.
  init<Value: Hashable>(_ title: String, selection: Binding<Value>,
                        sections: [(title: String?, options: [EnigmaOption<Value>])],
                        placeholder: String = "Choose", style: EnigmaMenuTriggerStyle = .field) {
    let selected = sections.lazy.flatMap(\.options).first { $0.value == selection.wrappedValue }?.title
    self.init(title, sections: sections.map { EnigmaMenuSection.choosing($0.options, selection: selection, title: $0.title) },
              style: style, accessibilityValue: selected) {
      EnigmaMenuValueLabel(text: selected ?? placeholder)
    }
  }
}

/// The trigger's look: outlined or plain, with a hover fill, the disabled
/// fade, and the `accent` focus ring.
private struct EnigmaMenuTriggerChrome: ViewModifier {
  let style: EnigmaMenuTriggerStyle
  let isFocused: Bool
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.displayScale) private var displayScale
  @State private var isHovered = false

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    content
      .font(EnigmaTypography.ui(12.5, weight: .medium))
      .foregroundStyle(palette.textPrimary.color)
      .padding(.vertical, style == .field ? 5 : 3)
      .padding(.leading, style == .field ? 10 : 6)
      .padding(.trailing, style == .field ? 8 : 6)
      .background {
        if isHovered && isEnabled { shape.fill(palette.hover.color) }
      }
      .overlay {
        if style == .field {
          shape.strokeBorder(EnigmaEdge.border.color(in: palette, increasedContrast: contrast == .increased).color,
                             lineWidth: 1 / displayScale)
        }
      }
      .contentShape(shape)
      .opacity(isEnabled ? 1 : EnigmaControlStyle.disabledOpacity)
      .enigmaFocusRing(isFocused && isEnabled, palette: palette, cornerRadius: 8)
      .onHover { isHovered = $0 }
  }
}

// MARK: Disclosure

/// A text button that shows or hides more content, with a chevron that turns.
struct EnigmaDisclosure<Content: View>: View {
  let title: String
  @ViewBuilder let content: () -> Content
  @State private var isExpanded: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(_ title: String, isExpanded: Bool = false, @ViewBuilder content: @escaping () -> Content) {
    self.title = title
    self.content = content
    _isExpanded = State(initialValue: isExpanded)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Button {
        withAnimation(reduceMotion ? nil : EnigmaMotion.pageChange.animation) { isExpanded.toggle() }
      } label: {
        HStack(spacing: 5) {
          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .accessibilityHidden(true)
          Text(title)
        }
      }
      .enigmaButtonStyle(.text)
      .padding(.leading, -8)
      .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
      .enigmaTestMarker(title)
      if isExpanded {
        content().transition(.opacity)
      }
    }
  }
}

// MARK: Previews

#if DEBUG
private struct EnigmaControlsPreview: View {
  @Environment(\.enigmaPalette) private var palette
  @State private var key = ""
  @State private var selected = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 12) {
        Button {} label: { HStack(spacing: 10) { Text("Get started"); EnigmaKeycap("↵") } }
          .enigmaButtonStyle(.primary)
        Button("Sign in") {}.enigmaButtonStyle(.secondary)
        Button("Back") {}.enigmaButtonStyle(.text)
        Button("Disabled") {}.enigmaButtonStyle(.secondary).disabled(true)
      }
      EnigmaHint("next: pick a local model, about a minute")
      VStack(alignment: .leading, spacing: 0) {
        EnigmaCommandLine(command: "⌥⌃ in any app", description: "opens over what you're doing")
        EnigmaCommandLine(command: "/screen /search /edit", description: "do things, not just chat")
      }
      EnigmaTextField("Brave API key", text: $key, isSecure: true).frame(width: 260)
      VStack(spacing: 0) {
        ForEach(0..<3) { index in
          EnigmaRow("Choice \(index + 1)", badge: index == 0 ? "recommended" : nil,
                    subtitle: "A short description", selection: selected == index, action: { selected = index })
        }
        EnigmaRow("Claude", subtitle: "Through your Claude plan") {
          EnigmaStatusLine(.on, "connected")
        }
        EnigmaRow("ChatGPT", subtitle: "Through your ChatGPT plan") {
          EnigmaStatusLine(.off, "not connected")
        }
        EnigmaHairline()
      }
      EnigmaStatusLine(.busy, "finish signing in in your browser")
      EnigmaStatusLine(.problem, "The download couldn't be verified.")
    }
    .padding(28)
    .frame(width: 520)
    .background(palette.background.color)
  }
}

/// The settings controls: a switch, the text segmented control, a menu, a
/// secure field, a disclosure, a note, and progress.
private struct EnigmaSettingsControlsPreview: View {
  @Environment(\.enigmaPalette) private var palette
  @State private var isOn = true
  @State private var isOff = false
  @State private var appearance = EnigmaAppearance.system
  @State private var provider = "Claude"
  @State private var key = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      EnigmaSectionHeader("Look")
      EnigmaRow("Appearance") {
        EnigmaSegmentedControl("Appearance", selection: $appearance,
                               options: EnigmaAppearance.allCases.map { EnigmaOption($0, $0.title) })
      }
      EnigmaRow("Search automatically", subtitle: "When fresh information is needed") {
        EnigmaSwitch("Search automatically", isOn: $isOn)
      }
      EnigmaRow("Use location", subtitle: "Only for nearby questions") {
        EnigmaSwitch("Use location", isOn: $isOff)
      }
      EnigmaRow("Preferred provider") {
        EnigmaMenu("Preferred provider", selection: $provider,
                   options: ["ChatGPT", "Claude", "OpenAI"].map { EnigmaOption($0, $0) })
      }
      EnigmaRow("Disabled switch") { EnigmaSwitch("Disabled switch", isOn: $isOn).disabled(true) }
      EnigmaHairline()
      EnigmaTextField("API key", text: $key, isSecure: true).padding(.top, 14)
      EnigmaProgressBar(fraction: 0.4, width: nil).padding(.top, 14)
      EnigmaDisclosure("Model details", isExpanded: true) {
        EnigmaNote("Q4_K_M · 8192 token context")
      }
      .padding(.top, 10)
    }
    .padding(28)
    .frame(width: 520, height: 520, alignment: .top)
    .background(palette.background.color)
    .enigmaMenuHost()
  }
}

#Preview("Controls, Paper") { EnigmaControlsPreview().enigmaTheme(.paper) }
#Preview("Controls, Ink") { EnigmaControlsPreview().enigmaTheme(.ink) }
#Preview("Settings controls, Paper") { EnigmaSettingsControlsPreview().enigmaTheme(.paper) }
#Preview("Settings controls, Ink") { EnigmaSettingsControlsPreview().enigmaTheme(.ink) }
#endif
