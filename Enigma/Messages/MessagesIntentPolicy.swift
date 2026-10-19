import Foundation

/// Recognizes a request to read or send Messages from the wording of a draft,
/// so the composer can infer `/messages` without a typed command.
///
/// Pass only the person's typed draft, with typed slash commands removed. Never
/// pass selection text, files, OCR, earlier messages, or tool results: those
/// must not be able to turn on Messages. Quoted, backticked, and code-block text
/// stays literal and never matches.
enum MessagesIntentPolicy {
  /// A read or send request aimed at Messages.
  static func isRequested(_ prompt: String) -> Bool {
    isRequested(normalized: WebSearchPolicy.questionText(prompt))
  }

  /// A looser cue that carries Messages into a follow-up after a request that
  /// used it: send, reply, text, message, tell her/him/them, "what about …" or
  /// "what else did …".
  static func isFollowUp(_ prompt: String) -> Bool {
    let text = WebSearchPolicy.questionText(prompt)
    return isRequested(normalized: text) || isFollowUpCue(normalized: text)
  }

  /// `isRequested` for text already normalized by `WebSearchPolicy.questionText`.
  static func isRequested(normalized text: String) -> Bool {
    // Every pattern below needs one of these words, so most drafts stop after one quick scan.
    guard !text.isEmpty, matches(messagingWord, text) else { return false }
    let asks = [readTexted, readQuestion, readFrom, readMine, readAny, readSaidIn, sendVerbFirst, sendVerb,
                sendAMessage, sendAMessageTo, replyToFirst, replyTo, tellOn].contains { matches($0, text) }
    return asks && (matches(namesMessages, text) || !matches(otherService, text))
  }

  /// Only the looser follow-up cue, for text already normalized by `WebSearchPolicy.questionText`.
  static func isFollowUpCue(normalized text: String) -> Bool {
    !text.isEmpty && matches(followUpCue, text)
  }

  private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
    pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
  }

  private static func expression(_ pattern: String) -> NSRegularExpression {
    // All patterns are fixed, tested source literals, never user-provided regexes.
    try! NSRegularExpression(pattern: pattern)
  }

  // The text is already lowercased with straight apostrophes.
  private static let noun = #"(?:text messages?|texts?|imessages?|messages?|sms)"#
  private static let pluralNoun = #"(?:text messages|texts|imessages|messages)"#
  /// A polite lead-in before an imperative.
  private static let lead = #"(?:(?:please|pls|can you|could you|would you|will you|go ahead and|just|quickly|and) )*"#
  /// An imperative at the start of the draft. Anchored separately so the regex scans quickly.
  private static let first = "^" + lead
  /// An imperative starting a new clause.
  private static let clause = #"(?:[.!?;:,] |\b(?:and|then|also|now) )"# + lead
  /// Words after a send verb that mean the recipient isn't another person.
  private static let notAPerson = #"(?!(?:me|myself|us|an?|the|this|that|these|those|it|its|some|your|yours|editor|editors|box|field|file|files|format|queue|queues|broker|bus|messages?|texts?)\b)"#

  /// A word that every read or send pattern contains.
  private static let messagingWord = expression(#"text|messag|sms|chat|repl|respond|write back"#)
  /// Another messaging service, so the request isn't about Messages.
  private static let otherService = expression(#"\b(?:e-?mails?|gmail|outlook|slack|whatsapp|telegram|discord|signal|teams|linkedin|instagram|facebook)\b"#)
  private static let namesMessages = expression(#"\b(?:imessages?|sms)\b"#)

  /// "who texted me", "check what my sister texted me last".
  private static let readTexted = expression(#"\b(?:texted|messaged|imessaged|sms'?ed) (?:me|us)\b"#)
  /// "what did Sam text me", "did Mom message me", "what didn't she text me back about".
  private static let readQuestion = expression(#"\b(?:what|who|when|why|did|didn't|has|hasn't|have|haven't|had)\b(?: [\w']+){1,3} (?:text|message|imessage) (?:me|us)\b"#)
  /// "check my messages from Alex", "any new texts from Jordan", "last text from Dad".
  private static let readFrom = expression(#"\b(?:my|any|new|unread|recent|latest|last)\b (?:(?:new|unread|recent|latest|last) )?\#(noun)\b (?:from|with)\b"#)
  /// "read my latest messages", "check my texts".
  private static let readMine = expression(#"\b(?:check|read|show|show me|open|see|summari[sz]e|catch me up on|go through|look at|look through|search)\b (?:all )?(?:of )?my (?:(?:new|unread|recent|latest|last) )*\#(pluralNoun)\b"#)
  /// "any new messages?", "got any texts".
  private static let readAny = expression(#"^(?:(?:do i have|have i got|got|are there) )?any (?:(?:new|unread|recent) )*\#(pluralNoun)\b"#)
  /// "what did Sam say in our chat", "what did Sam say on iMessage".
  private static let readSaidIn = expression(#"\b(?:what|did|has|have|who|when)\b.{0,40}\b(?:say|said|send|sent|write|wrote|ask|asked|reply|replied)\b.{0,20}\b(?:in our (?:group )?chat|in the group chat|(?:on|in|over|via) imessage|in messages|on messages|(?:by|over|via) text|in (?:a|her|his|their) text)\b"#)

  /// "text Alex that …", "message Sam …", "iMessage Alex …".
  private static let sendVerbFirst = expression(first + sendVerbBody)
  private static let sendVerb = expression(clause + sendVerbBody)
  private static let sendVerbBody = #"(?:text|message|imessage|sms) \#(notAPerson)[\w']+"#
  /// "send her a message saying …", "send Sam a text saying …".
  private static let sendAMessage = expression(#"\bsend (?!(?:me|myself|us|an?|the|it|this|that)\b)[\w']+(?: [\w']+)? an? (?:(?:quick|short|new) )?(?:text message|text|message|imessage|sms)\b"#)
  /// "send a text to Mom".
  private static let sendAMessageTo = expression(#"\bsend an? (?:(?:quick|short|new) )?(?:text message|text|imessage|sms) to \#(notAPerson)[\w']+"#)
  /// "reply to Mom with ok".
  private static let replyToFirst = expression(first + replyToBody)
  private static let replyTo = expression(clause + replyToBody)
  private static let replyToBody = #"(?:reply|respond|write back) to \#(notAPerson)(?!(?:my|his|her|their|our) (?:\w+ )?(?:email|post|comment|review|question|code|essay|letter)\b)[\w']+"#
  /// "tell Jordan on iMessage I'm here", "tell Sam by text …".
  private static let tellOn = expression(#"\b(?:tell|ask|let) (?!(?:me|us|myself)\b)[\w']+(?: [\w']+)? (?:know )?(?:on|by|over|via|in) (?:imessage|text|messages|sms)\b"#)

  private static let followUpCue = expression(#"\b(?:send|reply|respond|text|message|imessage)\b|\b(?:tell|ask) (?:her|him|them)\b|^what about\b|\bwhat else did\b"#)
}
