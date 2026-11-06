import XCTest
@testable import Enigma

final class BugReportTests: XCTestCase {
  private let diagnostics = BugReport.Diagnostics(
    appVersion: "0.13.1 (7)", macOS: "Version 26.1 (Build 25B78)", chip: "Apple M3 Pro", memory: "36 GB",
    route: "Cloud · OpenAI · GPT-5.5", localModel: "Qwen 3 8B", cloudModel: "gpt-5.5")

  private func chat() -> ChatSession {
    var user = ChatMessage(role: .user, content: "Why did it crash?")
    user.attachments = [MessageAttachment(name: "secret-plans.pdf", isDirectory: false)]
    user.contexts = [ConversationContext(sourceName: "Notes", text: "selected secret")]
    user.imagePreview = Data([1, 2, 3])
    let reply = ChatMessage(role: .assistant, content: "It ran out of memory.")
    return ChatSession(title: "Crash", messages: [user, reply])
  }

  func testRecipientComesFromInfoPlist() {
    XCTAssertEqual(BugReport.recipient(info: ["EnigmaBugReportEmail": "bugs@example.com"]), "bugs@example.com")
    XCTAssertNil(BugReport.recipient(info: [:]))
    XCTAssertNil(BugReport.recipient(info: ["EnigmaBugReportEmail": "  "]))
    XCTAssertEqual(BugReport.recipient(info: Bundle(for: LocalChatViewModel.self).infoDictionary ?? [:]),
                   "enigmabugreporting@gmail.com")
  }

  func testEndpointComesFromInfoPlistAndIsHTTPS() {
    XCTAssertEqual(BugReport.endpoint(info: ["EnigmaBugReportURL": "https://example.com/f/abc"]),
                   URL(string: "https://example.com/f/abc"))
    XCTAssertNil(BugReport.endpoint(info: [:]))
    XCTAssertNil(BugReport.endpoint(info: ["EnigmaBugReportURL": "http://example.com/f/abc"]))
    XCTAssertEqual(BugReport.endpoint(info: Bundle(for: LocalChatViewModel.self).infoDictionary ?? [:]),
                   URL(string: "https://formspree.io/f/mjyyanzn"))
  }

  func testReplyToOnlyForAnAddress() {
    var report = BugReport()
    XCTAssertNil(report.replyTo)
    report.contactEmail = " me@example.com\n"
    XCTAssertEqual(report.replyTo, "me@example.com")
    for text in ["me", "me@example", "me @example.com", "a@b.c@d"] {
      report.contactEmail = text
      XCTAssertNil(report.replyTo, text)
    }
  }

