# Slash commands

Recognized commands stay highlighted in `accentText` in the composer and work at the start, middle, or
end of a message. `/search` applies only to the current message and stays visible
until acceptance. Deleting it cancels explicit search; subsequent messages follow
the automatic-search preference in Settings → Cloud and search → Web search · Brave.
Automatic search defaults to on and requires a saved Brave key. Capture commands
run when you submit.
`/think` applies only to the current answer, including File Mode requests.

| Command | Action |
| --- | --- |
| `/search` | Search the web for this message only |
| `/screen` | Capture all displays |
| `/snapshot` | Select a screen region |
| `/think` | Request more careful reasoning |
| `/messages` | Read, search, and send Apple Messages for this message only |

Type `/` anywhere after whitespace, or click the composer's `/` button, to see
the commands and their descriptions.
`/search` is offered only with a saved Brave key, including in Help and the welcome
tour. Saving or removing a key updates suggestions immediately without editing
the draft. The automatic-search preference does not hide deliberate `/search`.
Suggestions filter by the text before the caret, case-insensitively. Use ↑/↓ to
select, Tab or Return to complete, or click a suggestion. Escape dismisses the
list before hiding the panel. Shift-Return inserts a newline. Completion edits
only the command at the caret and supports Undo.

The list is an opaque `menu` surface that floats over the composer without moving
its attachment, model, or send controls. It opens below the composer while it sits
high on the main page and above it once docked, and in the compact panel it opens
above the input near the bottom of the screen. Each command is set in monospace
`accentText` beside its description, with the chosen one on a `hover` fill. History
remains hidden at startup.

Commands must be separate tokens; punctuation may follow them. Quoted examples,
backtick code, URLs, paths, and unknown commands remain literal text. Repeated
commands activate once; `/snapshot` takes precedence over `/screen` if both occur.
Screen and Search remain incompatible with attached File Mode selections.
`/messages` cannot be combined with Screen, Search, or File Mode; see
[Messages](Messages.md).

Submitting `/screen` or `/snapshot` alone attaches an image and waits for your
question. Both the window and the compact panel show a thumbnail with
**Retake** and **Remove**. Retake repeats the capture type; Remove excludes the
image and extracted OCR from your next request. Cloud image consent previews
the capture and names its scope and selected provider. See
[Screen](Screen-Skill.md) for the saved permission and OCR distinction.

![Command suggestions under the composer](design/ui-revamp/screenshots/phase-6/composer-commands-paper.png)

The screenshot above is intentionally checked in as UI review documentation.
Build products and generated test renders remain outside the repository. The
rendering test also retains the screenshot as an XCTest attachment.

Verification uses `scripts/verify-xcode.sh build`, `test`, and `analyze`.
Regression coverage includes placement, boundaries, Unicode caret offsets,
completion, undo, keyboard navigation, multiline entry, capture cancellation,
focus restoration, and conversation scrolling.
