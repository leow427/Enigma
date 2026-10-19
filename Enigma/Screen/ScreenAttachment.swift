import AppKit

/// Full-resolution draft data. Neither originals nor sent-message previews enter chat storage.
@MainActor
struct ScreenAttachment: Identifiable {
  enum Source: String {
    case screenRegion, fullDesktop

    var label: String {
      self == .fullDesktop ? "Full desktop · All displays" : "Screen region"
    }
    var captureScope: String {
      self == .fullDesktop ? "the full desktop, including all displays" : "the selected region"
    }
  }
  enum Status: String { case captured = "Screenshot", reading = "Reading text…", localOCR = "Local OCR", vision = "Vision" }
  let id = UUID()
  let originalImage: NSImage
  let mimeType = "image/png"
  let pixelWidth: Int
  let pixelHeight: Int
  var ocrText = ""
  var ocrConfidence: Float = 0
  let source: Source
  var status = Status.captured
  var routingDecision: ScreenRoutingPolicy.Decision?
  let createdAt = Date()

  init(image: NSImage, source: Source = .screenRegion) throws {
    self.source = source
    guard let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          pixels.width > 0, pixels.height > 0 else { throw ScreenCaptureError.invalidImage }
    originalImage = image
    pixelWidth = pixels.width
    pixelHeight = pixels.height
  }

  /// A bounded Retina preview retained only for the current app session.
  func makeMessagePreview() -> Data? {
    guard let pixels = originalImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let scale = min(1, 240.0 / Double(pixels.width), 192.0 / Double(pixels.height))
    let width = max(1, Int((Double(pixels.width) * scale).rounded()))
    let height = max(1, Int((Double(pixels.height) * scale).rounded()))
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.interpolationQuality = .high
    context.draw(pixels, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let thumbnail = context.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: thumbnail).representation(using: .png, properties: [:])
  }
}

