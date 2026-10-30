# CP0b: Second probe — the search sites from another network

Read [agent-workflow.md](agent-workflow.md), the spec (§2, §6.4, Delivery's
"Open questions for CP0b"), and [CP0's Hand-off](cp0-spike.md#hand-off) in
full.

## Goal

CP0 ran on one network on one afternoon. Mojeek answered with a captcha and
then 403s (and later blocked that network for a real browser too),
Startpage challenged every search, and DuckDuckGo challenged 5 of 20.
CP0b repeats the acceptance check from another network, settles
DuckDuckGo's region and header set, and checks Open-Meteo's geocoding, so
the owner can fix the site lineup before CP2 builds the ports. **No product
code comes out of this checkpoint.**

- Probes live in a scratch folder outside the repository. Swift scripts
  (as CP0 used, for URLSession) and `curl` for Open-Meteo.
- Only the Hand-off, any new sanitized fixtures and their README lines are
  committed.

## Starting point

- **The worktree** (outside `~/Documents`; `git worktree list` shows it) on
  `feat/f29-on-device-search`, at CP1 plus a local merge of an older `main`
  (`aac6d48`, not pushed). **First, merge `main` into the branch**
  (`git fetch origin && git merge origin/main`), the one merge this plan
  allows. It brings F32, F30 and these rewritten docs; the CP0 and CP1
  briefs on `main` already hold the branch's Hand-offs, so their conflicts,
  if any, resolve to `main`'s side. Push the branch after the merge.
- **CP0's probe,** described in its Hand-off (Q4, Verification): 20 rounds,
  5 s apart, 4 rotating queries, Safari's headers with the version read from
  the installed Safari. Its scripts aren't in the repository; write them
  again from that description.
- **The two header sets** from CP0's Q4(e):
  - **A, the probe's:** `User-Agent`, `Accept`, `Accept-Language`,
    `Sec-Fetch-Site: same-origin`, `Sec-Fetch-Mode`, `Sec-Fetch-Dest`,
    `Priority: u=0, i`, and `Origin` plus `Referer` on POSTs;
  - **B, CP2's planned `SafariHeaders.standard`:** the same without
    `Origin` or `Priority`, `Sec-Fetch-Site: none`, and `Referer` only to
    Startpage.

  The owner approved probing with these two sets when approving the spec
  (2026-10-29). Don't try any other header change to get past a block: that
  stays the owner's call, as CP0 said.
- **The network:** the owner runs the probe on a network other than CP0's
  (for example at home). The worker writes the probe and hands the owner
  the command; record which network type it was (home, office, mobile
  hotspot), never an address.

## Tasks

### Task 0b.1: Acceptance (Q1)

**Owner-run.** About 120 requests per site across both header sets.

- [ ] **Write the probe:** for each of DuckDuckGo, Mojeek and Startpage
  (Startpage's token request plus search counts as one), run CP0's 20
  rounds with header set A, wait 2 minutes, then 20 with set B. Same 4
  queries as CP0 ("how do vaccines work", and CP0's other three from its
  scratch notes or three of the same kind). Stop a site early after 3
  consecutive blocks with a set, and move on.
- [ ] **Record** per site and set: status codes, result counts, block
  markers (CP0's list), median latency.
- [ ] **Hand the owner the command** and wait for its output folder.

### Task 0b.2: DuckDuckGo's region (Q2)

**Owner-run,** in the same run: 4 extra DuckDuckGo requests.

- [ ] **Send** "best pizza" and "news today" twice each: with `l=us-en`
  (ddgs's form field) and with `kl=us-en`. Record the echoed
  `<input name="kl">` value and whether results differ (count of shared
  URLs among the top 10).

### Task 0b.3: Parsing Mojeek and Startpage (Q3)

Only if a site returned results pages in Task 0b.1.

- [ ] **Save** one results page and one no-results page per site
  (sanitized as CP0 did: tokens, session values, geo-IP points, per-request
  IDs), as `mojeek-results.html`, `mojeek-no-results.html`,
  `startpage-results.html`, `startpage-no-results.html`.
- [ ] **Parse** each with `XMLDocument(xmlString:options: [.documentTidyHTML])`
  after decoding, and ddgs's XPaths from spec §2. Record whether titles,
  links and bodies match the page as a browser shows it. If tidy breaks the
  XPaths (CP0 expected this for Startpage), say so: SwiftSoup or a libxml2
  wrapper would be a new dependency and an owner decision.

### Task 0b.4: Open-Meteo geocoding (Q4)

- [ ] **Run** spec §6.4's geocoding request 5 times each for "Paris",
  "Springfield", "Pariss" and "東京" with `language=en` and the Mac's
  language. Record the shape (name, admin fields, country, latitude,
  longitude, timezone), latency, and what comes back for each.
- [ ] **Save** `open-meteo-geocoding-paris.json` as a fixture.

### Task 0b.5: The owner's lineup

- [ ] **Write the Hand-off,** then ask the owner to decide, with your
  recommendation and the evidence:
  1. keep, drop or replace Mojeek (primary) and Startpage (backup);
  2. which header set CP2 sends;
  3. whether DuckDuckGo gets `kl`.

  If Mojeek and Startpage both drop, say what that leaves (DuckDuckGo and
  Wikipedia, one index, no backup) and whether the spec's agreement score
  and Startpage rule still make sense. Record the owner's answers in the
  Hand-off and the progress log; CP2 follows them.

## Exit criteria

- Every row of the findings table is filled in, and the owner's three
  decisions are recorded.
- New fixtures are sanitized, with README lines.
- `git status` shows only this brief, the plan's progress log, and the
  fixtures.

## Reviewer checklist

- **Fixtures:** no IP address, geo-IP point, session value, account or
  username. Diff each against its raw capture's structure.
- **Evidence:** each answer follows from the recorded output; the network
  is described by type only.
- **No header variation** beyond sets A and B.
- **Never rerun a live probe.** Reason from the recordings.

## Hand-off

*Filled in by the CP0b worker.*

| # | Question | Answer | Evidence | Decision for later checkpoints |
| --- | --- | --- | --- | --- |
| Q1 | Acceptance per site and header set, on another network | | | |
| Q2 | DuckDuckGo `kl` vs `l` | | | |
| Q3 | Mojeek and Startpage parsing | | | |
| Q4 | Open-Meteo geocoding | | | |
| Owner | Lineup, header set, `kl` | | | |

1. **Summary:**
2. **Files:**
3. **Decisions:**
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
