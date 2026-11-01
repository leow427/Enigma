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

  @MainActor
  func testOnlyMailGetsTheSharingService() {
    XCTAssertTrue(BugReportMailer.usesMailService(defaultMailApp: "com.apple.mail"))
    XCTAssertFalse(BugReportMailer.usesMailService(defaultMailApp: "com.google.Chrome"))
    XCTAssertFalse(BugReportMailer.usesMailService(defaultMailApp: nil))
  }

  func testFloatsOnlyWhereTheChatColumnLeavesTheCornerFree() {
    // The column is 680 pt at most, centred; the button takes 46 pt from the right edge.
    XCTAssertTrue(ReportBugButton.floatsClear(ofChatIn: 680 + 2 * 46))
    XCTAssertFalse(ReportBugButton.floatsClear(ofChatIn: 680 + 2 * 46 - 1))
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
    let body = report.body(diagnostics: diagnostics, chat: chat())
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
    let body = report.body(diagnostics: diagnostics, chat: chat())
    XCTAssertTrue(body.contains("Steps to reproduce\n1. Ask\n2. Wait"))
    XCTAssertTrue(body.contains("Contact: me@example.com"))
    XCTAssertTrue(body.contains("Logs: attached"))
    XCTAssertTrue(body.contains("Conversation (“Crash”, text only)\nYou: Why did it crash?\n\nEnigma: It ran out of memory."))
    XCTAssertFalse(body.contains("secret-plans"), "Attachment names stay out")
    XCTAssertFalse(body.contains("selected secret"), "Selected text stays out")
  }

  func testConversationOnWithoutAChatSendsNone() {
    var report = BugReport()
    report.whatHappened = "Crash"
    report.includesConversation = true
    XCTAssertTrue(report.body(diagnostics: diagnostics, chat: nil).contains("Conversation: not included"))
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
      BugReportView(chat: viewModel, diagnostics: diagnostics, recipient: "bugs@example.com", close: {})
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
