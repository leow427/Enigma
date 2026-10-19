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
  /// When in doubt it doesn't match: a false match sends an ordinary question
  /// down the Messages path.
  ///
  /// A request combines three signals: a messaging term, tied to a person or to
  /// the person's own messages ("texts from my dad", "Mom texted me", "my texts"),
  /// in a read or send shape (a question, or a verb such as check, show or text).
  /// Noun compounds, other services, "send me …", how-to and advice questions,
  /// references to this chat, drafting and reviewing, and titles or quotes of
  /// books, songs and shows veto it.
  static func isRequested(normalized text: String) -> Bool {
    // Every signal below needs one of these words, so most drafts stop after one quick scan.
    guard !text.isEmpty, matches(messagingWord, text) else { return false }
    if matches(readPlain, text) { return true }
    let linked = links.contains { matches($0, text) }
      || (matches(subjectVerbWord, text) && subjectVerbs.contains { matches($0, text) })
    guard linked, matches(shape, text),
          !vetoes.contains(where: { matches($0, text) }) else { return false }
    return matches(namesMessages, text) || !matches(otherService, text)
  }

  /// Only the looser follow-up cue, for text already normalized by `WebSearchPolicy.questionText`.
  /// Everyday uses of "message" and "text" don't count, and neither does "send me …".
  static func isFollowUpCue(normalized text: String) -> Bool {
    !text.isEmpty && matches(followUpCue, text) && !matches(followUpNearMiss, text)
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
  /// Words that describe which messages: "my last few texts", "Sam's latest message", "my last 5 messages".
  private static let which = #"(?:most|new|unread|recent|latest|last|newest|few|previous|older|earlier|first|\d+)"#
  /// A polite lead-in before an imperative or question.
  private static let lead = #"(?:(?:please|pls|can you|could you|would you|will you|go ahead and|just|quickly|and|hey|ok|okay|so|now|i want you to|i need you to|i'd like you to),? )*"#
  /// The start of the draft or of a new clause.
  private static let clauseStart = #"(?:^|[.!?;:,] |\b(?:and|then|also|now) )"# + lead
  /// Who "my …" can be when it's a person: "my dad", "my best friend", "my boss".
  private static let relation = #"(?:(?:little|big|older|younger|baby|best|step|twin) )*(?:dad|daddy|mom|mommy|mum|mummy|mother|father|parents?|sister|brother|sis|bro|siblings?|wife|husband|partner|spouse|girlfriend|boyfriend|gf|bf|fianc[eé]e?|son|daughter|kids?|child|children|grandma|grandpa|grandmother|grandfather|granny|nana|aunt|uncle|cousin|niece|nephew|friends?|bestie|buddy|roommate|flatmate|housemate|boss|manager|coworkers?|co-workers?|colleagues?|landlord|landlady|neighbou?rs?|family|ex|in-laws?|mother-in-law|father-in-law|stepmom|stepdad|babysitter|nanny)\b"#
  /// "my dad", "our landlord".
  private static let relative = #"(?:my|our) \#(relation)"#
  /// Words that can't be a person's name: function words, and the nouns that make a
  /// compound with "text" or "message" ("text classification", "message passing").
  private static let notAName = #"(?!(?:me|myself|us|i|you|we|it|its|it's|an?|the|this|that|these|those|some|any|all|every|each|my|our|his|their|your|yours|not|no|is|isn't|are|was|were|be|been|being|do|does|did|doesn't|don't|didn't|has|have|had|can|could|will|won't|would|should|may|might|must|says?|said|means?|meant|reads?|shows?|looks?|keeps|stopped|written|typed|sent|send|say|write|use|put|include|get|give|share|post|read|on|in|for|with|without|vs|and|or|but|so|if|to|of|from|about|at|by|as|into|like|than|over|under|here|there|then|when|where|which|who|what|why|how|while|above|below|earlier|before|after|people|someone|somebody|anyone|anybody|everyone|everybody|nobody|one|editors?|box(?:es)?|fields?|files?|formats?|queues?|brokers?|bus(?:es)?|messages?|texts?|messaging|texting|classification|classifier|wrapping|alignment|generation|generator|passing|types?|boards?|gateways?|marketing|size|length|style|color|input|area|view|block|content|body|bodies|processing|mining|analysis|search|models?|history|limits?|templates?|ids?|handlers?|apis?|services?|providers?|apps?|settings|notifications?|backup|sync|encoding|parsing|parser|summarization|extraction|embeddings?|layout|rendering|selection|string|strings|frames?|protocols?|signing|delivery|sending|speech|etiquette|kafka|rabbitmq|sqs|topics?|servers?|clients?|sockets?|websockets?|stdin|stdout|console|mqtt|redis|logs?|users?|customers?|chatgpt|claude|ai|gpt|essays?|notes?|database|db|streams?|backend|frontend|consumers?|producers?|components?|endpoints?|tables?|channels?|bots?|pdfs?|clipboard|screenshots?|docs?|documents?|slides?|code|mailbox|inbox|firebase|props|schema|books?|chapters?|story|poems?|letters?|images?|phone|iphone|mac)\b)"#
  /// A name that isn't part of a noun phrase ("the server", "a good …").
  private static let name = #"(?<!\bthe )(?<!\ba )(?<!\ban )(?<!\bthis )(?<!\bthat )(?<!\byour )"# + notAName + #"[\w']+"#
  /// Someone messages go to or come from: "my dad", "the group chat", a pronoun, or a name.
  private static let person = #"(?:\#(relative)|the (?:family |work )?group(?: chat)?|her|him|them|\#(name))"#
  /// Someone who can send a message, as a subject.
  private static let sender = #"(?:\#(relative)|she|he|they|\#(name))"#
  private static let adverbs = #"(?: (?:has|have|had|just|already|ever|finally|not|never|been|still|actually))*"#

  /// A word that every signal contains.
  private static let messagingWord = expression(#"text|messag|sms|chat|conversation|convo|repl|respond|sen[dt] (?:me|us)|got back|gotten back|get back|answer|write back|wrote back|written back"#)
  /// Another messaging service, so the request isn't about Messages.
  private static let otherService = expression(#"\b(?:e-?mails?|gmail|outlook|slack|whatsapp|telegram|discord|signal|teams|linkedin|instagram|facebook)\b"#)
  private static let namesMessages = expression(#"\b(?:imessages?|sms)\b"#)

  /// "check messages", "read new texts", with nothing after that names something else.
  private static let readPlain = expression(#"^(?:(?:please|can you|could you) )?(?:check|read) (?:(?:new|unread|recent|latest) )*(?:text messages|texts|imessages|messages)(?: (?:from [\w']+|for me|today|now|please))?[?.!]*$"#)

  /// A messaging term tied to a person or to the person's own messages.
  private static let links = [
    // Cheapest first. "who texted me", "been texting me", "what did Sam text me".
    expression(#"\b(?:texted|messaged|imessaged|sms'?ed) (?:me|us|\#(person))\b|\b(?:texting|messaging) (?:me|us|her|him|them)\b|\b(?:did|didn't|does|has|hasn't|have|haven't|had|what|who|when|why|will|would)\b(?: [\w']+){1,3} (?:text|message|imessage) (?:me|us)\b"#),
    // "messages from my dad", "the last text I got from Sam", "texts between me and Alex",
    // "send a text to Mom". A message "to" someone counts only with a send verb, so
    // "my message to my boss" stays a writing request.
    expression(#"\b\#(noun) (?:(?:that )?(?:i|we) (?:got|received) )?(?:from|with) \#(person)\b|\b\#(noun) between (?:me|us) and \#(person)\b|\b(?:send|shoot|drop|fire off)\b.{0,30}?\b\#(noun) to \#(person)\b"#),
    expression(#"\b(?:my|our) (?:\#(which) )*\#(pluralNoun)\b|\b(?:my|our) (?:\#(which) )+\#(noun)\b"#),
    // "what did Mom say in her last message", but not "what did the president say in his".
    expression(#"\b(?:what|did) (?:did )?\#(person) (?:say|said|write|wrote|mean|ask|asked) in (?:her|his|their) (?:\#(which) )*\#(noun)\b"#),
    // "Alex's last text", "my dad's texts", "according to Mom's text".
    expression(#"(?<=\b\w{1,30})'s (?:\#(which) )+\#(noun)\b|\b\#(relative)'s (?:\#(which) )*\#(noun)\b|\baccording to (?:(?:my|our) )?[\w]+'s (?:\#(which) )*\#(noun)\b"#),
    // "text Mom that …", "when did I last text Alex".
    expression(clauseStart + #"(?:text|message|imessage|sms) \#(person)\b"#),
    expression(#"\b(?:i|we|you|she|he|they|to|please|last|ever|never|already|just) (?:text|message|imessage) \#(person)\b"#),
    // "did my wife text?", "has Sam messaged yet".
    expression(#"^(?:did|didn't|has|hasn't|have|haven't) \#(person) (?:text|message|imessage)(?: (?:me|us|back|yet|today|already))*[?.!]*$"#),
    // "my conversation with Alex", "catch me up on the group chat".
    expression(#"\b(?:my|our) (?:(?:\#(which)|whole|entire) )*(?:conversations?|convos?|chats?|threads?|history) with (?!(?:you|chatgpt|claude|gpt|ai|the ai|enigma)\b)\#(person)|\b(?:the|our|my) (?:[\w']+ )?group ?chats?\b"#),
    // "do I have any unread texts", "any new messages?", "how many unread messages do I have",
    // "what texts did I get today".
    expression(#"^(?:(?:do i have|have i got|did i get|got|are there|is there) )?any (?:(?:new|unread|recent) )*\#(pluralNoun)(?: (?:from|today|for me|yet|lately|since)\b|[?.!]*$)|^how many (?:(?:new|unread) )*\#(pluralNoun) (?:do|did|have) (?:i|we)\b|^(?:what|which) (?:(?:new|unread) )*\#(pluralNoun) (?:did|have) (?:i|we) (?:get|got|received|missed)\b"#),
    // "find the message where Sam sent the address".
    expression(#"\b\#(noun) (?:where|in which|when) \#(person) (?:sent|said|wrote|mentioned|asked|texted|shared)\b"#),
    // "what did Sam say in our chat", "what did Sam say on iMessage".
    expression(#"\b(?:what|did|has|have|who|when)\b.{0,40}\b(?:say|said|send|sent|write|wrote|ask|asked|reply|replied)\b.{0,20}\b(?:in our (?:group )?chat|in the group chat|(?:on|in|over|via) imessage|in messages|on messages|(?:by|over|via) text|in (?:a|her|his|their) text)\b"#),
    // "send Alex a text saying …", "shoot Sam a text", "drop Alex a message".
    expression(#"\b(?:send|shoot|drop|fire off|shoot off) \#(person) an? (?:(?:quick|short|new|little) )?(?:text message|text|message|imessage|sms)\b"#),
    // "reply to Mom with ok", "respond to my sister and say yes", "answer Sam's text with yes".
    expression(#"\b(?:(?:reply|respond|write back) to|answer) (?:(?:(?:my|our) )?[\w]+'s (?:\#(which) )*\#(noun)|(?!(?:reviewers?|comments?|threads?|posts?|issues?|tickets?|reviews?|questions?|emails?|prs?|bugs?|recruiters?)\b)\#(person))(?: (?:with|saying|that|and say|and tell)\b|[:,] )"#),
    // "tell Sam over text …", "let Mom know I landed via text".
    expression(#"\b(?:tell|let|ask|remind) \#(notAName)[\w']+(?: [\w']+)? (?:know )?(?:[\w']+ ){0,6}?(?:on|by|over|via|in|through) (?:a )?(?:imessage|text|texts|messages|sms|text message)\b"#),
  ]

  /// A word every `subjectVerbs` match contains, checked first because those patterns are slower.
  private static let subjectVerbWord = expression(#"texted|messaged|repl|respond|back|sent|send |answer"#)
  private static let subjectVerbs = [
    // "Mom texted", "Alex got back to me", "the last thing my wife sent me", "did my brother answer my text".
    // Not "Sam sent me this article, summarize it", which is about pasted content.
    expression(#"\b\#(sender)\#(adverbs) (?:texted|messaged|imessaged|got back to (?:me|us)|gotten back to (?:me|us)|get back to (?:me|us)|sent (?:me|us)(?! (?:this|these|that|those|a|an|the|some|my|his|her|their|over|in)\b|:)|answer(?:ed)? my (?:text|message|imessage)s?|been (?:texting|messaging))\b"#),
    // "what did Jordan send me yesterday", but not "who sang send me a text".
    expression(#"\b(?:did|didn't|has|hasn't|will|would) \#(sender) send (?:me|us)\b"#),
    // A reply counts only in a whole-draft question about it: "has Dad replied yet", not "the
    // reason he replied" or "did Microsoft respond to the allegations".
    expression(#"^"# + lead + #"(?:did|didn't|has|hasn't|have|haven't|what did|why hasn't|why didn't|check if|check whether|see if|find out if) \#(sender)(?: (?:has|have|had|just|already|ever|finally|not|never|still|actually))* (?:replied|responded|reply|respond|wrote back|written back|write back|texted back|messaged back)(?: (?:to (?:me|us)|to my (?:text|message|imessage)s?|back|yet|already|today))*[?.!]*$"#),
  ]

  /// A read or send shape: a question, a read or send verb, or "latest text from …".
  private static let shape = expression(#"^"# + lead + #"(?:what|what's|whats|what're|who|who's|whos|when|when's|did|didn't|has|hasn't|have|haven't|had|any|do i|have i|got|is there|are there|how many|how often|which)\b|"# + clauseStart + #"(?:check|read|show|see|pull up|open|look at|look through|look over|go through|go over|scan|catch me up on|summari[sz]e|find|get|search|list|tell me|give me|fetch|bring up|text|message|imessage|sms|send|shoot|drop|reply|respond|answer|write back|tell|let|ask|remind)\b|^(?:the )?(?:most recent|last|latest|newest|new|recent|unread)\b"#)

  private static let vetoes = [
    // Noun compounds: "text classification", "error message", "my messages table".
    expression(#"\b(?:error|commit|log|status|exit|warning|system|debug|console|validation|exception|alert|git|push|marketing|welcome|default|automated) (?:messages?|texts?)\b|\b(?:text|message|sms|imessage) (?:classification|classifier|wrapping|alignment|generation|passing|types?|boards?|brokers?|queues?|bus|editors?|fields?|formats?|gateways?|marketing|to speech)\b|\b(?:messages|texts|chats?) (?:apps?|tables?|components?|endpoints?|apis?|views?|schemas?|models?|queues?|props|controllers?|screens?|pages?|tabs?|features?|database|db|services?)\b"#),
    // Someone else's message: "the president's message to Congress", "the author's last text",
    // "messages from NASA to us about Artemis".
    expression(#"\b(?:his|her|its|their) (?:\#(which) )*\#(noun) to\b|\b(?:the|a|an|this|that) \w+'s (?:\#(which) )+\#(noun)\b|\bto us about\b|\bto (?:the public|the world|everyone|the nation|congress)\b"#),
    // "send me …", "text me a summary".
    expression(clauseStart + #"(?:send|text|message|imessage|sms|forward) (?:me|us)\b"#),
    // How-to, advice and general questions: "how do I text …", "should I text my ex", "text my ex or not?".
    expression(#"^"# + lead + #"(?:how (?:do|does|did|can|could|should|would|to|is|are)|why (?:do|does|would|is|are|can't|won't|isn't)|is it (?:ok|okay|rude|weird|normal|bad|good|polite|appropriate|possible))\b|\bhow (?:to|do i|do you|can i|should i|would i)\b|\bshould (?:i|we)\b|\bor not\b|\bwhat are my chances\b|\bif (?:i|we) (?:text|message|send|reply|respond|answer)\b|\bwhat should (?:i|we) (?:text|say|reply|write|send|respond|message)\b|\b(?:best|good|better|right|polite|nice|proper|appropriate|perfect|clever|funny|witty|cute|sweet|easiest|fastest) (?:way|ways|reply|replies|response|text|message|answer|thing) (?:to|for)\b"#),
    // This chat: "your last message", "what you sent me", "summarize our conversation".
    expression(#"\byour (?:[\w']+ )?(?:messages?|texts?|repl(?:y|ies)|answers?|responses?)\b|\byou (?:just )?(?:sent|wrote|said|replied|texted|messaged|gave)\b|\b(?:this|the current|our current) (?:chat|conversation|thread)\b|\bour (?:conversation|convo)\b(?! with)|\bwith you\b|\bmy (?:last|previous|earlier|first|latest|original|initial) (?:message|question|prompt|reply|request)\b(?! (?:to|from|with)\b)|\b(?:above|earlier in this)\b"#),
    // Drafting and reviewing: "write a message to my landlord", "check my grammar in my message",
    // "read my message to my boss and tell me if it's too harsh".
    expression(#"\b(?:write(?! back)|draft|compose|craft|rewrite|reword|rephrase|proofread|edit|improve|polish|translate|fix|correct|come up with|suggest|help me (?:word|reply|respond))\b.{0,40}?\b(?:texts?|messages?|repl(?:y|ies)|responses?|imessages?|sms)\b|\b(?:grammar|spelling|typos?|punctuation|tone|too (?:harsh|long|short|rude|formal|casual|blunt|pushy|aggressive|passive))\b"#),
    // Books, songs, shows and slang: "the song text me back", "who sang send me a text",
    // "in the episode where Ross texted Rachel", "what does text me mean".
    expression(#"\b(?:in|from|of) (?:the|this|that|an?|my) (?:book|chapter|novel|story|poem|essay|article|movie|film|song|script|episode|series|scene|speech|letter|slides?|presentation|document|pdf|notes|screenshot|image|lyrics)\b|\b(?:the|a) (?:book|song|movie|film|episode|show|album|novel|poem|series|website|meme) (?:called |titled )?(?:texts?|messages?|send|sent|imessage)\b|\bwho (?:sang|sings|wrote|directed)\b|\bwhat does (?:text|message|imessage|sms|texting|sent|send)\b"#),
  ]

  /// After a Messages request: send, reply or respond; text or message someone; tell her,
  /// him or them; "what about …"; "what else did …".
  private static let followUpCue = expression(#"\b(?:send|reply|respond)\b|\b(?:text|message|imessage) (?:her|him|them|back|it|[\w']+ (?:back|that|saying))\b|\b(?:tell|ask) (?:her|him|them)\b|^what about\b|\bwhat else did\b"#)
  /// Follow-ups that use "message" or "text" as a noun, or ask for something to be sent here.
  private static let followUpNearMiss = expression(#"\b(?:error|commit|log|status|exit|warning|system|debug) (?:messages?|texts?)\b|\bsend (?:me|us)\b|\b(?:text|message) (?:classification|wrapping|alignment|generation|passing|types?|boards?|brokers?|queues?|bus|editors?|fields?|formats?)\b"#)
}