  func testRequestIsAnonymousUnlessAReplyAddressIsGiven() throws {
    let endpoint = try XCTUnwrap(URL(string: "https://example.com/f/abc"))
    func fields(_ request: URLRequest) throws -> [String: String] {
      try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
    }
    let anonymous = BugReportSender.request(endpoint: endpoint, body: "The body", replyTo: nil)
    XCTAssertEqual(anonymous.url, endpoint)
    XCTAssertEqual(anonymous.httpMethod, "POST")
    XCTAssertEqual(anonymous.value(forHTTPHeaderField: "Accept"), "application/json")
    XCTAssertEqual(anonymous.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertEqual(try fields(anonymous), ["_subject": "Enigma bug report", "message": "The body"])
    let named = BugReportSender.request(endpoint: endpoint, body: "The body", replyTo: "me@example.com")
    XCTAssertEqual(try fields(named)["email"], "me@example.com")
  }

  func testSendSucceedsOnlyOnA2xx() async throws {
    let request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.com/f/abc")))
    let ok = await BugReportSender.send(request, transport: ReportTransport(result: .success(200)))
    let rejected = await BugReportSender.send(request, transport: ReportTransport(result: .success(422)))
    let offline = await BugReportSender.send(request, transport: ReportTransport(result: .failure(URLError(.notConnectedToInternet))))
    XCTAssertTrue(ok)
    XCTAssertFalse(rejected)
    XCTAssertFalse(offline)
  }

  func testSentReportCarriesTheLogsTextInsteadOfAttaching() {
    var report = BugReport()
    report.whatHappened = "Crash"
    report.includesLogs = true
    let body = report.body(diagnostics: diagnostics, chat: nil, logs: "2026-11-01T20:39:38Z Enigma launched")
    XCTAssertTrue(body.contains("Logs: below"))
    XCTAssertTrue(body.hasSuffix("Logs\n2026-11-01T20:39:38Z Enigma launched"))
    XCTAssertTrue(report.body(diagnostics: diagnostics, chat: nil, logs: "").hasSuffix("Logs\nNo events yet"))
    report.includesLogs = false
    let without = report.body(diagnostics: diagnostics, chat: nil, logs: "SECRET-LOG")
    XCTAssertTrue(without.contains("Logs: not included"))
    XCTAssertFalse(without.contains("SECRET-LOG"), "Logs stay out unless asked for")
  }

  @MainActor
  func testFailedSendOffersEmailAndASentReportCantBeSentTwice() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "BugReportSend-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let viewModel = LocalChatViewModel(
      engine: LlamaCPPModelEngine(installationStore: LocalModelInstallationStore(modelsDirectory: root.appending(path: "models"))),
      sessionStore: ChatSessionStore(applicationSupportDirectory: root), nativeToolsEnabled: false)
    var draft = BugReport()
    draft.whatHappened = "The reply stopped."
    func host(_ status: Result<Int, URLError>) -> NSView {
      let view = NSHostingView(rootView: BugReportView(
        chat: viewModel, diagnostics: diagnostics, recipient: "bugs@example.com",
        endpoint: URL(string: "https://example.com/f/abc"), transport: ReportTransport(result: status), draft: draft,
        close: {})
        .environment(\.enigmaTestMarker, { AnyView(TestControlMarker(name: $0).allowsHitTesting(false)) })
        .enigmaTheme(.paper)
        .transaction { $0.disablesAnimations = true })
      let window = ReportTestWindow(contentRect: NSRect(origin: .zero, size: BugReportView.size),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = view
      window.orderFrontRegardless()
      addTeardownBlock { @MainActor in
        window.orderOut(nil)
        window.contentView = nil
      }
      return view
    }
    func marker(_ name: String, in view: NSView) -> TestControlMarker.Marker? {
      EnigmaMainWindowTests.Host.marker(name, in: view) as? TestControlMarker.Marker
    }

    let failing = host(.failure(URLError(.notConnectedToInternet)))
    XCTAssertNil(marker("Email Instead", in: failing), "Email is only the fallback")
    try await clickTestControl("Send Report", in: failing)
    try await waitForUI("the email fallback", in: failing) { marker("Email Instead", in: failing) != nil }
    XCTAssertEqual(marker("Send Report", in: failing)?.isEnabled, true, "A failed send can be tried again")

    let working = host(.success(200))
    try await clickTestControl("Send Report", in: working)
    try await waitForUI("the sent report", in: working) { marker("Send Report", in: working)?.isEnabled == false }
    XCTAssertNil(marker("Email Instead", in: working))
  }

  @MainActor
  func testOnlyMailGetsTheSharingService() {
    XCTAssertTrue(BugReportMailer.usesMailService(defaultMailApp: "com.apple.mail"))
    XCTAssertFalse(BugReportMailer.usesMailService(defaultMailApp: "com.google.Chrome"))
    XCTAssertFalse(BugReportMailer.usesMailService(defaultMailApp: nil))
  }

  func testFloatsOnlyWhereTheChatColumnLeavesTheCornerFree() {
    // The column is 680 pt at most, centred; it and the ghost button take 80 pt from the right edge.
    XCTAssertTrue(ReportBugButton.floatsClear(ofChatIn: 680 + 2 * 80))
    XCTAssertFalse(ReportBugButton.floatsClear(ofChatIn: 680 + 2 * 80 - 1))
    XCTAssertFalse(ReportBugButton.floatsClear(ofChatIn: 640))
  }

