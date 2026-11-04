import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Text for the composer to insert at its caret, like `/` from the composer's
/// command button. A new value inserts it again, even with the same text.
struct SlashCommandInsertion: Equatable {
  let id = UUID()
  let text: String
}

/// The message field, with `/` commands highlighted as they're typed and an
/// inline list of the commands that match. Its colors come from `enigmaPalette`.
struct SlashCommandComposer: View {
  /// Where the inline command list opens: above the text, or below it, as when
  /// the composer sits high on the main page. `gap` is the distance from the
  /// text's edge to the list.
  enum SuggestionPlacement: Equatable {
    case above(gap: CGFloat)
    case below(gap: CGFloat)
  }

  @Binding var text: String
  @Binding var isFocused: Bool
  var isEnabled: Bool
  var fontSize: CGFloat = 15
  var availableCommands: [SlashCommand]
  var placeholder = "Ask anything..."
  var suggestionPlacement: SuggestionPlacement = .above(gap: 18)
  var insertion: SlashCommandInsertion?
  var submit: () -> Void
  @StateObject private var completion = CommandCompletionModel()
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.composerDrops) private var drops

  var body: some View {
    ZStack(alignment: .topLeading) {
      if text.isEmpty {
        placeholderText.allowsHitTesting(false).accessibilityHidden(true)
      }
      CommandTextEditor(text: $text, isFocused: $isFocused, isEnabled: isEnabled,
                        completion: completion, availableCommands: availableCommands,
                        fontSize: fontSize, colors: colors, submit: submit,
                        attach: drops?.attach, dropTarget: drops?.targetChanged)
        .frame(height: completion.height)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: suggestionAlignment) {
      if isFocused && isEnabled && !completion.commands.isEmpty { inlineSuggestions }
    }
    .onChange(of: insertion) { _, insertion in
      if let insertion { completion.insert(insertion.text) }
    }
  }

  private var placeholderText: some View {
    Text(placeholder).font(EnigmaTypography.ui(fontSize)).foregroundStyle(palette.textTertiary.color)
  }

  private var colors: CommandTextEditor.Colors {
    CommandTextEditor.Colors(text: palette.textPrimary.nsColor, command: palette.accentText.nsColor,
                             caret: palette.accent.nsColor)
  }

  private var suggestionAlignment: Alignment {
    switch suggestionPlacement {
    case .above: .bottomLeading
    case .below: .topLeading
    }
  }

  @ViewBuilder private var inlineSuggestions: some View {
    // The list opens in place, under the window's character stage, so the
    // stage hides the character where the list covers it.
    let suggestions = EnigmaSlashSuggestions(completion: completion)
      .enigmaCharacterCover(cornerRadius: EnigmaSlashSuggestions.cornerRadius)
      .background { suggestionsFrame }
    switch suggestionPlacement {
    case .above(let gap): suggestions.padding(.bottom, completion.height + gap)
    case .below(let gap): suggestions.padding(.top, completion.height + gap)
    }
  }

  /// Where the list is, so a container that grows to fit, like the compact
  /// panel, can make room for it.
  private var suggestionsFrame: some View {
    GeometryReader { proxy in
      Color.clear.preference(key: SlashSuggestionsFrame.self,
                             value: proxy.frame(in: .named(SlashSuggestionsFrame.coordinateSpace)))
    }
  }
}

/// The open command list's frame in the `coordinateSpace` of a container
/// that names it, or zero while it's closed.
struct SlashSuggestionsFrame: PreferenceKey {
  static let coordinateSpace = "SlashSuggestionsSpace"
  static let defaultValue: CGRect = .zero
  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    let next = nextValue()
    if next != .zero { value = next }
  }
}

/// The command list: an opaque `menu` surface with a
/// `border` edge, each command in monospace `accentText` beside its
/// description, and the chosen one on a `hover` fill.
private struct EnigmaSlashSuggestions: View {
  static let cornerRadius: CGFloat = 10

