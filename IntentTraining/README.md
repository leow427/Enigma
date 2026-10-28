# Intent examples

Labelled example drafts for F31's trained command-recognition models. One
folder per skill (`search`, `messages`, `think`, `selection`, `coding`,
`reasoning`), each with three files:

- `train.jsonl`: what the models learn from (`scripts/train-intent-models.sh`).
- `test.jsonl`: the held-out score set, written separately by an agent that
  never saw the training files or the rule code.
- `must-pass.jsonl`: cases that must always come out right: privacy cases,
  headline examples from the docs, and misses reported from now on.

**Format.** The first line is `{"asOf": "YYYY-MM-DD"}`: years in the text are
read relative to that date. Every other line is
`{"text": …, "label": …}`, with `"nearMiss": true` on negatives that look like
a request but aren't, and, in must-pass files, a `"why"`. Labels are `yes`/`no`,
or `edit`/`translate`/`none` for `selection`. No example may repeat across a
skill's files after cleanup, and none may contain a typed `/think`.

**Where the training examples came from** (2026-10-27):

- every phrasing that today's tests assert for these recognizers
  (`ComposerIntentPhrasingTests`, `ComposerIntentTests`, `WebSearchTests`,
  `AutoRouterTests`) and the examples in the "Recognized commands" table of
  `docs/Slash-Commands.md`, with the labels those tests assert;
- new hand-written wording: casual and misspelled drafts, near-misses, drafts
  that need two skills, and long drafts (neutral paragraphs with the request
  at the start or the end);
- variants of those: hand-written sentence patterns filled from short lists
  (cities, teams, names, tasks), and casual prefixes, suffixes and letter-swap
  typos added to some examples.

All wording is invented: no real contact details, numbers or addresses.
`baseline.json` holds today's rules' scores on the test sets; `floors.json`
the score floor of each skill that has switched to its model.