enum ScreenCommand {
  static func remainder(in prompt: String) -> String? {
    let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.lowercased().hasPrefix("/screen") else { return nil }
    let remainder = text.dropFirst(7)
    guard remainder.isEmpty || remainder.first?.isWhitespace == true else { return nil }
    return remainder.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// Resolve recognized commands anywhere in the draft, once, at submission.
struct ComposerCommands: Equatable {
  let prompt: String
  let screen: Bool
  let search: Bool
  let snapshot: Bool
  let think: Bool
  let edit: Bool
  let translate: Bool
  /// Applies to this message only, like search.
  let messages: Bool

  init(_ draft: String) {
    let commands = Set(SlashCommand.tokens(in: draft).map(\.command))
    prompt = SlashCommand.removing(Set(SlashCommand.allCases), from: draft)
    screen = commands.contains(.screen) || commands.contains(.snapshot)
    search = commands.contains(.search)
    snapshot = commands.contains(.snapshot)
    think = commands.contains(.think)
    translate = commands.contains(.translate)
    edit = commands.contains(.edit) && !translate
    messages = commands.contains(.messages)
  }

  var hasPrompt: Bool { !prompt.isEmpty || edit || translate }
  var submissionPrompt: String {
    (think ? "/think " : "") + (translate ? "/translate " : edit ? "/edit " : "") + prompt
  }
  var captureDraft: String { (snapshot ? "/snapshot" : "/screen") + (submissionPrompt.isEmpty ? "" : " " + submissionPrompt) }
}

enum ThinkCommand {
  static let guidance = "Think carefully before answering. Check assumptions, compare possible solutions, and verify the result. Return the answer with a concise explanation."

  static func remainder(in prompt: String, command: String = "/think") -> String? {
    let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.lowercased().hasPrefix(command) else { return nil }
    let rest = text.dropFirst(command.count)
    guard rest.isEmpty || rest.first?.isWhitespace == true else { return nil }
    return rest.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func message(_ prompt: String) -> ChatMessage {
    let enabled = SlashCommand.tokens(in: prompt).contains { $0.command == .think }
    var message = ChatMessage(role: .user, content: enabled ? SlashCommand.removing([.think], from: prompt) : prompt)
    message.extendedThinking = enabled ? true : nil
    return message
  }

  static func enabled(in messages: [ChatMessage]) -> Bool {
    messages.last(where: { $0.role == .user })?.extendedThinking == true
  }

  static func localOutputTokens(_ messages: [ChatMessage]) -> Int {
    enabled(in: messages) ? 2_048 : 512
  }
}

extension ThinkCommand {
  /// Whether the typed draft asks for careful reasoning ("think hard", "take your
  /// time", "step by step"), so the composer can infer `/think`. Pass the typed
  /// draft only; quoted and backticked text never matches. Opinions ("what do you
  /// think", "I think") and "think of a name" don't count.
  static func isRequested(by prompt: String) -> Bool {
    isRequested(normalized: WebSearchPolicy.questionText(prompt))
  }

  /// `isRequested(by:)` for text already normalized by `WebSearchPolicy.questionText`.
  static func isRequested(normalized text: String) -> Bool {
    // Every cue below contains one of these, so most drafts stop after one quick scan.
    guard matches(thinkWord, text), !matches(meaningQuestion, text) else { return false }
    return matches(thinkCue, text)
  }

  private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
    pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
  }

  // Fixed, tested source literals, never user-provided regexes. Each cue starts with its
  // literal word and checks what came before with a lookbehind, so long drafts stay fast.
  private static let thinkWord = try! NSRegularExpression(pattern:
    #"think|reason|consider|reflect|ponder|mull|careful|take|rush|thorough|step|check|thought|deep|method"#)
  /// "what does think it over mean".
  private static let meaningQuestion = try! NSRegularExpression(pattern: #"^what (?:does|do)(?: [\w'-]+){1,5} mean[?.!]*$"#)
  /// Thinking said by the person or about others ("I think", "do you think", "how to think").
  private static let notARequest = #"(?<!\b(?:i|i'm|im|i'll|i'd|you|you're|we|we're|they|they're|people|me|want to|need to|have to|going to|how to|how do i|how can i|how do you|how should i) (?:think|reason|consider|reflect|ponder))"#
  private static let thinkCue = try! NSRegularExpression(pattern: [
    // think or reason, then a depth word: "think it over", "think long and hard", "reason through this".
    #"\b(?:think|reason)\b"# + notARequest + #" (?:(?:really|very|long and|it|this|that|things|everything|this one|about (?:it|this|that)(?: one)?|some|a (?:bit|little)|much) )*(?:hard|harder|carefully|deeply|deeper|through|over|more(?! (?:\w+ly|like|as|of)\b)|thoroughly|critically|before (?:answering|replying|responding|you (?:answer|reply|respond)))\b"#,
    // "think about this carefully", "consider this carefully before answering".
    #"\b(?:think|reason|consider|reflect|ponder)\b"# + notARequest + #" (?:about |on |over )?(?:[\w']+ ){0,4}?(?:carefully|deeply|hard|thoroughly|before (?:answering|replying|responding|you (?:answer|reply|respond)))\b"#,
    #"\bmull (?:it|this|that) over\b|\bcarefully (?:think|reason|consider|reflect|analy[sz]e|work through|go through|check|review|weigh)\b"#,
    // Effort phrases. "take a while" only as a request: not "it'll take a while" or "take a minute and read this".
    #"\btake(?<!\b(?:it|it'll|will|would|does|did|can|could|should|might|may|usually|always|often|to|i|we|they|people) take) (?:a (?:while|moment|minute|second|beat)|some time|a little time|time)(?= (?:to (?:think|consider|reason|reflect|answer|respond|work|figure)|and (?:think|consider|reason|reflect|answer|respond|explain|work|figure|compare)|before|thinking)\b|[,.;:!]|$)"#,
    #"\btake your time\b|\btake (?:as long as|all the time) you need\b|\b(?:don't|do not|dont) rush\b|\bno rush\b|\bbe thorough\b"#,
    #"\b(?:explain|answer|check|review|analy[sz]e|research|consider|go through|work through|respond)\b.{0,30}\bthoroughly\b|\bthoroughly (?:explain|check|review|analy[sz]e|research|consider|think)\b"#,
    #"\bstep[- ]by[- ]step\b|\bdouble[- ]?check (?:your|the answer|the math|everything|this|it|that|before)\b"#,
    // "give this some serious thought", "put some real thought into this". Not "deep thought" or "some thought experiments".
    #"\b(?:give|put)\b(?: [\w']+){0,3} (?:serious|real|careful|deep|some|more|a lot of) thought\b(?! (?:experiments?|leadership)\b)|\b(?:serious|real|careful|deep|more) thought (?:into|to) (?:this|it|that)\b"#,
    #"\bgo (?:deep|deeper) (?:on|into)\b|\bmethodically\b|\bextended thinking\b|\bspend (?:some |a (?:little |bit of )?|more |a lot of )?time (?:thinking|reasoning)\b"#,
  ].joined(separator: "|"))
}