  @ObservedObject var completion: CommandCompletionModel
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(completion.commands.enumerated()), id: \.element) { index, command in
        let isSelected = index == completion.selected
        Button { completion.accept(command) } label: {
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(command.token)
              .font(EnigmaTypography.mono(12, weight: .medium))
              .foregroundStyle(palette.accentText.color)
              .frame(width: 92, alignment: .leading)
            Text(command.description)
              .font(EnigmaTypography.ui(12.5))
              .foregroundStyle(palette.textSecondary.color)
              .lineLimit(1)
            Spacer(minLength: 0)
            Text("⇥")
              .font(EnigmaTypography.mono(11))
              .foregroundStyle(palette.textTertiary.color)
              .opacity(isSelected ? 1 : 0)
              .accessibilityHidden(true)
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 6)
          .contentShape(Rectangle())
          .background {
            if isSelected { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.hover.color) }
          }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(command.token + ", " + command.description)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .enigmaTestMarker("Slash command \(command.token)")
      }
    }
    .padding(5)
    .background(palette.menu.color, in: shape)
    .enigmaEdge(shape)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Slash commands")
    .frame(width: 400)
    .fixedSize(horizontal: false, vertical: true)
  }
}

@MainActor
final class CommandCompletionModel: ObservableObject {
  @Published var commands: [SlashCommand] = []
  @Published var selected = 0
  @Published var height: CGFloat = 20
  weak var editor: SlashCommandTextView?
  var availableCommands = SlashCommand.allCases
  private var active: SlashCommand.Completion?

  func refresh() {
    guard let editor, editor.isEditable, !editor.hasMarkedText() else { dismiss(); return }
    let next = SlashCommand.completion(in: editor.string, selection: editor.selectedRange(),
                                      availableCommands: availableCommands)
    if next != active { selected = 0 }
    active = next
    let matches = next?.commands ?? []
    if commands != matches { commands = matches }
    updateHeight()
  }

  func updateHeight() {
    guard let editor, let container = editor.textContainer, let layout = editor.layoutManager else { return }
    layout.ensureLayout(for: container)
    let measured = min(100, max(20, ceil(layout.usedRect(for: container).height)))
    if height != measured { height = measured }
  }

  @discardableResult
  func dismiss() -> Bool {
    let wasVisible = !commands.isEmpty
    if !commands.isEmpty { commands = [] }
    active = nil
    return wasVisible
  }

  func accept(_ command: SlashCommand) {
    guard let editor, let active, editor.isEditable, active.commands.contains(command),
          SlashCommand.completion(in: editor.string, selection: editor.selectedRange(),
                                  availableCommands: availableCommands) == active else { return }
    let source = editor.string as NSString
    let end = NSMaxRange(active.range)
    let hasSpace = end < source.length && source.substring(with: NSRange(location: end, length: 1)).first?.isWhitespace == true
    let replacement = command.token + (hasSpace ? "" : " ")
    guard editor.shouldChangeText(in: active.range, replacementString: replacement) else { return }
    editor.textStorage?.replaceCharacters(in: active.range, with: replacement)
    editor.setSelectedRange(NSRange(location: active.range.location + (replacement as NSString).length, length: 0))
    editor.didChangeText()
    dismiss()
    editor.window?.makeFirstResponder(editor)
  }

  /// Types `text` at the caret, or at the end when the editor doesn't have
  /// focus, with a space before it after a word, and gives the editor focus.
  /// Inserting `/` opens the command list.
  func insert(_ text: String) {
    guard let editor, editor.isEditable, !editor.hasMarkedText() else { return }
    let source = editor.string as NSString
    let hasFocus = editor.window?.firstResponder === editor
    var range = editor.selectedRange()
    if !hasFocus || range.location == NSNotFound || NSMaxRange(range) > source.length {
      range = NSRange(location: source.length, length: 0)
    }
    let previous = range.location > 0 ? source.substring(with: NSRange(location: range.location - 1, length: 1)) : ""
    let replacement = (previous.isEmpty || previous.first?.isWhitespace == true ? "" : " ") + text
    editor.window?.makeFirstResponder(editor)
    guard editor.shouldChangeText(in: range, replacementString: replacement) else { return }
    editor.textStorage?.replaceCharacters(in: range, with: replacement)
    editor.setSelectedRange(NSRange(location: range.location + (replacement as NSString).length, length: 0))
    editor.didChangeText()
    refresh()
  }