  func testNeedsWhatHappened() {
    var report = BugReport()
    XCTAssertFalse(report.canSend)
    report.whatHappened = "  \n"
    XCTAssertFalse(report.canSend)
    report.whatHappened = "The reply stopped."
    XCTAssertTrue(report.canSend)
  }

  func testBodyHasTheFormAndDiagnosticsButNoChatByDefault() {
    var report = BugReport()
    report.whatHappened = "The reply stopped."
    let body = report.body(diagnostics: diagnostics, chat: chat(), logs: "")
    XCTAssertTrue(body.contains("What happened\nThe reply stopped."))
    XCTAssertFalse(body.contains("Steps to reproduce"), "Optional fields left empty are left out")
    XCTAssertFalse(body.contains("Contact"))
    for line in ["Enigma: 0.13.1 (7)", "macOS: Version 26.1 (Build 25B78)", "Chip: Apple M3 Pro", "Memory: 36 GB",
                 "Last route: Cloud · OpenAI · GPT-5.5", "Local model: Qwen 3 8B", "Cloud model: gpt-5.5",
                 "Logs: not included", "Conversation: not included"] {
      XCTAssertTrue(body.contains(line), line)
    }
    XCTAssertFalse(body.contains("Why did it crash?"))
    XCTAssertFalse(body.contains("out of memory"))
  }

  func testBodyIncludesOptionalFieldsAndTheChosenChatsTextOnly() {
    var report = BugReport()
    report.whatHappened = "Crash"
    report.steps = "1. Ask\n2. Wait"
    report.contactEmail = " me@example.com "
    report.includesLogs = true
    report.includesConversation = true
    let body = report.body(diagnostics: diagnostics, chat: chat(), logs: "")
    XCTAssertTrue(body.contains("Steps to reproduce\n1. Ask\n2. Wait"))
    XCTAssertTrue(body.contains("Contact: me@example.com"))
    XCTAssertTrue(body.contains("Logs: below"))
    XCTAssertTrue(body.contains("Conversation (“Crash”, text only)\nYou: Why did it crash?\n\nEnigma: It ran out of memory."))
    XCTAssertFalse(body.contains("secret-plans"), "Attachment names stay out")
    XCTAssertFalse(body.contains("selected secret"), "Selected text stays out")
  }

  func testConversationOnWithoutAChatSendsNone() {
    var report = BugReport()
    report.whatHappened = "Crash"
    report.includesConversation = true
    XCTAssertTrue(report.body(diagnostics: diagnostics, chat: nil, logs: "").contains("Conversation: not included"))
  }

  func testMailtoEncodesEverything() throws {
    let url = try XCTUnwrap(BugReport.mailtoURL(recipient: "bugs@example.com", subject: "Enigma bug report",
                                                 body: "a & b = c?\nnext"))
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    XCTAssertEqual(components.scheme, "mailto")
    XCTAssertEqual(components.path, "bugs@example.com")
    XCTAssertEqual(components.queryItems?.first { $0.name == "subject" }?.value, "Enigma bug report")
    XCTAssertEqual(components.queryItems?.first { $0.name == "body" }?.value, "a & b = c?\nnext")
    XCTAssertEqual(components.queryItems?.count, 2, "An ampersand in the body can't start a new field")
  }

