import AppKit
import Combine
import LocalAuthentication
import Security
import SwiftUI
import XCTest
import WebKit
import Vision
@testable import Enigma

@MainActor
final class ScreenViewTests: XCTestCase {
  func testSlashCommandSuggestionsRenderWithHighlightedDraft() async throws {
    let text = "Explain /think using /"
    let view = NSHostingView(rootView: SlashCommandComposer(text: .constant(text),
      isFocused: .constant(true), isEnabled: true, availableCommands: SlashCommand.allCases, submit: {})
      .padding(.top, 360).padding(16).frame(width: 480).environment(\.colorScheme, .dark))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    view.layoutSubtreeIfNeeded()
    let editor = try composerField(in: view)
    editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    editor.completion?.refresh()
    await Task.yield()
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(editor.string, text)
    XCTAssertEqual(editor.completion?.commands, SlashCommand.allCases)
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/tmp/AI-Spotlight-Slash-Commands.png"))
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = "Slash command suggestions"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testMarkdownResponseRendersInBothAppearances() throws {
    let content = ####"""
      \### A cleaner response

      \* **Bold**, *italic*, `inline code`, and [a link](https://example.com).
      \* Another bullet with a longer sentence that wraps naturally in the chat.

      1. First step
      2. Second step

      > A useful quote with **emphasis**.

      ```swift
      let path = #"C:\Users\leo\notes.md"#
      ```

      | Model | Output |
      | --- | --- |
      | Local | Clean Markdown |
      | ChatGPT | Clean Markdown |
      """####
    for scheme in [ColorScheme.light, .dark] {
      let view = NSHostingView(rootView: LocalMessageView(message: ChatMessage(role: .assistant, content: content))
        .padding(24).frame(width: 620).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme))
      let size = view.fittingSize
      XCTAssertGreaterThan(size.height, 300)
      let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
      window.contentView = view
      defer { window.contentView = nil }
      view.frame = NSRect(origin: .zero, size: size)
      view.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      try png.write(to: URL(fileURLWithPath: "/tmp/AI-Spotlight-Markdown-\(scheme == .dark ? "dark" : "light").png"))
      let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
      attachment.name = "Markdown response"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }

  func testCoalescenceThinkingRendersAnimation() async throws {
    XCTAssertNotNil(NSDataAsset(name: "EnigmaCoalescence"))
    let view = NSHostingView(rootView: ThinkingStatusView()
      .padding(16).frame(width: 200, height: 96).background(NatureGlass.canvas))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 96),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    defer { window.contentView = nil }
    view.layoutSubtreeIfNeeded()
    let web = try XCTUnwrap(descendants(view).compactMap { $0 as? WKWebView }.first)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    var ready = false
    repeat {
      ready = (try? await web.evaluateJavaScript("document.readyState === 'complete' && !!document.querySelector('.ec-still')")) as? Bool == true
      if !ready { await Task.yield() }
    } while !ready && ContinuousClock.now < deadline
    XCTAssertTrue(ready, "The bundled SVG must finish loading")
    let motionDisplay = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('.ec-motion')).display") as? String
    let stillDisplay = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('.ec-still')).display") as? String
    XCTAssertNotEqual(motionDisplay, "none")
    XCTAssertEqual(stillDisplay, "none")
    _ = try await web.evaluateJavaScript("document.querySelector('svg').pauseAnimations(); document.querySelector('svg').setCurrentTime(0); true")
    let first = try await web.takeSnapshot(configuration: nil)
    let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(first.cgImage(forProposedRect: nil, context: nil, hints: nil)))
    let visible = (0..<bitmap.pixelsWide).reduce(0) { count, x in
      count + (0..<bitmap.pixelsHigh).filter { y in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 }.count
    }
    XCTAssertGreaterThan(visible, 10, "Coalescence artwork must render, not a blank web view")
    _ = try await web.evaluateJavaScript("document.querySelector('svg').setCurrentTime(3); true")
    let next = try await web.takeSnapshot(configuration: nil)
    XCTAssertNotEqual(first.tiffRepresentation, next.tiffRepresentation, "The supplied coalescence must change across its timeline")
    let preview = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: preview)
    let png = try XCTUnwrap(preview.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/tmp/Enigma-Thinking-Animated.png"))
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = "Thinking · enigma coalescence"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testLiquidGlassSettingsAndAssetsRender() throws {
    for name in ["ForestBackdrop", "TemplateAttachment"] {
      let image = try XCTUnwrap(NSImage(named: name))
      XCTAssertNotNil(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }
    let credentials = ScreenTestCredentialStore()
    let settings = CloudSettingsModel(credentialStore: credentials,
      catalog: CloudModelCatalog(credentialStore: credentials, transport: ScreenTestTransport()),
      codexAvailable: { false })
    for destination in SettingsView.SettingsDestination.allCases {
      let view = NSHostingView(rootView: SettingsView(settings: settings, initialDestination: destination,
        discovery: LocalModelDiscovery(loader: { _ in HuggingFaceModelPage(models: []) })))
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 680), styleMask: [.borderless], backing: .buffered, defer: false)
      window.contentView = view
      defer { window.contentView = nil }
      view.layoutSubtreeIfNeeded()
      XCTAssertEqual(view.fittingSize, NSSize(width: 820, height: 680))
      let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      try png.write(to: URL(fileURLWithPath: "/tmp/AI-Spotlight-Glass-Settings-\(destination.rawValue).png"))
      let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
      attachment.name = "Liquid Glass settings · \(destination.rawValue)"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }

  func testConversationBubblesAndSentAttachmentRender() throws {
    var outgoing = ChatMessage(role: .user, content: "Could you review the notes I attached and suggest a clearer introduction?")
    outgoing.attachments = [MessageAttachment(name: "Project notes.txt", isDirectory: false)]
    let encoded = try JSONEncoder().encode(outgoing)
    XCTAssertEqual(try JSONDecoder().decode(ChatMessage.self, from: encoded).attachments, outgoing.attachments)
    let preview = VStack(alignment: .leading, spacing: 24) {
      LocalMessageView(message: outgoing)
      LocalMessageView(message: ChatMessage(role: .assistant, content: "Start with the purpose of the project, then explain who it helps. Keep the first paragraph focused on the reader.\n\nHere is a more direct opening you can build on."))
      LocalMessageView(message: ChatMessage(role: .user, content: "That feels much clearer. Thank you."))
    }.padding(28).frame(width: 620, height: 390).background(Color(nsColor: .windowBackgroundColor))
    let view = NSHostingView(rootView: preview.environment(\.colorScheme, .dark))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 390), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    defer { window.contentView = nil }
    view.frame = NSRect(x: 0, y: 0, width: 620, height: 390)
    view.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/tmp/AI-Spotlight-Bubbles.png"))
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = "Chat bubbles and sent attachments"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testRemovingWaitingRowKeepsFollowingButLiveScrollStillReleases() {
    let document = ConversationTestDocument(flipped: true)
    document.frame = NSRect(x: 0, y: 0, width: 400, height: 1600)
    let observer = ConversationScrollObserver.ObserverView()
    observer.frame = document.bounds
    document.addSubview(observer)
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    scroll.documentView = document
    let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = scroll
    defer { window.contentView = nil }
    observer.scrollToBottomIfFollowing()
    document.setFrameSize(NSSize(width: 400, height: 1500))
    // Simulate the offset adjustment SwiftUI makes after removing the leaf row.
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 1150))
    XCTAssertTrue(observer.followsLatest)
    observer.scrollToBottomIfFollowing()
    XCTAssertEqual(scroll.contentView.bounds.maxY, document.bounds.maxY, accuracy: 1)
    document.setFrameSize(NSSize(width: 400, height: 1450))
    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 1000))
    NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    observer.scrollToBottomIfFollowing()
    XCTAssertFalse(observer.followsLatest)
    XCTAssertEqual(scroll.contentView.bounds.minY, 1000, accuracy: 1)
  }

  func testStreamRevisionFollowsEvenWithoutObserverFrameChanges() async throws {
    let document = ConversationTestDocument(flipped: true)
    document.frame = NSRect(x: 0, y: 0, width: 400, height: 1600)
    let observer = ConversationScrollObserver.ObserverView()
    observer.frame = document.bounds
    document.addSubview(observer)
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    scroll.documentView = document
    let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = scroll
    defer { window.contentView = nil }
    observer.scrollToBottomIfFollowing()
    // Bounds-only growth deliberately does not send the document frame notification.
    document.setBoundsSize(NSSize(width: 400, height: 1900))
    observer.contentChanged("new streamed text")
    let followed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      abs(scroll.contentView.bounds.maxY - document.bounds.maxY) < 2
    }, object: nil)
    await fulfillment(of: [followed], timeout: 2)
    XCTAssertTrue(observer.followsLatest)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY - 8))
    observer.contentChanged("more streamed text")
    observer.scrollToBottomIfFollowing()
    XCTAssertFalse(observer.followsLatest)
    XCTAssertGreaterThan(document.bounds.maxY - scroll.contentView.bounds.maxY, 2)
  }

  func testConversationScrollPreservesReadingPositionAcrossLayoutAndStreaming() throws {
    for flipped in [true, false] {
      let document = ConversationTestDocument(flipped: flipped)
      document.frame = NSRect(x: 0, y: 0, width: 400, height: 1600)
      let observer = ConversationScrollObserver.ObserverView()
      observer.frame = document.bounds
      document.addSubview(observer)
      let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
      scroll.documentView = document
      let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      window.contentView = scroll
      defer { window.contentView = nil }
      observer.scrollToBottomIfFollowing()
      XCTAssertTrue(observer.followsLatest)
      let bottom = scroll.contentView.bounds.minY

      // A tiny wheel/keyboard movement cancels a layout correction already queued.
      observer.setFrameSize(NSSize(width: 400, height: 1601))
      scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom + (flipped ? -8 : 8)))
      let readingPosition = scroll.contentView.bounds.minY
      XCTAssertFalse(observer.followsLatest)
      observer.scrollToBottomIfFollowing()
      XCTAssertEqual(scroll.contentView.bounds.minY, readingPosition, accuracy: 0.5)

      document.setFrameSize(NSSize(width: 400, height: 2000))
      observer.setFrameSize(document.bounds.size)
      observer.scrollToBottomIfFollowing()
      XCTAssertFalse(observer.followsLatest)
      XCTAssertEqual(scroll.contentView.bounds.minY, readingPosition, accuracy: 0.5)

      // Returning to the bottom restores following for the next streamed growth.
      let newBottom = flipped ? document.bounds.maxY - scroll.contentView.bounds.height : 0
      scroll.contentView.scroll(to: NSPoint(x: 0, y: newBottom))
      XCTAssertTrue(observer.followsLatest)
      document.setFrameSize(NSSize(width: 400, height: 2200))
      observer.setFrameSize(document.bounds.size)
      observer.scrollToBottomIfFollowing()
      XCTAssertEqual(scroll.contentView.bounds.minY,
                     flipped ? document.bounds.maxY - scroll.contentView.bounds.height : 0, accuracy: 0.5)

      // Trackpad gestures suspend following even before their first offset change.
      NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
      observer.setFrameSize(NSSize(width: 400, height: 2201))
      observer.scrollToBottomIfFollowing()
      XCTAssertFalse(observer.followsLatest)
      scroll.contentView.scroll(to: NSPoint(x: 0, y: flipped ? 100 : 1000))
      NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
      XCTAssertFalse(observer.followsLatest)
      let olderPosition = scroll.contentView.bounds.minY
      observer.scrollToBottomIfFollowing()
      XCTAssertEqual(scroll.contentView.bounds.minY, olderPosition, accuracy: 0.5)
    }
  }

  func testToolMenuImagesHaveCompactIntrinsicSizesWithoutChangingAssets() throws {
    for name in ["ScreenCapture", "WebSearch"] {
      let source = try XCTUnwrap(NSImage(named: name))
      let originalSize = source.size
      let image = ToolMenuLabel.menuImage(named: name)
      XCTAssertEqual(image.size, NSSize(width: 16, height: 16))
      XCTAssertTrue(image.isTemplate)
      XCTAssertFalse(image === source)
      XCTAssertEqual(source.size, originalSize)
      XCTAssertNotNil(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }
    let preview = VStack(alignment: .leading, spacing: 10) {
      ToolMenuLabel(title: "Screen", imageName: "ScreenCapture")
      ToolMenuLabel(title: "Web Search", imageName: "WebSearch")
      Divider()
      HStack {
        Text("Hide Inactive Tools")
        Spacer()
        Text("⇧⌘H").foregroundStyle(.secondary)
      }
    }
    .font(.system(size: 13)).padding(12).frame(width: 240)
    .background(Color(nsColor: .windowBackgroundColor))
    let renderer = ImageRenderer(content: preview.environment(\.colorScheme, .dark))
    renderer.scale = 2
    let image = try XCTUnwrap(renderer.cgImage)
    let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/tmp/AI-Spotlight-Compact-Tool-Icons.png"))
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = "Compact tool menu labels"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testSentImagesStaySmallAndPreserveTheirProportions() throws {
    let sizes: [NSSize] = [
      NSSize(width: 1600, height: 800),
      NSSize(width: 800, height: 1600),
      NSSize(width: 1000, height: 1000),
    ]
    let expected: [NSSize] = [
      NSSize(width: 120, height: 60),
      NSSize(width: 48, height: 96),
      NSSize(width: 96, height: 96),
    ]
    var messages: [ChatMessage] = []
    for (index, size) in sizes.enumerated() {
      let source = NSImage(size: size, flipped: false) { bounds in
        NSColor.systemTeal.setFill()
        bounds.fill()
        NSColor.systemYellow.setFill()
        NSBezierPath(ovalIn: NSRect(x: size.width * 0.15, y: size.height * 0.25,
          width: min(size.width, size.height) * 0.4, height: min(size.width, size.height) * 0.4)).fill()
        return true
      }
      let data = try XCTUnwrap(try ScreenAttachment(image: source).makeMessagePreview())
      let image = try XCTUnwrap(NSImage(data: data))
      let view = NSHostingView(rootView: SentImagePreview(image: image))
      XCTAssertEqual(view.fittingSize.width, expected[index].width, accuracy: 0.5)
      XCTAssertEqual(view.fittingSize.height, expected[index].height, accuracy: 0.5)
      let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
      XCTAssertLessThanOrEqual(bitmap.pixelsWide, 240)
      XCTAssertLessThanOrEqual(bitmap.pixelsHigh, 192)
      var message = ChatMessage(role: .user, content: ["What is in this image?", "Describe this portrait image.", "And this square image?"][index])
      message.imagePreview = data
      messages.append(message)
    }
    let preview = VStack(alignment: .leading, spacing: 20) {
      ForEach(messages) { message in
        LocalMessageView(message: message)
      }
      LocalMessageView(message: ChatMessage(role: .assistant, content: "Each image shows a yellow circle on a teal background."))
    }
    .padding(24).frame(width: 440).background(Color(nsColor: .windowBackgroundColor))
    let renderer = ImageRenderer(content: preview)
    renderer.scale = 2
    let image = try XCTUnwrap(renderer.cgImage)
    let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/tmp/AI-Spotlight-Sent-Image-Previews.png"))
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = "Sent image thumbnails above message text"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testKeychainAvailabilityUsesAttributesWithoutAuthentication() throws {
    let store = KeychainCredentialStore(copyMatching: { query, _ in
      let query = query as NSDictionary
      XCTAssertNil(query[kSecReturnData])
      XCTAssertEqual(query[kSecReturnAttributes] as? Bool, true)
      XCTAssertEqual((query[kSecUseAuthenticationContext] as? LAContext)?.interactionNotAllowed, true)
      return errSecSuccess
    })
    XCTAssertTrue(try store.containsAPIKey(for: .openAI))
    for status in [errSecItemNotFound, errSecInteractionNotAllowed] {
      let unavailable = KeychainCredentialStore(copyMatching: { _, _ in status })
      XCTAssertFalse(try unavailable.containsAPIKey(for: .openAI))
    }
  }

  func testCloudAvailabilityDoesNotReadTheSecretDuringScreenRouting() throws {
    let credentials = PresenceOnlyCredentials()
    let settings = CloudSettingsModel(credentialStore: credentials,
      catalog: CloudModelCatalog(credentialStore: credentials, transport: ScreenTestTransport()),
      codexAvailable: { false })
    XCTAssertTrue(settings.hasCloudAccess(for: .openAI))
  }

  func testComposerSearchSettingsDoNotReadTheSecret() {
    XCTAssertTrue(WebSearchSettings(credentials: PresenceOnlyCredentials()).hasAPIKey)
  }

  func testFullPanelRetainsContentDuringScreenSubmission() async throws {
    try await verifyFullPanelScreenSubmission(searchEnabled: false)
  }

  func testFullPanelCombinesScreenAndSearchDuringRapidStreaming() async throws {
    try await verifyFullPanelScreenSubmission(searchEnabled: true)
  }

  func testCombinedCommandsSearchBeforeAutomaticScreenSubmission() async throws {
    for commands in ["/screen /search", "/search /screen", "/SCREEN /SEARCH", "/screen /search /screen /search"] {
      try await verifyFullPanelScreenSubmission(searchEnabled: true, commands: commands)
    }
  }

  func testLongScreenSearchConversationSettlesAtBottom() async throws {
    try await verifyFullPanelScreenSubmission(searchEnabled: true, historyCount: 40)
  }

  private func verifyFullPanelScreenSubmission(searchEnabled: Bool, commands: String? = nil, historyCount: Int = 0) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenPanel-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let suite = "ScreenPanel-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.set(true, forKey: "localModelOnboardingDismissed")
    defaults.set(ChatMode.auto.rawValue, forKey: StartPreferences.modeKey)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: directory)
      UserDefaults().removePersistentDomain(forName: suite)
    }
    let stream = AsyncThrowingStream<String, Error>.makeStream()
    let started = expectation(description: "Screen request reaches local text model")
    let model = LocalModel(id: "text", displayName: "Qwen2.5 3B Instruct Q8_0", fileURL: directory.appendingPathComponent("text.gguf"))
    let engine = PanelScreenEngine(model: model, response: stream.stream, started: { started.fulfill() })
    let search = PanelSearch()
    let store = ChatSessionStore(applicationSupportDirectory: directory)
    if historyCount > 0 {
      let history = (0..<historyCount).map { index in
        ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant,
          content: "Earlier message \(index). " + String(repeating: "A longer reply with wrapping text. ", count: 1 + index % 12))
      }
      try store.save([ChatSession(messages: history)])
    }
    let chat = LocalChatViewModel(engine: engine, webSearch: search,
                                 sessionStore: store)
    await chat.refreshInstalledModel()
    let screen = ScreenComposerCoordinator(captureService: PreviewCapture(), ocrService: PreviewOCR())
    let credentials = ScreenTestCredentialStore()
    let cloud = CloudSettingsModel(credentialStore: credentials,
      catalog: CloudModelCatalog(credentialStore: credentials, transport: ScreenTestTransport(), cacheDirectory: directory),
      preferences: CloudPreferencesStore(defaults: defaults), codexAvailable: { false })
    let advisor = LocalModelAdvisor(directory: directory, modelsDirectory: directory, defaults: defaults, trust: nil)
    await advisor.start(installedModels: [model])
    let appearance = GlassAppearanceSettings(defaults: defaults)
    let view = NSHostingView(rootView: AppShellView(glassAppearance: appearance, cloudSettings: cloud,
      localChat: chat, screen: screen, modelAdvisor: advisor,
      searchSettings: WebSearchSettings(credentials: PresenceOnlyCredentials(), defaults: defaults),
      startPreferences: StartPreferences(defaults: defaults), welcomeSetup: WelcomeSetup(defaults: defaults))
      .transaction { if historyCount == 0 { $0.disablesAnimations = true } })
    let sizes = PanelSizeStore(defaults: defaults)
    sizes.save(NSSize(width: 752, height: 462))
    let controller = SpotlightPanelController(glassAppearance: appearance, sizeStore: sizes, contentView: view)
    controller.show()
    defer { controller.hide() }
    let prompt = "What is the answer to this piece of code?"
    if let commands {
      view.layoutSubtreeIfNeeded()
      screen.draft = commands + " " + prompt
      // Submit in the same turn, before SwiftUI can run an onChange action.
      try submitComposer(in: view)
    } else {
      _ = await screen.capture()
      screen.draft = (searchEnabled ? "/search " : "") + prompt
      try await renderPanel(view, state: "attached")
      XCTAssertEqual(screen.draft, (searchEnabled ? "/search " : "") + prompt)
      try submitComposer(in: view)
    }
    await fulfillment(of: [started], timeout: 5)
    try await renderPanel(view, state: "loading")
    let reply = expectation(description: "First reply appears")
    let replyToken = chat.$sessions.filter { $0.flatMap(\.messages).contains { $0.content == "The answer is values.count." } }
      .prefix(1).sink { _ in reply.fulfill() }
    stream.continuation.yield("The answer is values.count.")
    await fulfillment(of: [reply], timeout: 5)
    replyToken.cancel()
    try await renderPanel(view, state: "reply")
    if searchEnabled && historyCount == 0 && commands == nil {
      try await verifyActivityExpansion(in: view, chat: chat)
    }
    if searchEnabled {
      let png = try Data(contentsOf: URL(fileURLWithPath: "/tmp/AI-Spotlight-Panel-reply.png"))
      try png.write(to: URL(fileURLWithPath: "/tmp/AI-Spotlight-Screen-Search.png"))
      let scroll = try XCTUnwrap(descendants(view).compactMap { $0 as? NSScrollView }
        .filter { !($0.documentView is SlashCommandTextView) }
        .max { view.convert($0.bounds, from: $0).midX < view.convert($1.bounds, from: $1).midX })
      let suffix = String(repeating: " More detail.", count: 80)
      let bottom = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        guard let document = scroll.documentView,
              chat.messages.last?.content == "The answer is values.count." + suffix else { return false }
        return document.bounds.height > scroll.contentView.bounds.height
          // The last message ends before the stack's 24-point bottom padding.
          && abs(scroll.documentVisibleRect.maxY - document.bounds.maxY) <= 25
      }, object: nil)
      let burst = expectation(description: "All rapid reply fragments appear")
      let burstToken = chat.$sessions.filter {
        $0.flatMap(\.messages).last?.content == "The answer is values.count." + suffix
      }.prefix(1).sink { _ in burst.fulfill() }
      for _ in 0..<80 { stream.continuation.yield(" More detail.") }
      await fulfillment(of: [burst, bottom], timeout: 5)
      XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0,
                           "Expected a scroll, visible: \(scroll.documentVisibleRect), document: \(String(describing: scroll.documentView?.bounds))")
      burstToken.cancel()
      await Task.yield()
      view.layoutSubtreeIfNeeded()
      if historyCount > 0 {
        let observer = try XCTUnwrap(descendants(view).compactMap { $0 as? ConversationScrollObserver.ObserverView }.first)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY - 8))
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(observer.followsLatest, "Even a small scroll must let the reader leave the bottom")
        let readingPosition = scroll.contentView.bounds.minY
        let extra = String(repeating: " Additional streamed detail.", count: 40)
        let received = expectation(description: "Reply grows while reading history")
        let receivedToken = chat.$sessions.filter { $0.flatMap(\.messages).last?.content.hasSuffix(extra) == true }
          .prefix(1).sink { _ in received.fulfill() }
        stream.continuation.yield(extra)
        await fulfillment(of: [received], timeout: 5)
        receivedToken.cancel()
        view.layoutSubtreeIfNeeded()
        observer.scrollToBottomIfFollowing()
        XCTAssertFalse(observer.followsLatest)
        XCTAssertEqual(scroll.contentView.bounds.minY, readingPosition, accuracy: 2,
                       "Streaming must not pull the reader back to the newest reply")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        view.layoutSubtreeIfNeeded()
        observer.scrollToBottomIfFollowing()
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 2, "The oldest messages remain reachable")
      }
    }
    let done = expectation(description: "Request finished")
    let token = chat.$state.filter { $0 == .idle }.prefix(1).sink { _ in done.fulfill() }
    stream.continuation.finish()
    await fulfillment(of: [done], timeout: 5)
    token.cancel()
    if !searchEnabled { try await renderPanel(view, state: "finished") }
    XCTAssertNil(screen.attachment)
    XCTAssertFalse(chat.isBusy)
    let queries = await search.queries
    XCTAssertEqual(queries, searchEnabled ? ["Swift values.count meaning"] : [])
    XCTAssertEqual(chat.messages.count, historyCount + 2)
    XCTAssertEqual(chat.messages[historyCount].content, prompt)
    XCTAssertEqual(chat.messages.last?.searchSources, searchEnabled ? [PanelSearch.source] : nil)
    XCTAssertEqual(screen.draft, "")
  }

  func testRepeatedScreenSubmissionsKeepFullPanelInsideWindow() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RepeatedScreenPanel-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let suite = "RepeatedScreenPanel-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.set(true, forKey: "localModelOnboardingDismissed")
    defaults.set(ChatMode.auto.rawValue, forKey: StartPreferences.modeKey)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: directory)
      UserDefaults().removePersistentDomain(forName: suite)
    }
    let model = LocalModel(id: "text", displayName: "Text", fileURL: directory.appendingPathComponent("text.gguf"))
    let engine = RepeatedPanelEngine(model: model)
    let store = ChatSessionStore(applicationSupportDirectory: directory)
    let chat = LocalChatViewModel(engine: engine, sessionStore: store)
    await chat.refreshInstalledModel()
    chat.newChat()
    let session = chat.selectedSessionID
    let screen = ScreenComposerCoordinator(captureService: PreviewCapture(), ocrService: PreviewOCR())
    let credentials = ScreenTestCredentialStore()
    let cloud = CloudSettingsModel(credentialStore: credentials,
      catalog: CloudModelCatalog(credentialStore: credentials, transport: ScreenTestTransport(), cacheDirectory: directory),
      preferences: CloudPreferencesStore(defaults: defaults), codexAvailable: { false })
    let advisor = LocalModelAdvisor(directory: directory, modelsDirectory: directory, defaults: defaults, trust: nil)
    await advisor.start(installedModels: [model])
    let appearance = GlassAppearanceSettings(defaults: defaults)
    let view = NSHostingView(rootView: AppShellView(glassAppearance: appearance, cloudSettings: cloud,
      localChat: chat, screen: screen, modelAdvisor: advisor,
      searchSettings: WebSearchSettings(credentials: PanelSearchCredentials(), defaults: defaults),
      startPreferences: StartPreferences(defaults: defaults), welcomeSetup: WelcomeSetup(defaults: defaults)))
    let sizes = PanelSizeStore(defaults: defaults)
    sizes.save(NSSize(width: 752, height: 462))
    let controller = SpotlightPanelController(glassAppearance: appearance, sizeStore: sizes, contentView: view)
    controller.show()
    defer { controller.hide() }
    let window = try XCTUnwrap(view.window)

    for size in [NSSize(width: 1200, height: 780), NSSize(width: 640, height: 420)] {
      window.setContentSize(size)
      await Task.yield()
      view.layoutSubtreeIfNeeded()
      let field = try composerField(in: view)
      XCTAssertTrue(view.bounds.contains(view.convert(field.bounds, from: field)))
      let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      try png.write(to: URL(fileURLWithPath: "/tmp/AI-Spotlight-Glass-\(Int(size.width)).png"))
      let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
      attachment.name = "Liquid Glass welcome \(Int(size.width))"
      attachment.lifetime = .keepAlways
      add(attachment)

      let composerFrame = view.convert(field.bounds, from: field)
      screen.draft = "Explain /think using /"
      await Task.yield()
      view.layoutSubtreeIfNeeded()
      XCTAssertTrue(window.makeFirstResponder(field))
      await Task.yield()
      field.setSelectedRange(NSRange(location: (field.string as NSString).length, length: 0))
      field.completion?.refresh()
      await Task.yield()
      view.layoutSubtreeIfNeeded()
      XCTAssertEqual(field.completion?.commands, [.screen, .snapshot, .think, .edit, .translate])
      XCTAssertEqual(view.convert(field.bounds, from: field), composerFrame,
                     "Suggestions must not resize or move the compact composer")
      XCTAssertEqual(field.font?.pointSize, size.width < 900 ? 14 : 15)
      let deadline = ContinuousClock.now.advanced(by: .seconds(2))
      var menuText = ""
      var menuPNG = Data()
      repeat {
        await Task.yield()
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let menuBitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: menuBitmap)
        menuText = try await ScreenOCRService().recognize(XCTUnwrap(menuBitmap.cgImage)).text.lowercased()
        menuPNG = try XCTUnwrap(menuBitmap.representation(using: .png, properties: [:]))
      } while !menuText.contains("capture all displays") && ContinuousClock.now < deadline
      XCTAssertTrue(menuText.contains("capture all displays"), "Suggestions must be visibly rendered: \(menuText)")
      XCTAssertFalse(menuText.contains("search the web"), "Without a key, search must not be offered")
      try menuPNG.write(to: URL(fileURLWithPath: "/tmp/Enigma-Slash-Commands-\(Int(size.width)).png"))
      let menuAttachment = XCTAttachment(data: menuPNG, uniformTypeIdentifier: "public.png")
      menuAttachment.name = "Enigma slash commands \(Int(size.width))"
      menuAttachment.lifetime = .keepAlways
      add(menuAttachment)
      field.completion?.dismiss()
      screen.draft = ""
    }
    window.setContentSize(NSSize(width: 752, height: 462))

    view.layoutSubtreeIfNeeded()
    XCTAssertFalse(descendants(view).compactMap { $0 as? NSScrollView }.contains {
      let frame = view.convert($0.bounds, from: $0)
      return frame.minX < 30 && frame.width >= 176 && frame.width < 270
    }, "History must be hidden when the app starts")
    NotificationCenter.default.post(name: .sidebarToggleRequested, object: nil)
    try await assertPanelControls(view, phase: "history opened from hidden startup")

    screen.draft = "Preserve this draft while toggling history"
    NotificationCenter.default.post(name: .sidebarToggleRequested, object: nil)
    await Task.yield()
    view.layoutSubtreeIfNeeded()
    let hiddenBitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: hiddenBitmap)
    let hiddenText = try await ScreenOCRService().recognize(XCTUnwrap(hiddenBitmap.cgImage)).text.lowercased()
    XCTAssertTrue(hiddenText.contains("help"), "Help must remain visible without the sidebar")
    XCTAssertEqual(screen.draft, "Preserve this draft while toggling history")
    XCTAssertEqual(chat.selectedSessionID, session)
    let hiddenPNG = try XCTUnwrap(hiddenBitmap.representation(using: .png, properties: [:]))
    try hiddenPNG.write(to: URL(fileURLWithPath: "/tmp/Enigma-Hidden-Sidebar.png"))
    let hiddenAttachment = XCTAttachment(data: hiddenPNG, uniformTypeIdentifier: "public.png")
    hiddenAttachment.name = "Hidden history with accessible Help"
    hiddenAttachment.lifetime = .keepAlways
    add(hiddenAttachment)
    NotificationCenter.default.post(name: .sidebarToggleRequested, object: nil)
    await Task.yield()
    try await assertPanelControls(view, phase: "sidebar restored")
    XCTAssertEqual(chat.selectedSessionID, session)
    screen.draft = ""

    // The layout failure is also reachable on a first blocked request; it
    // depends on the detail's measurement, not a global submission counter.
    screen.draft = "Describe the colors in this diagram."
    _ = await screen.capture()
    try await assertPanelControls(view, phase: "fresh attachment")
    try submitComposer(in: view)
    try await assertPanelControls(view, phase: "first blocked request")
    XCTAssertNotNil(screen.error)
    XCTAssertTrue(chat.messages.isEmpty)
    XCTAssertTrue(engine.requests.isEmpty)
    screen.removeAttachment()

    for cycle in 1...2 {
      screen.draft = "Explain the code in capture \(cycle)."
      if cycle == 1 {
        _ = await screen.capture()
        let original = screen.attachment?.id
        _ = await screen.capture() // Two captures without two submissions.
        XCTAssertNotEqual(screen.attachment?.id, original)
        XCTAssertTrue(engine.requests.isEmpty)
      } else {
        screen.draft = "/screen " + screen.draft
      }
      try await assertPanelControls(view, phase: "before request \(cycle)")
      let completed = expectation(description: "Request \(cycle) completed")
      let token = chat.$state.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in completed.fulfill() }
      try submitComposer(in: view)
      await fulfillment(of: [completed], timeout: 5)
      token.cancel()
      try await assertPanelControls(view, phase: "submission \(cycle)")
      XCTAssertEqual(chat.selectedSessionID, session)
      XCTAssertEqual(chat.messages.filter { $0.role == .user }.count, cycle)
      XCTAssertEqual(engine.requests.count, cycle)
      XCTAssertNil(screen.attachment)
      XCTAssertEqual(screen.draft, "")
      XCTAssertFalse(screen.isEnabled)
      XCTAssertFalse(screen.isBusy)
      XCTAssertNil(chat.activeRequest)
      XCTAssertEqual(chat.state, .idle)
      XCTAssertFalse(chat.isBusy)
      XCTAssertTrue(controller.isVisible)
      XCTAssertTrue(window.isKeyWindow)
      XCTAssertTrue(window.firstResponder === (try composerField(in: view)), "The completed request must return keyboard focus to the composer")
      XCTAssertFalse(window.ignoresMouseEvents)
    }
    await chat.sessionWriter.waitForPendingWrites()
    XCTAssertEqual(store.load().first?.messages.filter { $0.role == .user }.map(\.content),
      ["Explain the code in capture 1.", "Explain the code in capture 2."])

    // A blocked vision route adds a wrapped error without starting a producer.
    // This was the exact second-send reflow observed in the signed app.
    _ = await screen.capture()
    screen.draft = "Describe the image."
    screen.error = "Visual analysis requires a local vision model or screenshot-upload permission in Screen settings."
    try await assertPanelControls(view, phase: "blocked vision")
    XCTAssertEqual(engine.requests.count, 2)
    XCTAssertNotNil(screen.attachment)
    screen.removeAttachment()
    try await assertPanelControls(view, phase: "removed attachment")
  }

  private func pressActivityStatus(in view: NSView) throws {
    view.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
    let label = try XCTUnwrap(request.results?.filter {
      $0.topCandidates(1).first?.string.lowercased().contains("generating response") == true
    }.max { $0.boundingBox.midY < $1.boundingBox.midY })
    let point = NSPoint(x: label.boundingBox.midX * view.bounds.width,
      y: (view.isFlipped ? 1 - label.boundingBox.midY : label.boundingBox.midY) * view.bounds.height)
    let window = try XCTUnwrap(view.window)
    let location = view.convert(point, to: nil)
    for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
      window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location,
        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
    }
  }

  private func verifyActivityExpansion(in view: NSView, chat: LocalChatViewModel) async throws {
    let originalSize = view.bounds.size
    view.window?.setContentSize(NSSize(width: 752, height: 760))
    await Task.yield()
    view.layoutSubtreeIfNeeded()
    try pressActivityStatus(in: view)
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    let expectedLabels = ["request activity", "web sources", "code reference"]
    var text = ""
    var png = Data()
    // The section heading appears before the source finishes expanding into view.
    repeat {
      await Task.yield()
      view.layoutSubtreeIfNeeded()
      view.window?.displayIfNeeded()
      let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      text = try await ScreenOCRService().recognize(XCTUnwrap(bitmap.cgImage)).text.lowercased()
    } while !expectedLabels.allSatisfy(text.contains) && ContinuousClock.now < deadline
    for label in expectedLabels { XCTAssertTrue(text.contains(label), "Expected \(label): \(text)") }
    XCTAssertEqual(chat.messages.last?.activity?.sources, [PanelSearch.source])
    try png.write(to: URL(fileURLWithPath: "/tmp/AI-Spotlight-Activity-App.png"))
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = "Live activity in current Liquid Glass app"
    attachment.lifetime = .keepAlways
    add(attachment)
    try pressActivityStatus(in: view)
    await Task.yield()
    view.window?.setContentSize(originalSize)
  }

  private func submitComposer(in view: NSView) throws {
    let window = try XCTUnwrap(view.window)
    XCTAssertTrue(window.makeFirstResponder(try composerField(in: view)))
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
    editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
  }

  private func composerField(in view: NSView) throws -> SlashCommandTextView {
    try XCTUnwrap(descendants(view).compactMap { $0 as? SlashCommandTextView }.first)
  }

  private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
  }

  private func assertPanelControls(_ view: NSView, phase: String) async throws {
    await Task.yield()
    view.layoutSubtreeIfNeeded()
    view.window?.displayIfNeeded()
    let field = try composerField(in: view)
    let fieldFrame = view.convert(field.bounds, from: field)
    XCTAssertTrue(view.bounds.contains(fieldFrame), "Composer outside panel during \(phase): \(fieldFrame)")
    XCTAssertFalse(field.isHiddenOrHasHiddenAncestor)
    XCTAssertTrue(field.isEditable)
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let rendered = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    rendered.name = "Repeated Screen · \(phase)"
    rendered.lifetime = .keepAlways
    add(rendered)
    let text = try await ScreenOCRService().recognize(try XCTUnwrap(bitmap.cgImage)).text.lowercased()
    // Native glass renders on a separate surface from cacheDisplay. Verify
    // the actual sidebar, its scroll content, and its position in the panel.
    let history = try XCTUnwrap(descendants(view).compactMap { $0 as? NSScrollView }.first {
      view.convert($0.bounds, from: $0).minX < 30
    })
    let historyFrame = view.convert(history.bounds, from: history)
    XCTAssertFalse(history.isHiddenOrHasHiddenAncestor)
    XCTAssertGreaterThanOrEqual(historyFrame.width, 176)
    XCTAssertLessThan(historyFrame.width, 270)
    XCTAssertEqual(historyFrame.minY, 12, accuracy: 1, "Inset sidebar moved during \(phase)")
    XCTAssertEqual(historyFrame.height, view.bounds.height - 24, accuracy: 1)
    XCTAssertTrue(view.bounds.contains(historyFrame), "History outside panel during \(phase)")
    XCTAssertGreaterThan(try XCTUnwrap(history.documentView).frame.height, 0)
    XCTAssertTrue(text.contains("auto"), "Composer mode missing during \(phase): \(text)")
  }

  private func renderPanel(_ view: NSView, state: String) async throws {
    let expected = switch state {
    case "attached": ["screen region", "what is the answer"]
    case "loading": ["thinking", "stop", "what is the answer"]
    case "reply": ["the answer is", "generating response", "stop"]
    default: ["the answer is", "local ocr"]
    }
    // Real animations can leave labels temporarily transparent. Wait for the
    // same required pixels instead of assuming one main-actor yield is enough.
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    var text = ""
    var png = Data()
    repeat {
      await Task.yield()
      view.layoutSubtreeIfNeeded()
      view.window?.displayIfNeeded()
      let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      text = try await ScreenOCRService().recognize(XCTUnwrap(bitmap.cgImage)).text.lowercased()
    } while !expected.allSatisfy(text.contains) && ContinuousClock.now < deadline
    try png.write(to: URL(fileURLWithPath: "/tmp/AI-Spotlight-Panel-\(state).png"))
    let rendered = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    rendered.name = "Screen panel · \(state)"
    rendered.lifetime = .keepAlways
    add(rendered)
    XCTAssertEqual(view.bounds.size, NSSize(width: 752, height: 462))
    if state == "reply" || state == "finished" {
      // OCR can merge the placeholder with adjacent tool icons. Inspect the
      // native field and its visible bounds to verify the actual composer instead.
      let field = try composerField(in: view)
      XCTAssertEqual(field.string, "")
      XCTAssertFalse(field.isHiddenOrHasHiddenAncestor)
      XCTAssertTrue(view.bounds.contains(view.convert(field.bounds, from: field)))
    }
    for phrase in expected {
      XCTAssertTrue(text.contains(phrase), "Visible panel content missing during \(state): \(phrase)")
    }
  }

  func testCompactCaptureShowsRetakeAndRemoveAndExcludesRemovedImageFromNextRequest() async throws {
    for command in ["/screen", "/snapshot"] {
      let fixture = try await makeScreenshotComposer(compact: true, mode: .cloud)
      defer { fixture.controller.hide(); fixture.window.contentView = nil }
      try await editScreenshotComposer(command, in: fixture)
      try submitComposer(in: fixture.view)
      await waitForScreenshotState { fixture.screen.attachment != nil && !fixture.screen.isBusy }
      XCTAssertEqual(fixture.screen.draft, "")
      XCTAssertTrue(fixture.chat.isTemporaryChat)
      XCTAssertTrue(fixture.controller.isSelectionComposer, "A standalone capture must wait for a question")
      XCTAssertTrue(fixture.engine.requests.isEmpty)
      XCTAssertTrue(fixture.cloudProvider.requests.isEmpty)
      XCTAssertNil(fixture.window.attachedSheet)
      XCTAssertEqual(fixture.screen.attachment?.source, command == "/screen" ? .fullDesktop : .screenRegion)
      let originalID = try XCTUnwrap(fixture.screen.attachment?.id)
      let text = try screenshotText(in: fixture.view, name: "compact-\(command.dropFirst())")
      XCTAssertTrue(text.contains(command == "/screen" ? "all displays" : "screen region"), text)
      XCTAssertTrue(text.contains("attached"), text)
      XCTAssertTrue(text.contains("retake"), text)
      XCTAssertTrue(text.contains("remove"), text)
      let editor = try composerField(in: fixture.view)
      XCTAssertTrue(fixture.view.bounds.contains(fixture.view.convert(editor.bounds, from: editor)))

      try await editScreenshotComposer("Explain the attached passage", in: fixture)
      NotificationCenter.default.post(name: .hideInactiveToolsRequested, object: nil)
      await settleScreenshotView(fixture.view)
      XCTAssertEqual(fixture.screen.attachment?.id, originalID)
      try await pressScreenshotControl("Retake", in: fixture.view)
      await waitForScreenshotState { fixture.screen.attachment?.id != originalID && !fixture.screen.isBusy }
      XCTAssertEqual(fixture.capture.desktopCount, command == "/screen" ? 2 : 0)
      XCTAssertEqual(fixture.capture.regionCount, command == "/snapshot" ? 2 : 0)
      XCTAssertEqual(fixture.screen.draft, "Explain the attached passage")
      await settleScreenshotView(fixture.view)
      try await pressScreenshotControl("Remove", in: fixture.view)
      await waitForScreenshotState { fixture.screen.attachment == nil }
      XCTAssertFalse(fixture.screen.isEnabled)
      XCTAssertEqual(fixture.screen.draft, "Explain the attached passage")
      await settleScreenshotView(fixture.view)
      XCTAssertFalse(try screenshotText(in: fixture.view).contains("retake"))
      try submitComposer(in: fixture.view)
      await waitForScreenshotState { !fixture.cloudProvider.requests.isEmpty && !fixture.chat.isBusy }
      let request = try XCTUnwrap(fixture.cloudProvider.requests.first)
      XCTAssertNil(request.image)
      XCTAssertFalse(request.allowsCloudImages)
      XCTAssertTrue(request.messages.last?.content.contains("Selected passage fixture") == true)
      XCTAssertFalse(request.messages.contains { $0.content.contains("values.count") || $0.imagePreview != nil })
      XCTAssertNil(fixture.chat.messages.first?.imagePreview)
      XCTAssertTrue(fixture.engine.requests.isEmpty)
      XCTAssertFalse(fixture.settings.allowCloudScreenshots)
    }
  }

  func testRealComposerConsentNamesCaptureAndProviderAndDenialKeepsDraft() async throws {
    // Use unambiguous provider glyphs for exact native OCR assertions. The image
    // approval test separately verifies OpenAI as the actual request destination.
    for (command, provider) in [("/screen", CloudProviderID.gemini), ("/snapshot", .anthropic)] {
      let fixture = try await makeScreenshotComposer(compact: command == "/snapshot", mode: .cloud, provider: provider)
      defer { fixture.controller.hide(); fixture.window.contentView = nil }
      try await editScreenshotComposer(command + " What color is this?", in: fixture)
      try submitComposer(in: fixture.view)
      await waitForScreenshotState { fixture.window.attachedSheet != nil }
      let sheet = try XCTUnwrap(fixture.window.attachedSheet?.contentView)
      await settleScreenshotView(sheet)
      XCTAssertEqual(sheet.window?.sharingType, .none as NSWindow.SharingType)
      let text = try screenshotText(in: sheet, name: "consent-\(command.dropFirst())")
      let labels = try screenshotLabels(in: sheet).map(\.string)
      XCTAssertTrue(labels.contains(command == "/screen" ? "Send full desktop to Gemini?" : "Send selected region to Anthropic?"), "\(labels)")
      XCTAssertTrue(text.contains(command == "/screen" ? "send full desktop to" : "send selected region to"), text)
      XCTAssertTrue(text.contains(command == "/screen" ? "captures the full desktop, including all displays" : "captures the selected region"), text)
      let previewText = text.filter { !$0.isWhitespace }
      XCTAssertTrue(previewText.contains("letanswer=values.count") && previewText.contains("print(answer)"),
        "Both lines of the actual captured image must be previewed: \(text)")
      XCTAssertTrue(text.contains("future region and full-desktop screenshots"), text)
      XCTAssertTrue(text.contains("whichever cloud provider"), text)
      XCTAssertTrue(text.contains("without uploading an image"), text)
      XCTAssertTrue(fixture.cloudProvider.requests.isEmpty)
      XCTAssertFalse(fixture.settings.allowCloudScreenshots)
      let attachmentID = fixture.screen.attachment?.id
      try await pressScreenshotControl("Keep Screenshots Local", in: sheet)
      await waitForScreenshotState { fixture.window.attachedSheet == nil }
      XCTAssertFalse(fixture.settings.allowCloudScreenshots)
      XCTAssertTrue(fixture.settings.hasExplainedCloudPermission)
      XCTAssertEqual(fixture.screen.attachment?.id, attachmentID)
      XCTAssertEqual(fixture.screen.draft, "What color is this?")
      XCTAssertTrue(fixture.cloudProvider.requests.isEmpty)
      try submitComposer(in: fixture.view)
      XCTAssertEqual(fixture.screen.attachment?.routingDecision, .blocked(ScreenRoutingPolicy.screenshotUploadDisabledMessage))
      XCTAssertTrue(fixture.cloudProvider.requests.isEmpty)
      XCTAssertNil(fixture.window.attachedSheet)
    }
  }

  func testRealComposerConsentAllowsImageAndRevocationBlocksNextCapture() async throws {
    let fixture = try await makeScreenshotComposer(mode: .cloud, provider: .openAI)
    defer { fixture.controller.hide(); fixture.window.contentView = nil }
    try await editScreenshotComposer("/screen What color is this?", in: fixture)
    try submitComposer(in: fixture.view)
    await waitForScreenshotState { fixture.window.attachedSheet != nil }
    let sheet = try XCTUnwrap(fixture.window.attachedSheet?.contentView)
    await settleScreenshotView(sheet)
    XCTAssertTrue(try screenshotText(in: sheet).contains("send full desktop to"))
    try await pressScreenshotControl("Allow & Send", in: sheet)
    await waitForScreenshotState { fixture.cloudProvider.requests.count == 1 && !fixture.chat.isBusy }
    XCTAssertTrue(fixture.settings.allowCloudScreenshots)
    XCTAssertTrue(fixture.settings.hasExplainedCloudPermission)
    let request = try XCTUnwrap(fixture.cloudProvider.requests.first)
    XCTAssertNotNil(request.image)
    XCTAssertTrue(request.allowsCloudImages)
    XCTAssertEqual(request.route.providerID, CloudProviderID.openAI.rawValue)
    XCTAssertNil(fixture.screen.attachment)
    XCTAssertEqual(fixture.screen.draft, "")
    fixture.settings.allowCloudScreenshots = false
    try await editScreenshotComposer("/snapshot What color is this?", in: fixture)
    try submitComposer(in: fixture.view)
    await waitForScreenshotState { fixture.screen.error != nil && !fixture.screen.isBusy }
    XCTAssertEqual(fixture.cloudProvider.requests.count, 1)
    XCTAssertNotNil(fixture.screen.attachment)
    XCTAssertEqual(fixture.screen.draft, "What color is this?")
    XCTAssertNil(fixture.window.attachedSheet)
  }

  func testRealComposerNeverApprovesAReplacedCaptureOrDestination() async throws {
    for replaceImage in [false, true] {
      let fixture = try await makeScreenshotComposer(mode: .cloud)
      defer { fixture.controller.hide(); fixture.window.contentView = nil }
      try await editScreenshotComposer("/snapshot What color is this?", in: fixture)
      try submitComposer(in: fixture.view)
      await waitForScreenshotState { fixture.window.attachedSheet != nil }
      let sheet = try XCTUnwrap(fixture.window.attachedSheet?.contentView)
      await settleScreenshotView(sheet)
      if replaceImage {
        _ = await fixture.screen.capture()
      } else {
        fixture.cloud.preferredProvider = .anthropic
        fixture.cloud.preferredModelID = "claude-sonnet-4-6"
      }
      try await pressScreenshotControl("Allow & Send", in: sheet)
      await waitForScreenshotState { fixture.window.attachedSheet == nil }
      XCTAssertFalse(fixture.settings.allowCloudScreenshots)
      XCTAssertTrue(fixture.cloudProvider.requests.isEmpty)
      XCTAssertNotNil(fixture.screen.attachment)
      XCTAssertEqual(fixture.screen.draft, "What color is this?")
    }
  }

  func testRealComposerOCRDoesNotRequestImageConsentAndLocalCannotUpload() async throws {
    for mode in [ChatMode.local, .cloud] {
      let fixture = try await makeScreenshotComposer(mode: mode)
      defer { fixture.controller.hide(); fixture.window.contentView = nil }
      if mode == .local { fixture.settings.answerCloudPermission(allow: true) }
      try await editScreenshotComposer("/snapshot Read the text", in: fixture)
      try submitComposer(in: fixture.view)
      await waitForScreenshotState {
        (mode == .local ? !fixture.engine.requests.isEmpty : !fixture.cloudProvider.requests.isEmpty) && !fixture.chat.isBusy
      }
      XCTAssertNil(fixture.window.attachedSheet)
      if mode == .cloud {
        let request = try XCTUnwrap(fixture.cloudProvider.requests.first)
        XCTAssertNil(request.image)
        XCTAssertFalse(request.allowsCloudImages)
        XCTAssertTrue(request.messages.last?.content.contains("values.count") == true)
        XCTAssertFalse(fixture.settings.hasExplainedCloudPermission)
      } else {
        XCTAssertTrue(fixture.cloudProvider.requests.isEmpty)
        try await editScreenshotComposer("/screen What color is this?", in: fixture)
        try submitComposer(in: fixture.view)
        await waitForScreenshotState { fixture.screen.error != nil && !fixture.screen.isBusy }
        XCTAssertTrue(fixture.screen.error?.contains("selected local model is text-only") == true)
        XCTAssertNotNil(fixture.screen.attachment)
        XCTAssertEqual(fixture.screen.draft, "What color is this?")
        XCTAssertTrue(fixture.cloudProvider.requests.isEmpty)
        XCTAssertNil(fixture.window.attachedSheet)
      }
    }
  }

  func testRealComposerScreenRecordingDenialKeepsCompactDraft() async throws {
    let fixture = try await makeScreenshotComposer(compact: true)
    defer { fixture.controller.hide(); fixture.window.contentView = nil }
    fixture.capture.denied = true
    try await editScreenshotComposer("/screen What color is this?", in: fixture)
    try submitComposer(in: fixture.view)
    await waitForScreenshotState { fixture.screen.needsScreenRecordingSettings && !fixture.screen.isBusy }
    XCTAssertTrue(fixture.controller.isSelectionComposer)
    XCTAssertTrue(fixture.window.isVisible)
    XCTAssertNil(fixture.screen.attachment)
    XCTAssertEqual(fixture.screen.draft, "/screen What color is this?")
    XCTAssertEqual(fixture.capture.desktopCount, 0)
    XCTAssertTrue(fixture.engine.requests.isEmpty)
    XCTAssertTrue(fixture.cloudProvider.requests.isEmpty)
    XCTAssertNil(fixture.window.attachedSheet)
  }

  func testRealComposerStopAndTypingRemainResponsiveWhileArchiveWriteIsBlocked() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "StreamingComposer-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let probe = ChatArchiveWriteProbe(store: ChatSessionStore(applicationSupportDirectory: directory), blockFirst: true)
    defer { probe.release() }
    let writer = ChatSessionWriter(write: probe.write)
    let stream = AsyncThrowingStream<String, Error>.makeStream()
    let cancelled = expectation(description: "Stop cancels the producer while disk is blocked")
    stream.continuation.onTermination = { if case .cancelled = $0 { cancelled.fulfill() } }
    let fixture = try await makeScreenshotComposer(sessionWriter: writer, response: stream.stream)
    defer { fixture.controller.hide(); fixture.window.contentView = nil }
    try await editScreenshotComposer("Stream a response", in: fixture)
    try submitComposer(in: fixture.view)
    await fulfillment(of: [probe.started], timeout: 2)
    let visible = expectation(description: "Fast stream is visible while disk is blocked")
    let observation = fixture.chat.$sessions.filter { $0.first?.messages.last?.content.count == 500 }
      .prefix(1).sink { _ in visible.fulfill() }
    for _ in 0..<500 { stream.continuation.yield("x") }
    await fulfillment(of: [visible], timeout: 5)
    observation.cancel()
    await settleScreenshotView(fixture.view)
    XCTAssertFalse(try composerField(in: fixture.view).isEditable, "Preserve the existing busy-composer policy")

    // Exercise the actual shell's Stop command and native editor binding. No
    // archive release or wall-clock latency threshold is needed to prove progress.
    NotificationCenter.default.post(name: .stopStreamingRequested, object: nil)
    await fulfillment(of: [cancelled], timeout: 2)
    await waitForScreenshotState { (try? self.composerField(in: fixture.view).isEditable) == true }
    try await editScreenshotComposer("Typing works before the archive finishes", in: fixture)
    XCTAssertFalse(fixture.chat.isBusy)
    XCTAssertEqual(probe.snapshots.count, 1)
    XCTAssertEqual(fixture.chat.messages.last?.content, String(repeating: "x", count: 500))
    XCTAssertEqual(fixture.screen.draft, "Typing works before the archive finishes")

    probe.release()
    await writer.waitForPendingWrites()
    XCTAssertEqual(probe.snapshots.count, 2)
    XCTAssertEqual(probe.store.load().first?.messages.last?.content, String(repeating: "x", count: 500))
  }

  private func makeScreenshotComposer(compact: Bool = false, mode: ChatMode = .local,
                                      provider: CloudProviderID = .openAI,
                                      sessionWriter: ChatSessionWriter? = nil,
                                      response: AsyncThrowingStream<String, Error>? = nil) async throws -> ScreenshotComposerFixture {
    let suite = "ScreenshotComposer-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.set(true, forKey: WelcomeSetup.completedKey)
    defaults.set(true, forKey: "localModelOnboardingDismissed")
    defaults.set(mode.rawValue, forKey: StartPreferences.modeKey)
    let directory = FileManager.default.temporaryDirectory.appending(path: suite)
    addTeardownBlock {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    let model = LocalModel(id: "text", displayName: "Fixture text model", fileURL: directory.appending(path: "text.gguf"))
    let engine = RepeatedPanelEngine(model: model, response: response)
    let cloudProvider = ComposerScreenProvider()
    let search = WebSearchSettings(credentials: PanelSearchCredentials(), defaults: defaults)
    let chat = LocalChatViewModel(engine: engine,
      cloudProviders: CloudProviderRegistry(openAI: cloudProvider, anthropic: cloudProvider, chatGPT: cloudProvider, gemini: cloudProvider),
      webSearch: PanelSearch(), searchSettings: search, sessionStore: ChatSessionStore(applicationSupportDirectory: directory),
      sessionWriter: sessionWriter)
    await chat.refreshInstalledModel()
    let capture = ComposerCapture()
    let screen = ScreenComposerCoordinator(captureService: capture, ocrService: PreviewOCR())
    let settings = ScreenSettings(defaults: defaults)
    let credentials = ScreenTestCredentialStore(keys: [provider: "fixture"])
    let cloud = CloudSettingsModel(credentialStore: credentials,
      catalog: CloudModelCatalog(credentialStore: credentials, transport: ScreenTestTransport(), cacheDirectory: directory),
      preferences: CloudPreferencesStore(defaults: defaults), codexAvailable: { false })
    cloud.preferredProvider = provider
    cloud.preferredModelID = provider == .gemini ? "gemini-2.5-flash" : provider == .anthropic ? "claude-sonnet-4-6" : "gpt-4o-mini"
    let advisor = LocalModelAdvisor(directory: directory, modelsDirectory: directory, defaults: defaults, trust: nil)
    await advisor.start(installedModels: [model], presentOnboarding: false)
    let appearance = GlassAppearanceSettings(defaults: defaults)
    let view = NSHostingView(rootView: AppShellView(glassAppearance: appearance, cloudSettings: cloud,
      localChat: chat, screen: screen, screenSettings: settings, modelAdvisor: advisor, searchSettings: search,
      startPreferences: StartPreferences(defaults: defaults), welcomeSetup: WelcomeSetup(defaults: defaults))
      .transaction { $0.disablesAnimations = true })
    let sizes = PanelSizeStore(defaults: defaults)
    sizes.save(NSSize(width: 752, height: 462))
    let controller = SpotlightPanelController(glassAppearance: appearance, sizeStore: sizes, contentView: view, reduceMotion: { true })
    controller.show()
    await settleScreenshotView(view)
    let window = try XCTUnwrap(view.window)
    if compact {
      let visible = try XCTUnwrap(window.screen?.visibleFrame)
      controller.presentSelectionContext(ConversationContext(sourceName: "Test editor", text: "Selected passage fixture"),
        cursor: NSPoint(x: visible.midX, y: visible.midY), selection: nil, visible: visible)
      await settleScreenshotView(view)
    }
    return ScreenshotComposerFixture(controller: controller, window: window, view: view, screen: screen,
      capture: capture, chat: chat, engine: engine, cloud: cloud, cloudProvider: cloudProvider, settings: settings)
  }

  private func editScreenshotComposer(_ text: String, in fixture: ScreenshotComposerFixture) async throws {
    let editor = try composerField(in: fixture.view)
    XCTAssertTrue(editor.isEditable)
    editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
    XCTAssertEqual(fixture.screen.draft, text)
    await settleScreenshotView(fixture.view)
  }

  private func settleScreenshotView(_ view: NSView) async {
    for _ in 0..<5 { await Task.yield(); view.layoutSubtreeIfNeeded(); view.window?.displayIfNeeded() }
  }

  private func waitForScreenshotState(_ condition: @escaping () -> Bool) async {
    let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
    await fulfillment(of: [ready], timeout: 5)
  }

  private func screenshotLabels(in view: NSView, name: String? = nil, candidates: Int = 1) throws -> [VNRecognizedText] {
    view.layoutSubtreeIfNeeded()
    view.window?.displayIfNeeded()
    // CI can use a 1× display. Render native content at a fixed scale so caption
    // and provider-name verification does not depend on the runner's screen.
    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
      pixelsWide: Int((view.bounds.width * 3).rounded()), pixelsHigh: Int((view.bounds.height * 3).rounded()),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: bitmap)
    if let name {
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      try png.write(to: URL(fileURLWithPath: "/tmp/Enigma-\(name).png"))
      let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
      attachment.name = name
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
    return (request.results ?? []).flatMap { $0.topCandidates(candidates) }
  }

  private func screenshotText(in view: NSView, name: String? = nil) throws -> String {
    try screenshotLabels(in: view, name: name).map(\.string).joined(separator: " ").lowercased()
  }

  private func pressScreenshotControl(_ title: String, in view: NSView) async throws {
    let window = try XCTUnwrap(view.window)
    // Synthetic events do not perform the window activation of a physical click.
    window.makeKeyAndOrderFront(nil)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    var renderedLabel: VNRecognizedText?
    repeat {
      await settleScreenshotView(view)
      renderedLabel = try screenshotLabels(in: view, candidates: 3).first { $0.string.contains(title) }
    } while renderedLabel == nil && ContinuousClock.now < deadline
    let label = try XCTUnwrap(renderedLabel, "Visible control: \(title)")
    let range = try XCTUnwrap(label.string.range(of: title))
    let bounds = try XCTUnwrap(label.boundingBox(for: range)).boundingBox
    let point = NSPoint(x: bounds.midX * view.bounds.width,
      y: (view.isFlipped ? 1 - bounds.midY : bounds.midY) * view.bounds.height)
    let location = view.convert(point, to: nil)
    for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
      let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location,
        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
      window.sendEvent(event)
    }
  }

}

private struct PresenceOnlyCredentials: CloudCredentialStore, WebSearchCredentialStore {
  func containsAPIKey(for provider: CloudProviderID) -> Bool { true }
  func containsAPIKey() -> Bool { true }
  func apiKey(for provider: CloudProviderID) -> String? { apiKey() }
  func apiKey() -> String? {
    XCTFail("Checking availability must not decrypt a secret or open a Keychain prompt")
    return nil
  }
  func setAPIKey(_ value: String, for provider: CloudProviderID) {}
  func removeAPIKey(for provider: CloudProviderID) {}
  func setAPIKey(_ value: String) {}
  func removeAPIKey() {}
}

private struct PanelSearchCredentials: WebSearchCredentialStore {
  func apiKey() -> String? { nil }
  func setAPIKey(_ value: String) {}
  func removeAPIKey() {}
}

private actor PanelSearch: WebSearchProvider {
  static let source = WebSearchSource(title: "Code reference", url: URL(string: "https://example.com/code")!)
  private(set) var queries: [String] = []
  func search(_ query: String, maximumTokens: Int) async throws -> [WebSearchResult] {
    queries.append(query)
    return [WebSearchResult(source: Self.source, snippets: ["The count property returns the number of elements."])]
  }
}

private actor PanelScreenEngine: LocalModelEngine {
  let model: LocalModel
  nonisolated let response: AsyncThrowingStream<String, Error>
  nonisolated let started: @Sendable () -> Void
  init(model: LocalModel, response: AsyncThrowingStream<String, Error>, started: @escaping @Sendable () -> Void) {
    self.model = model; self.response = response; self.started = started
  }
  func installedModel() -> LocalModel? { model }
  func installedModels() -> [LocalModel] { [model] }
  func install(_ model: LocalModel) {}
  func selectModel(id: String) {}
  func download(_ model: LocalModelDescriptor, progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) -> LocalModel { self.model }
  nonisolated func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error> {
    if request.prompt.hasPrefix("Read the attached screenshot") {
      return AsyncThrowingStream { $0.yield("Swift values.count meaning"); $0.finish() }
    }
    started()
    return response
  }
  func unload() {}
}

@MainActor
private struct PreviewCapture: ScreenCapturing {
  func capture() async throws -> NSImage? {
    NSImage(size: NSSize(width: 600, height: 200), flipped: false) { rect in
      NSColor(white: 0.12, alpha: 1).setFill(); rect.fill()
      ("let answer = values.count\nprint(answer)" as NSString).draw(at: NSPoint(x: 20, y: 60), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 28, weight: .regular), .foregroundColor: NSColor.systemGreen])
      return true
    }
  }
}

private struct PreviewOCR: ScreenOCRReading {
  func recognize(_ image: CGImage) async throws -> ScreenOCRResult {
    ScreenOCRResult(text: "let answer = values.count\nprint(answer)\n// explain this code", confidence: 0.95)
  }
}

private final class RepeatedPanelEngine: LocalModelEngine, @unchecked Sendable {
  let model: LocalModel
  private let response: AsyncThrowingStream<String, Error>?
  private let lock = NSLock()
  private var captured: [LocalModelRequest] = []
  var requests: [LocalModelRequest] { lock.withLock { captured } }
  init(model: LocalModel, response: AsyncThrowingStream<String, Error>? = nil) {
    self.model = model
    self.response = response
  }
  func installedModel() async -> LocalModel? { model }
  func installedModels() async -> [LocalModel] { [model] }
  func install(_ model: LocalModel) async throws {}
  func selectModel(id: String) async throws {}
  func download(_ model: LocalModelDescriptor, progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws -> LocalModel { self.model }
  func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error> {
    lock.withLock { captured.append(request) }
    if let response { return response }
    return AsyncThrowingStream { $0.yield("The answer is values.count."); $0.finish() }
  }
  func unload() async {}
}

private final class ConversationTestDocument: NSView {
  private let usesFlippedCoordinates: Bool
  init(flipped: Bool) {
    self.usesFlippedCoordinates = flipped
    super.init(frame: .zero)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var isFlipped: Bool { usesFlippedCoordinates }
}

@MainActor
private struct ScreenshotComposerFixture {
  let controller: SpotlightPanelController
  let window: NSWindow
  let view: NSView
  let screen: ScreenComposerCoordinator
  let capture: ComposerCapture
  let chat: LocalChatViewModel
  let engine: RepeatedPanelEngine
  let cloud: CloudSettingsModel
  let cloudProvider: ComposerScreenProvider
  let settings: ScreenSettings
}

@MainActor
private final class ComposerCapture: ScreenCapturing {
  var denied = false
  private(set) var regionCount = 0
  private(set) var desktopCount = 0
  func prepareForCapture() throws {
    if denied { throw ScreenCaptureError.permissionDenied }
  }
  func capture() async throws -> NSImage? {
    regionCount += 1
    return try await PreviewCapture().capture()
  }
  func captureDesktop() async throws -> NSImage? {
    desktopCount += 1
    return try await PreviewCapture().capture()
  }
}

private final class ComposerScreenProvider: ChatProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var captured: [ChatRequest] = []
  var requests: [ChatRequest] { lock.withLock { captured } }
  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    lock.withLock { captured.append(request) }
    return AsyncThrowingStream { $0.yield(.token("Fixture answer")); $0.yield(.completed); $0.finish() }
  }
}
