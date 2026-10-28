import Foundation

/// A local freshness policy, independent of model routing and evidence capacity.
/// Pass the original current question, never an expanded/serialized context.
/// Quoted material, history, files and OCR do not get to opt into network access.
enum WebSearchPolicy {
  static func needsFreshInformation(_ prompt: String, now: Date = Date()) -> Bool {
    needsFreshInformation(normalized: questionText(prompt), now: now)
  }

  /// `needsFreshInformation` for text already normalized by `questionText`.
  /// The person's own communications never search, even when Messages isn't
  /// recognized: their contents must not become a web query. Past these rules,
  /// location questions search, and the bundled search model decides the rest.
  static func needsFreshInformation(normalized text: String, now: Date = Date(),
                                    models: IntentModels = .shared) -> Bool {
    guard !text.isEmpty, !matches(optOut, text), !isAboutOwnCommunications(text), !matches(thisChat, text) else {
      return false
    }
    if LocationIntent.needsLocation(normalized: text) { return true }
    return models.answer(.search, cleaned: text, now: now) == "yes"
  }

  static func questionText(_ prompt: String) -> String {
    IntentText.clean(ThinkCommand.message(prompt).content)
  }

  static func isOfflineOrTransformation(_ text: String) -> Bool {
    matches(optOut, text) || matches(transformation, text) || matches(localTask, text)
  }

  /// "the most recent messages from my dad", "what's new in my texts", "what did Jordan send me",
  /// "what did Mom say today". News about others ("the latest message from the White House")
  /// still searches, and so do drafts that can't tell, such as "what's the latest from Sam".
  /// Nouns that only ever mean personal messages (texts, voicemails, DMs) veto search with
  /// any first-person word anywhere: "who's been blowing up my phone with texts today".
  /// Ambiguous ones (messages, chats, calls, mail) need the person next to them.
  static func isAboutOwnCommunications(_ text: String) -> Bool {
    guard matches(communicationWord, text) else { return false }
    return (matches(personalTerm, text) && matches(firstPerson, text)) || matches(ownCommunications, text)
  }