  @MainActor
  func testOffersSavedChatsOnlyAndDefaultsToTheOpenOne() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "BugReportChats-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let saved = chat()
    let store = ChatSessionStore(applicationSupportDirectory: root)
    try store.save([saved])
    let viewModel = LocalChatViewModel(
      engine: LlamaCPPModelEngine(installationStore: LocalModelInstallationStore(modelsDirectory: root.appending(path: "models"))),
      sessionStore: store, nativeToolsEnabled: false)
    viewModel.selectSession(id: saved.id)
    XCTAssertEqual(BugReport.defaultChatID(in: viewModel), saved.id)
    viewModel.playTourExchange(TourDemo(prompt: "Temporary question", script: TourScript(reply: "Hi", phases: [])),
                               onFinish: {})
    XCTAssertTrue(viewModel.isTemporaryChat)
    XCTAssertTrue(viewModel.sessions.contains { $0.id != saved.id && !$0.messages.isEmpty }, "The temporary chat has text")
    XCTAssertEqual(BugReport.chats(in: viewModel).map(\.id), [saved.id], "A temporary chat is never offered")
    XCTAssertNil(BugReport.defaultChatID(in: viewModel), "…nor chosen by default")
  }

  @MainActor
  func testRequestsLogTheirRouteButNeverTheirText() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "BugReportLog-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let log = EnigmaLog(directory: root.appending(path: "logs"), writesFile: true)
    let cloud = FailingCloud()
    let viewModel = LocalChatViewModel(
      engine: LlamaCPPModelEngine(installationStore: LocalModelInstallationStore(modelsDirectory: root.appending(path: "models"))),
      cloudProviders: CloudProviderRegistry(openAI: cloud, anthropic: cloud, chatGPT: cloud, gemini: cloud),
      sessionStore: ChatSessionStore(applicationSupportDirectory: root), nativeToolsEnabled: false, log: log)
    viewModel.submitCloud("PROMPT-MARKER", provider: .openAI, modelID: "gpt-test")
    for _ in 0..<300 where !viewModel.state.isFailure { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(viewModel.state.isFailure)
    XCTAssertEqual(viewModel.lastRouteName, "Cloud · OpenAI · gpt-test")
    let text = try log.files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
    XCTAssertTrue(text.contains("Request started: Cloud · OpenAI · gpt-test"), text)
    XCTAssertTrue(text.contains("A request failed"), text)
    XCTAssertFalse(text.contains("MARKER"), "No prompt, reply or failure text: \(text)")
  }

  @MainActor
  func testScreenshots() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "BugReport-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ChatSessionStore(applicationSupportDirectory: root)
    try store.save([chat()])
    let viewModel = LocalChatViewModel(
      engine: LlamaCPPModelEngine(installationStore: LocalModelInstallationStore(modelsDirectory: root.appending(path: "models"))),
      sessionStore: store, nativeToolsEnabled: false)
    try EnigmaSnapshot.save("bug-report", size: BugReportView.size) {
      BugReportView(chat: viewModel, diagnostics: diagnostics, recipient: "bugs@example.com",
                    endpoint: URL(string: "https://example.com/f/abc"), close: {})
    }
    let actions = EnigmaTopBar.SidebarActions(show: {}, openHelp: {}, openSettings: {}, newChat: {})
    try EnigmaSnapshot.save("report-bug-corner", size: CGSize(width: 480, height: EnigmaTopBar.height * 3)) {
      VStack(spacing: 0) {
        EnigmaTopBar(sidebarActions: actions, whatsNew: nil, reportBug: {})
        EnigmaTopBar(sidebarActions: nil, whatsNew: (label: "What's new", open: {}), reportBug: {})
        HStack(spacing: 4) {
          Spacer()
          Button {} label: { Image(systemName: "gearshape") }.enigmaIconButtonStyle()
          ReportBugButton(action: {}, isFloating: true, isHovered: true)
        }
        .padding(.horizontal, 12)
        .frame(height: EnigmaTopBar.height)
      }
    }
  }
}

private final class ReportTestWindow: NSPanel {
  override var canBecomeKey: Bool { true }
}

private struct ReportTransport: CloudNetworkTransport {
  let result: Result<Int, URLError>

  func data(for request: URLRequest) async throws -> CloudDataResponse {
    CloudDataResponse(data: Data(), statusCode: try result.get())
  }

  func stream(for request: URLRequest) -> AsyncThrowingStream<CloudNetworkEvent, Error> {
    AsyncThrowingStream { $0.finish() }
  }
}

