import SwiftUI

// Shared controls for the new UI. Each reads its colors from the environment's
// `enigmaPalette`, so it follows Paper and Ink. Later phases add switches,
// menus, and the rest here rather than making local copies.

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
  fileprivate func enigmaFocusRing(_ isVisible: Bool, palette: EnigmaPalette,
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
  var onFocusChange: (Bool) -> Void = { _ in }
  var onSubmit: () -> Void = {}
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.displayScale) private var displayScale
  @FocusState private var isFocused: Bool

  init(_ placeholder: String, text: Binding<String>, isSecure: Bool = false,
       onFocusChange: @escaping (Bool) -> Void = { _ in }, onSubmit: @escaping () -> Void = {}) {
    self.placeholder = placeholder
    _text = text
    self.isSecure = isSecure
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
        .accessibilityLabel(placeholder)
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

#Preview("Controls, Paper") { EnigmaControlsPreview().enigmaTheme(.paper) }
#Preview("Controls, Ink") { EnigmaControlsPreview().enigmaTheme(.ink) }
#endif