  private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
    pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
  }

  private static func expression(_ pattern: String) -> NSRegularExpression {
    // All patterns are fixed, tested source literals, never user-provided regexes.
    try! NSRegularExpression(pattern: pattern)
  }

  /// Unused here since the search model took over; F29's `recency(_:now:)` reads it.
  private static let fourDigitWord = expression(#"\b[0-9]{4}\b"#)
  /// "Don't search" in any of its usual wordings. It runs before the model and before location.
  private static let optOut = expression(#"\b(?:(?:do not|don't|dont|never) (?:\w+ ){0,3}(?:search|browse|look up|use (?:the )?(?:web|internet))"#
    // "please don't google it", but not "stores that don't take google pay".
    + #"|(?:do not|don't|dont|never) (?:even |bother (?:to )?)?google(?: (?:it|this|that|anything|stuff|things|the answer))?(?=[.,;:!?]|$)"#
    + #"|(?:without|no) (?:\w+ ){0,2}(?:web|internet|browsing|search|searching|googling|look ?ups?)"#
    + #"|without (?:checking|looking|searching|browsing|going) (?:\w+ ){0,1}online"#
    // "please don't look anything up", "without looking it up": nothing but "even" or "bother" before "look".
    + #"|(?:do not|don't|dont|never|without|no need to) (?:even |bother (?:to )?)?look(?:ing)? (?:anything|it|this|that|things|stuff) up"#
    + #"|skip (?:the )?(?:web |internet |online )?(?:search|searching|googling|lookup)|(?:avoid|refrain from) (?:searching|googling|looking (?:\w+ )?up|(?:using )?the (?:web|internet))"#
    + #"|(?:stay|answer|respond|keep (?:this|it)) offline|(?:^|[.,;:!?] )offline (?:answers? )?(?:only|please)|(?:use|using|from) (?:only )?(?:your (?:own |existing )?knowledge|memory only)"#
    + #"|(?:answer|respond|reply|just|only) (?:\w+ ){0,2}from (?:your )?memory)\b"#)
  private static let transformation = expression(#"^(?:(?:please|can you|could you|help me) )?(?:translate|rewrite|rephrase|proofread|paraphrase|(?:write|draft|compose) (?:(?:a|an|me|a short|a new) )?(?:poem|story|email|message|letter|function|script|test)|invent|imagine|roleplay|pretend|debug|refactor|implement|fix (?:this|my|the) (?:code|function|test)|summari[sz]e (?:this|the following|the attached|my))\b"#)
  private static let localTask = expression(#"\b(?:current|latest|recent) (?:file|folder|directory|selection|function|variable|branch|commit|diff|log|chat|conversation|document|draft|code|buffer|working directory)\b"#)
  private static let personalTerm = expression(#"\b(?:texts|text messages?|imessages?|sms|voicemails?|dms|direct messages|missed calls?)\b"#)
  private static let firstPerson = expression(#"\b(?:my|me|i|i'm|im|our|us)\b"#)
  /// This chat, not anything to look up: "the first message I sent you".
  private static let thisChat = expression(#"\b(?:message|text|question|prompt)s? (?:i|we) (?:sent|asked|gave|wrote) you\b|\byou (?:sent|told|gave|wrote) (?:me|us)\b"#)
  /// A word every `ownCommunications` match contains.
  private static let communicationWord = expression(#"messag|text|mail|dm|chat|voicemail|call|inbox|sms|send|sent|did (?:i|we)|from|my |our |mom|dad|mum|phone|facetime"#)
  private static let ownCommunications: NSRegularExpression = {
    let term = #"(?:text messages?|messages?|texts?|imessages?|e-mails?|emails?|dms|direct messages?|chats?|group chats?|voicemails?|(?:missed|phone) calls?|inbox(?:es)?|sms)"#
    let relation = #"(?:dad|mom|mum|mother|father|parents|sister|brother|wife|husband|partner|girlfriend|boyfriend|son|daughter|kids|grandma|grandpa|grandmother|grandfather|nana|granny|aunt|uncle|cousin|friends?|best friend|roommate|boss|manager|coworkers?|colleagues?|landlord|family|ex)"#
    // The term sits next to the person: "my latest texts", "messages from my dad", "texts for me",
    // "what texts did I get", "what emails came in". Not "the earnings call for my stock".
    return expression(#"\b(?:my|our) (?:(?:new|unread|recent|latest|last|most|few|missed|old|own|family|work|group|text|direct|personal) ){0,3}\#(term)\b(?! (?:apps?|components?|tables?|endpoints?|apis?|views?|schemas?)\b)"#
      + #"|\b\#(term) (?:(?:from|to|with|for|between) )?(?:me|us)\b|\b\#(term) (?:from|with|by) (?:my|our) (?:\w+ )?\#(relation)\b"#
      + #"|\b\#(term) (?:did|have|has|had) (?:i|we)\b|\b\#(term) (?:\w+ )?(?:came|come|coming) in\b"#
      // "the news Sam texted me", "the link Alex DM'd us" (owner, 2026-10-27).
      + #"|\b(?:texted|messaged|imessaged|dm'?d|dmed) (?:me|us)\b"#
      // "what did Jordan send me", "did I get any texts", "what did Mom say today", "any news from my sister".
      + #"|\b(?:did|has|have|had)\b(?: [\w']+){1,3} (?:send|sent) (?:me|us)\b|\bdid (?:i|we) (?:get|miss|receive)\b|\b(?:did|has|have)\b(?: [\w']+){1,2} call(?:ed)? (?:me|us)\b|\bwho called (?:me|us)\b"#
      + #"|\b(?:what|did|has) (?:did )?(?:(?:my|our) \#(relation)|mom|dad|mum) (?:say|said|send|sent|text|texted|write|wrote|tell|told)\b|\bfrom (?:my|our) \#(relation)\b"#
      // A call with family or with me: "what did Grandpa say on the phone yesterday".
      + #"|\b\#(relation)\b.{0,40}\b(?:on|over) (?:the phone|a call|facetime)\b|\b(?:on|over) (?:the phone|a call|facetime) (?:with|to) (?:me|us|(?:(?:my|our) )?\#(relation))\b|\bwhen (?:(?:my|our) )?(?:\#(relation)|he|she|they) called\b"#)
  }()
}