final class EnigmaLogTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("EnigmaLogTests-\(UUID())")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  func testWritesTimestampedLinesToTheFile() throws {
    let log = EnigmaLog(directory: directory, writesFile: true)
    log.record("Enigma launched", date: Date(timeIntervalSince1970: 0))
    log.record("A request failed", error: NSError(domain: "NSURLErrorDomain", code: -1001))
    XCTAssertEqual(log.files, [log.fileURL])
    let text = try String(contentsOf: log.fileURL, encoding: .utf8)
    XCTAssertTrue(text.hasPrefix("1970-01-01T00:00:00Z Enigma launched\n"))
    XCTAssertTrue(text.contains(" A request failed (NSURLErrorDomain -1001)\n"))
  }

  func testRollsOverIntoOnePreviousFile() throws {
    let log = EnigmaLog(directory: directory, writesFile: true, maximumFileSize: 100)
    for index in 0..<10 { log.record("event \(index) padded to forty characters…") }
    let files = log.files
    XCTAssertEqual(files, [log.previousFileURL, log.fileURL])
    let current = try String(contentsOf: log.fileURL, encoding: .utf8)
    XCTAssertTrue(current.contains("event 9"))
    XCTAssertLessThanOrEqual(try Data(contentsOf: log.previousFileURL).count, 100 + 80)
    let all = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
    XCTAssertFalse(all.contains("event 0"), "Older events roll off")
  }

  func testTextKeepsTheNewestWholeLinesOfBothFiles() {
    let log = EnigmaLog(directory: directory, writesFile: true, maximumFileSize: 100)
    for index in 0..<6 { log.record("event \(index) padded to forty characters…", date: Date(timeIntervalSince1970: 0)) }
    let all = log.text()
    XCTAssertTrue(all.hasPrefix("1970-01-01T00:00:00Z event "), all)
    XCTAssertTrue(all.hasSuffix("event 5 padded to forty characters…\n"), "Previous file first, then the current one")
    let tail = log.text(limit: 90)
    XCTAssertLessThanOrEqual(tail.utf8.count, 90)
    XCTAssertTrue(tail.hasPrefix("1970-01-01T00:00:00Z event 5"), "Starts at a whole line: \(tail)")
    XCTAssertEqual(EnigmaLog(directory: directory.appending(path: "none"), writesFile: false).text(), "")
  }

  func testWritesNothingWhenFileLoggingIsOff() {
    let log = EnigmaLog(directory: directory, writesFile: false)
    log.record("Enigma launched")
    XCTAssertEqual(log.files, [])
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }
}

private struct FailingCloud: ChatProvider {
  struct Failure: LocalizedError { var errorDescription: String? { "FAILURE-MARKER" } }
  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { $0.yield(.token("REPLY-MARKER ")); $0.finish(throwing: Failure()) }
  }
}

private extension LocalChatViewModel.State {
  var isFailure: Bool { if case .failed = self { true } else { false } }
}

import SwiftUI

/// The bug report's description boxes: Return starts a new line, as in any text box.
@MainActor
final class EnigmaTextFieldMultilineTests: XCTestCase {
  private final class Box: ObservableObject { @Published var text = "" }
  private struct Host: View {
    @ObservedObject var box: Box
    var body: some View {
      EnigmaTextField("Steps", text: $box.text, accessibilityLabel: "Steps", minHeight: 36).frame(width: 300).padding(20)
    }
  }

  private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

  private func key(_ window: NSWindow, _ characters: String, code: UInt16) throws {
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)))
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
  }

  func testReturnInsertsANewLine() throws {
    let box = Box()
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.titled],
                          backing: .buffered, defer: false)
    defer { window.orderOut(nil) }
    let hosting = NSHostingView(rootView: Host(box: box).enigmaTheme(.paper))
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    hosting.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    let editor = try XCTUnwrap(views(hosting).first { $0 is NSTextView })
    XCTAssertTrue(window.makeFirstResponder(editor))
    try key(window, "a", code: 0)
    try key(window, "\r", code: 36)
    try key(window, "b", code: 11)
    XCTAssertEqual(box.text, "a\nb")
  }
}