  func handle(_ event: NSEvent) -> Bool {
    guard !commands.isEmpty, editor?.hasMarkedText() == false,
          event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
    switch event.keyCode {
    case 53: return dismiss()
    case 125: selected = (selected + 1) % commands.count
    case 126: selected = (selected + commands.count - 1) % commands.count
    case 48, 36, 76: accept(commands[selected])
    default: return false
    }
    return true
  }
}

final class SlashCommandTextView: NSTextView {
  var completion: CommandCompletionModel?
  /// Plain text and command tokens, from the palette. The field sets them from
  /// the current theme; until then they're Paper's.
  var plainTextColor: NSColor = EnigmaPalette.paper.textPrimary.nsColor
  var commandTextColor: NSColor = EnigmaPalette.paper.accentText.nsColor
  var submit: (() -> Void)?
  var focusChanged: ((Bool) -> Void)?
  /// Files and images dropped or pasted on the field (F4). Returns whether
  /// they were attached. Nil keeps AppKit's plain-text behavior.
  var attach: (@MainActor @Sendable (ComposerPasteboard.Item) -> Bool)? {
    didSet { if (attach == nil) != (oldValue == nil) { updateDragTypeRegistration() } }
  }
  /// A drag with files or an image is over the field, for the composer's highlight.
  var dropTargetChanged: (@MainActor @Sendable (Bool) -> Void)?

  override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
    // Keeps Paste enabled for image data and Finder files; `paste(_:)` takes them first.
    super.readablePasteboardTypes + (attach == nil ? [] : [.fileURL, .png, NSPasteboard.PasteboardType(UTType.jpeg.identifier), .tiff])
  }

  /// Hands files or image data on `pasteboard` to `attach`. False leaves the
  /// pasteboard to AppKit, as for text, including text that is a path.
  @discardableResult
  func attachItems(from pasteboard: NSPasteboard) -> Bool {
    guard let attach, let item = ComposerPasteboard.item(in: pasteboard) else { return false }
    _ = attach(item)
    return true
  }

  override func paste(_ sender: Any?) {
    if attachItems(from: .general) { return }
    super.paste(sender)
  }

  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    guard attach != nil, ComposerPasteboard.hasItem(sender.draggingPasteboard) else { return super.draggingEntered(sender) }
    dropTargetChanged?(true)
    return .copy
  }

  override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
    guard attach != nil, ComposerPasteboard.hasItem(sender.draggingPasteboard) else { return super.draggingUpdated(sender) }
    return .copy
  }

  override func draggingExited(_ sender: (any NSDraggingInfo)?) {
    dropTargetChanged?(false)
    super.draggingExited(sender)
  }

  /// A plain-text view refuses image data here, so take what `attach` handles.
  override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    (attach != nil && ComposerPasteboard.hasItem(sender.draggingPasteboard)) || super.prepareForDragOperation(sender)
  }

  /// A refused drop gets neither `performDragOperation` nor `draggingExited`.
  override func draggingEnded(_ sender: any NSDraggingInfo) {
    dropTargetChanged?(false)
    super.draggingEnded(sender)
  }

  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    dropTargetChanged?(false)
    guard let attach, let item = ComposerPasteboard.item(in: sender.draggingPasteboard) else {
      return super.performDragOperation(sender)
    }
    return attach(item)
  }

  override func keyDown(with event: NSEvent) {
    if completion?.handle(event) == true { return }
    if !hasMarkedText(), [36, 76].contains(event.keyCode),
       event.modifierFlags.intersection([.shift, .option, .control, .command]) == .shift {
      insertText("\n", replacementRange: selectedRange())
      return
    }
    if !hasMarkedText(), [36, 76].contains(event.keyCode),
       event.modifierFlags.intersection([.shift, .option, .control, .command]).isEmpty {
      submit?()
      return
    }
    super.keyDown(with: event)
  }

  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { focusChanged?(true) }
    return accepted
  }

  override func resignFirstResponder() -> Bool {
    let accepted = super.resignFirstResponder()
    if accepted {
      focusChanged?(false)
      DispatchQueue.main.async { [weak self] in
        guard let self, self.window?.firstResponder !== self else { return }
        self.completion?.dismiss()
      }
    }
    return accepted
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    // Wrapping can change when the panel resizes without an edit.
    DispatchQueue.main.async { [weak self] in self?.completion?.updateHeight() }
  }

  func highlightCommands() {
    guard !hasMarkedText(), let storage = textStorage else { return }
    let selection = selectedRanges
    storage.beginEditing()
    storage.addAttributes([.foregroundColor: plainTextColor, .font: NSFont.systemFont(ofSize: font?.pointSize ?? 15)],
                          range: NSRange(location: 0, length: storage.length))
    for token in SlashCommand.tokens(in: string) {
      storage.addAttribute(.foregroundColor, value: commandTextColor, range: token.range)
    }
    storage.endEditing()
    selectedRanges = selection
    typingAttributes = [.foregroundColor: plainTextColor, .font: NSFont.systemFont(ofSize: font?.pointSize ?? 15)]
  }
}

