# Bug reports

Enigma can turn a short bug report into an email in your mail app. Nothing
leaves Enigma by itself: you read the email and send it from your mail app,
or don't.

## Where to find it

- **Help** (the sidebar's Help button): **Report a Bug…** at the bottom left.
- **Settings → About → Feedback**: **Report a Bug…**. Searching Settings for
  "bug" or "feedback" finds it.
- The **menu-bar menu**: **Report a Bug…**.

Each opens the form in its own window. Opening it again while it's open, or
minimized, brings the same window, with its draft, to the front.

## The form

- **What happened?** (required), **Steps to reproduce** and **Your email, if
  you'd like a reply** (both optional). In the first two, Return starts a new
  line.
- **Include logs**, off by default. Attaches Enigma's event log (below).
- **Include this conversation**, off by default, with the note "Never turn
  this on if the chat contains anything sensitive, such as passwords, personal
  or financial details, or private messages." directly under it. When it's on,
  a **Chat** menu picks which saved chat, the open one by default
  (`BugReport.chats(in:)` and `defaultChatID(in:)`). Only the
  chat's visible text is sent, as `You:` and `Enigma:` lines: no attachments,
  screenshots, file contents, selected text or Messages data, unless they're
  already in that text. Temporary chats are never saved, so they're never
  offered; with no saved chats the switch is off and disabled.
- **What will be sent** opens the email's whole text, with its address and
  subject, before you create it.
- **Create Email** opens it in your mail app. The form stays open, so the
  draft isn't lost if the mail app shows no email (for example while it's
  still being set up): it says to send the previewed text to the address in
  that case, and stops floating so the email and Finder can come in front of
  it. **Close** closes it.

Diagnostics are added automatically: Enigma's version, the macOS version, the
chip and memory, the route and model of the last request this launch, and the
local and cloud models chosen. They never include chat content.

## Delivery

When Mail is the default mail app, `BugReportMailer` uses
`NSSharingService(named: .composeEmail)`, which opens a new email with the
recipient, subject ("Enigma bug report"), body and any log files attached.
With any other default (such as a browser for web mail), or if Mail can't take
the email, it opens a `mailto:` link instead, so the email opens where the user
reads mail. A link can't carry attachments: Enigma then shows the log files in
Finder and says to drag them into the email. If nothing opens, the form says so and
gives the address.

The address is the `EnigmaBugReportEmail` key in `Enigma/Resources/Info.plist`
(`enigmabugreporting@gmail.com`), and nowhere else.

## The event log

`EnigmaLog` (`Enigma/App/EnigmaLog.swift`) records what Enigma did, never what
anyone wrote: launches with the version, each request's route and model
(`Request started: Cloud · OpenAI · …`, and `Request moved to: Local · …` when
a request changes route, such as an offline screen request answered on this
Mac), that a request failed (not why: a
failure's text can quote a provider), model install, delete or switch
failures, and the errors that used to go to `NSLog` (shortcut registration,
moving into Applications, the memory bandwidth test), as their error domain
and code only. Never chat text, model output, prompts, queries, URLs, file
paths or an error's description.

Each event goes to the unified log (subsystem Enigma's bundle id, category
`events`) and to `~/Library/Logs/Enigma/Enigma.log`. `OSLogStore` reads only
the current launch, so the file keeps earlier ones: past 256 KB it becomes
`Enigma.previous.log`, replacing the one before, so the two never pass about
512 KB. The test host writes no file.

## Tests

`BugReportTests` covers the recipient key, the required field, the email body
with and without each option (no chat text, attachment names or selected text
unless asked), `mailto:` encoding, that only Mail gets the sharing service, that a temporary chat is never offered or
chosen, and that a failed request logs its route but never its prompt, reply or
failure text;
`LocalInferenceTests.testRequestLogsTheModelItSettlesOn` checks a request that
settles its model on the way; `testScreenshots` renders the form when
`ENIGMA_SNAPSHOT_DIR` is set. `EnigmaLogTests` covers the file's lines,
rolling over and the no-file mode. `EnigmaTextFieldMultilineTests` checks that
Return inserts a new line in a multi-line field. `AppCommandTests` checks the menu-bar
command list.

## Limits

- A very long conversation can make a `mailto:` link longer than some mail
  apps accept. The sharing-service path, used with Mail, has no such limit.
- The form writes nothing to disk; the log file is the only thing Enigma
  writes for bug reports.
