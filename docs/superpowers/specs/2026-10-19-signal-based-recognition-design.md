# Signal-based command recognition

Approved 2026-10-19. Follows [inferred commands](2026-10-19-inferred-commands-design.md):
the chips, `ComposerIntent.resolve`, settings and Messages safeguards stay as they
are. Only the recognizers behind `messages`, `think` and automatic search change.

## Problem

The recognizers match whole sentence shapes, so they're precise but miss most
natural wording. On 113 realistic phrasings run through the shipped matchers:

| Command | Recognized |
| --- | --- |
| Messages, reading | 14 of 32 |
| Messages, sending | 11 of 17 |
| Think | 7 of 24 |
| Tricky negatives | 0 false matches of 20 |

- "what are the most recent messages from my dad" misses because `readFrom`
  allows one adjective ("recent") but not "most recent".
- "take a while to think about your answer" misses because think needs "think"
  directly followed by "hard", "carefully" or similar, or "take your time" or
  "step by step".
- A missed Messages request can fall through to automatic search, so the draft
  ("… messages from my dad") becomes a Brave query. This is a privacy gap.

## Design

### 1. A phrasing corpus

A test holds about 300 English phrasings, each tagged `messages`, `think`,
`search` or `none`, and requires every one to resolve as tagged. It includes
the 113 probe phrasings below, the existing tests' examples, and hard
negatives. It is the yardstick for the rules: each miss found later becomes a
line in it.

### 2. Messages: signals instead of sentence shapes

A draft is a Messages request when it has all three, anywhere in the draft:

- **A messaging term:** message(s), text(s), texted, iMessage, SMS, group chat,
  "sent me", "got back to me", "answer(ed) my text", "my/our conversation with
  <person>", "my chat with <person>".
- **A person or ownership:** a name, "my <relation>" (dad, mom, sister, boss,
  wife …), a pronoun, "the group chat", or first-person ownership of the
  messages ("my texts", "my messages").
- **A read or send shape:** read covers questions (what, who, when, did, has,
  any, what's new) and verbs (check, read, show, see, pull up, look at, go
  through, catch me up on, summarize, find, get). Send covers text, message,
  iMessage, send, shoot, drop, reply, respond, and "let/tell <person> know …
  by/via/over text".

Kept as vetoes:

- Noun compounds: "text classification", "message passing", "error message".
- Other services: email, Slack, WhatsApp and the rest, unless iMessage or SMS is
  named.
- "send me …".
- How-to and general questions: "how do I text …", "best way to message …".
- References to this chat: "my last message", "your last message",
  "summarize our conversation", "this chat", "with you".
- Drafting: "write a message/text to …" and "write my dad a text saying …"
  stay ordinary writing requests, as before.

Deliberately not recognized: a question with no messaging term, such as "what
did Sam say about dinner" or "tell Sam I'm running late", unless the previous
turn used Messages and the follow-up cue applies.

### 3. Think: any effort cue

Think is recognized from any of:

- think, reason, consider, reflect, ponder or mull, followed within a few words by
  a depth or effort word: hard, harder, carefully, deeply, through, over, more,
  long, "before answering", "before you answer".
- Effort phrases: take your time / a while / a moment / as long as you need,
  don't rush, no rush, be thorough, thoroughly, step by step, double-check,
  serious or real thought, go deep, methodically, extended thinking.

Not recognized: "what do you think", "I think", "do you think", "think of a
name", "what are you thinking", "I'm thinking about buying …".

### 4. Search never fires on personal communications

Automatic search doesn't fire when the draft is about the person's own
communications: a communication term (messages, texts, emails, DMs, chats,
voicemails, calls, inbox) together with a first-person marker (my, our, me, us),
such as "what are the most recent messages from my dad", "what's new in my
texts", "what did Jordan send me yesterday" or "any new emails from my boss
today". This holds even when Messages isn't recognized. News about other people
still searches: "latest message from the White House on tariffs".

### Unchanged

- Precompiled `static let` patterns; `ComposerIntent.resolve` stays within the
  existing timing test (1,000 resolves under 5 s).
- Only the typed draft is read. Quoted, backticked and code text stays literal.
- Every existing positive and negative test keeps passing; none is removed or
  weakened.
- Edit and translate recognition aren't part of this change.

## Not doing

- **A trained on-device classifier (Create ML).** Handles paraphrases well and is
  fast, but its decisions can't be explained, it needs a training pipeline and a
  model file in the repo, and fixing one miss means retraining. The corpus would
  be its training data if the rules plateau.
- **Asking a model to route.** Adds about 0.5–1 s per message, can't drive
  chips while typing, Apple's on-device model needs Apple Intelligence, and a
  cloud model would receive the draft just to choose a command.

## Probe phrasings

Messages, reading: what are the most recent messages from my dad · what did my
dad text me · show me my texts from mom · did my sister message me today · any
messages from Sam? · what was Alex's last text · read me the last message from
Jordan · what has Sam been texting me about · summarize my conversation with
Alex · check if mom texted · has dad replied yet · catch me up on the group chat
· whats new in my texts · do i have any unread texts · who messaged me today ·
what was the last thing my wife sent me · pull up my chat with Alex · show my
recent imessages · what did Jordan send me yesterday · latest text from dad ·
read my messages from my boss · go through my messages with Sam and tell me what
we planned · what were my dad's last few messages · what's my mom been saying in
our texts · any texts from Jordan today? · can you look at my messages from Sam ·
see if Alex got back to me · did my brother answer my text · what did mom say in
her last message · get my latest messages · find the message where Sam sent the
address · when did I last text Alex

Messages, sending: text my dad that I'll be late · send a message to mom saying
happy birthday · send Alex a text saying I'm outside · reply to Jordan with
sounds good · message the group chat that I'm on my way · let mom know I landed
via text · shoot Sam a text that I'm here · can you send my wife a message
saying I'm on my way home · imessage Jordan the address · respond to my sister
and say yes · send a quick text to my boss that I'm sick today · drop Alex a
message saying thanks · text Sam happy birthday · message mom: running late ·
send dad a message · tell Sam over text that dinner is at 7

Messages, not: text classification with bert · how do I send a message in slack
· what is message passing in mpi · how do i reply to a recruiter · what are the
latest messages in the kafka topic · how to text a girl · what does the error
message mean · summarize this text · what are the most recent developments in
sms marketing · send me a list of data structures · tell me a joke · explain the
most recent text in the book · what's the best way to message a landlord · what
message does the ending of inception send · write my dad a text saying happy
fathers day

Think: i want you to tell me about some data structures, take a while to think
about your answer · think about this carefully · please think hard about this ·
take your time and explain recursion · really think it over before answering ·
give this some serious thought · think long and hard about the best approach ·
reason through this step by step · be thorough, what's the best way to learn
rust · don't rush, explain how tcp works · think deeply about free will · spend
some time thinking about this · use extended thinking · think it through ·
consider this carefully before answering · carefully reason about whether p
equals np · take a moment to think before you answer · think more about this ·
double check your answer before replying · work through this methodically ·
think harder · put some real thought into this · take as long as you need · go
deep on this: how does a hash map work

Think, not: what do you think about python · i think the answer is 4 · how do
people think · think of a name for my dog · what are you thinking · do you think
it will rain