private struct CommandTextEditor: NSViewRepresentable {
  /// The text view's colors: text, highlighted commands, and the insertion point.
  struct Colors: Equatable {
    var text: NSColor
    var command: NSColor
    var caret: NSColor
  }

  @Binding var text: String
  @Binding var isFocused: Bool
  var isEnabled: Bool
  var completion: CommandCompletionModel
  var availableCommands: [SlashCommand]
  var fontSize: CGFloat = 15
  var colors: Colors
  var submit: () -> Void
  var attach: (@MainActor @Sendable (ComposerPasteboard.Item) -> Bool)?
  var dropTarget: (@MainActor @Sendable (Bool) -> Void)?

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    let editor = SlashCommandTextView(frame: .zero)
    editor.isRichText = false
    editor.allowsUndo = true
    editor.drawsBackground = false
    editor.textContainerInset = .zero
    editor.textContainer?.lineFragmentPadding = 0
    editor.isHorizontallyResizable = false
    editor.isVerticallyResizable = true
    editor.autoresizingMask = [.width]
    editor.textContainer?.widthTracksTextView = true
    editor.font = .systemFont(ofSize: fontSize)
    editor.plainTextColor = colors.text
    editor.commandTextColor = colors.command
    editor.insertionPointColor = colors.caret
    editor.setAccessibilityLabel("Message")
    editor.setAccessibilityHelp("Type slash for commands. Use arrow keys to choose, Tab or Return to complete, Escape to dismiss, and Shift Return for a new line.")
    editor.delegate = context.coordinator
    editor.completion = completion
    completion.editor = editor
    completion.availableCommands = availableCommands
    scroll.documentView = editor
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let editor = scroll.documentView as? SlashCommandTextView else { return }
    editor.isEditable = isEnabled
    context.coordinator.rejectsEdits = context.environment.enigmaTourDemo
    editor.submit = submit
    // The tour's read-only demo field takes no drops or pastes either.
    if context.environment.enigmaTourDemo { editor.attach = nil } else { editor.attach = attach }
    editor.dropTargetChanged = dropTarget
    if completion.availableCommands != availableCommands {
      completion.availableCommands = availableCommands
      DispatchQueue.main.async { completion.refresh() }
    }
    editor.focusChanged = { focused in
      DispatchQueue.main.async { context.coordinator.parent.isFocused = focused }
    }
    let needsFontUpdate = editor.font?.pointSize != fontSize
    if needsFontUpdate { editor.font = .systemFont(ofSize: fontSize) }
    let needsColorUpdate = editor.plainTextColor != colors.text || editor.commandTextColor != colors.command
    if needsColorUpdate {
      editor.plainTextColor = colors.text
      editor.commandTextColor = colors.command
    }
    if editor.insertionPointColor != colors.caret { editor.insertionPointColor = colors.caret }
    if needsColorUpdate, editor.string == text, !needsFontUpdate, !editor.hasMarkedText() {
      editor.highlightCommands()
    }
    if (editor.string != text || needsFontUpdate), !editor.hasMarkedText() {
      editor.delegate = nil
      editor.string = text
      editor.highlightCommands()
      editor.delegate = context.coordinator
      DispatchQueue.main.async { completion.refresh() }
    }
    if !isEnabled { DispatchQueue.main.async { completion.dismiss() } }
    if isFocused && isEnabled && editor.window?.firstResponder !== editor {
      DispatchQueue.main.async { [weak editor] in
        guard let editor, context.coordinator.parent.isFocused, editor.isEditable else { return }
        editor.window?.makeFirstResponder(editor)
      }
    } else if !isFocused && editor.window?.firstResponder === editor {
      editor.window?.makeFirstResponder(nil)
    }
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: CommandTextEditor
    /// Read-only keeps Return (the tour's next step) but refuses typing and pastes.
    var rejectsEdits = false
    init(_ parent: CommandTextEditor) { self.parent = parent }
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
      !rejectsEdits
    }
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      guard commandSelector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() else { return false }
      parent.submit()
      return true
    }
    func textDidChange(_ notification: Notification) {
      guard let editor = notification.object as? SlashCommandTextView else { return }
      parent.text = editor.string
      editor.highlightCommands()
      parent.completion.refresh()
    }
    func textViewDidChangeSelection(_ notification: Notification) {
      parent.completion.refresh()
    }
  }
}

/// What a drop or paste on the composer carries (F4).
enum ComposerPasteboard {
  enum Item: Equatable, Sendable {
    /// Finder files or folders, routed by `ComposerDrop`.
    case files([URL])
    /// Image data (PNG, JPEG or TIFF), not yet decoded.
    case image(Data)
  }

  /// Smallest first: a browser image carries its JPEG and a far larger TIFF.
  private static let imageTypes: [NSPasteboard.PasteboardType] = [.png, NSPasteboard.PasteboardType(UTType.jpeg.identifier), .tiff]

  /// File URLs first. Image data with no text, or with a web link, as a
  /// browser's image drag or Copy Image has; a spreadsheet cell or styled
  /// text, which carries text without a link, still pastes as text.
  static func item(in pasteboard: NSPasteboard) -> Item? {
    let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    if !urls.isEmpty { return .files(urls) }
    guard isImage(pasteboard), let data = imageTypes.lazy.compactMap({ pasteboard.data(forType: $0) }).first else { return nil }
    return .image(data)
  }

  /// `item(in:)` without reading the data, for a drag in progress.
  static func hasItem(_ pasteboard: NSPasteboard) -> Bool {
    pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) || isImage(pasteboard)
  }

  private static func isImage(_ pasteboard: NSPasteboard) -> Bool {
    pasteboard.availableType(from: imageTypes) != nil
      && (pasteboard.availableType(from: [.string]) == nil || pasteboard.availableType(from: [.URL]) != nil)
  }
}

/// Where dropped files go (F4): one image file to the image attachment,
/// anything else, images included, to File Mode.
enum ComposerDrop: Equatable {
  case image(URL)
  case files([URL], includesImages: Bool)

  static func route(_ urls: [URL]) -> ComposerDrop? {
    let files = urls.filter(\.isFileURL)
    guard !files.isEmpty else { return nil }
    let images = files.filter(isImage)
    if files.count == 1, let image = images.first { return .image(image) }
    return .files(files, includesImages: !images.isEmpty)
  }

  /// PDFs aren't images here: they go to File Mode.
  static func isImage(_ url: URL) -> Bool {
    let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
      ?? UTType(filenameExtension: url.pathExtension)
    return type.map { $0.conforms(to: .image) && !$0.conforms(to: .pdf) } ?? false
  }
}

/// The composer's drop and paste actions (F4). Always equal: the shell makes
/// new closures on every render, and a changed environment value would update
/// the field each time, which drops its focus while the binding still lags.
struct ComposerDrops: Equatable, Sendable {
  /// Attaches files or an image dropped or pasted on the composer.
  let attach: @MainActor @Sendable (ComposerPasteboard.Item) -> Bool
  /// A drag with files or an image entered or left the message field.
  let targetChanged: @MainActor @Sendable (Bool) -> Void
  static func == (_: Self, _: Self) -> Bool { true }
}

extension EnvironmentValues {
  @Entry var composerDrops: ComposerDrops? = nil
  /// A drop over the composer: its edge shows the focus accent.
  @Entry var composerDropTargeted = false

  /// The window shows the tour's demo chat: it scrolls, but its composer takes
  /// no typing and its messages' buttons take no clicks.
  @Entry var enigmaTourDemo = false
}
