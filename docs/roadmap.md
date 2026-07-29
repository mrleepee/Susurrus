# Susurrus Roadmap

*Written 2026-07-06, after the accuracy pipeline landed (see
[accuracy-pipeline.md](accuracy-pipeline.md)).*

---

## Notebooks: removed (2026-07-28)

Notebooks required picking an "active" notebook before dictating — a mode
decision before you speak, in a tool whose whole point is not having to
think before you speak. The watch period this roadmap called for ran on
its own: 144 entries between 2026-04-06 and 2026-04-27, one more on
2026-07-07, then nothing. Three months of the feature being off.

Nothing of value was lost. Everything notebooks provided is covered
elsewhere: `TranscriptionHistoryManager.recentBiasTerms()` gives the same
ASR context boost with no setup (this was already the live path, since no
notebook was ever active); `TranscriptionHistoryItem` stores the raw/edited
pair on every dictation, not only when a notebook happened to be active;
and edits already reach the correction loop through the review panel and
History. The removal deleted ~930 lines of dedicated code plus a menu-bar
JSON parse that ran on every single menu open regardless of whether
notebooks were ever used.

The SPEC R31 idea (LLM auto-assigns each dictation to a notebook) would
have actually solved the context-switching problem, by removing the
manual pick — but it wasn't worth an LLM call per dictation for a feature
with four months of zero pull. Filing was never the job that needed
doing; corrections were, and the review panel already does that job.

---

## Top 5 long-term improvements

Ranked. Number 1 matters most.

### 1. Context without asking

Susurrus should know what you're talking about without being told.
Today it looks at your recent dictations. Next: look at **where you're
pasting**. Dictating into Xcode? Bias toward code words. Into Slack?
Names of your colleagues. The goal: delete every setup step between
"install app" and "it knows my words".

### 2. Effortless corrections

Right now, teaching Susurrus means opening History and editing text.
Too much work. Instead:

- A "fix that" button (or hotkey) right after a dictation pastes.
- Highlight the words Whisper itself wasn't sure about, so you can see
  at a glance what to check.
- After you fix the same mistake twice, ask once: *"Always replace
  'core bee' with 'CoRB'?"* — one click, learned forever.

Every fix you make today saves ten fixes later. Making fixes cheap is
the highest-leverage accuracy work left.

### 3. Cleanup AI on by default, fully private

An AI pass that fixes punctuation and phrasing is optional today because
it needs setup (an API key, or LM Studio running). Long term: ship or
auto-detect a small model that runs on the Mac itself, so polish is free,
private, and always on — with the existing safety check so it can never
rewrite what you actually said. Nothing leaves the Mac.

### 4. Dictate longer than 60 seconds

The recording cap exists because Whisper decodes 30-second windows and
long audio needs careful chunking. Solve that properly (decode in chunks
while you keep talking) and Susurrus becomes usable for meetings, memos,
and thinking out loud — not just short bursts.

### 5. Your words on every Mac

Vocabulary and learned rules should follow you via iCloud. Teach Susurrus
a name on your desktop, and your laptop knows it too. Without sync, every
machine starts from zero — and the learning loop is the product.

---

## Scheduled decision: do learned rules earn their keep?

**Review on 2026-08-26.**

Measured on 2026-07-27 across 200 dictations (2026-07-07 → 2026-07-27):

- **1 of 15** enabled learned rules had ever fired again after being
  learned, across roughly 2,000 rule × dictation opportunities.
- 6 of 15 were redundant with the fuzzy vocabulary layer.
- 2 actively corrupted ordinary English (`'your eyes' → 'URIs'`).
- Meanwhile vocabulary + prompt bias fixed `SciFinder` **at the source**:
  4 correct transcriptions, zero variants.

The cause is structural. Whisper does not repeat a mangling — "Abhishek"
came out as "Abishek" once and never that exact form again — so exact-match
rules are minted from noise. Prompt bias prevents the error; rules chase it.

**The decision:** if aggregate `fireCount` across all learned rules is
still under 5 on 2026-08-26, delete the learned-rule path and let
vocabulary plus prompt bias be the whole loop. Do not add a fourth round
of guards. Two rounds have already shipped (PR #24, and PRs #27–29), and
each one is maintenance tax on a mechanism with no demonstrated payout.

To check: Preferences → Corrections now shows fires per rule, or read
`correctionRules` from `~/Library/Preferences/com.susurrus.app.plist`.

**Interim re-measurement, 2026-07-29** (200 dictations, 45 rules). Aggregate
`fireCount` is still **0**. The guards shipped in PRs #27–29 are working as
designed: of 7 rules minted since 2026-07-27, 5 were suppressed and 2 enabled,
and every call was right — `'right' → 'write'` recurred two days later in
"the right-hand column", and `'they all' → 'they'll'` came from an
ungrammatical edit. Across the whole corpus only 5 triggers ever genuinely
recurred; 3 of those would have corrupted English, 1 was already handled by
vocabulary, 1 was a real missed fix. So suppression is net-positive, and
separately the rules layer has still delivered nothing. Nothing here changes
the 2026-08-26 decision — it points the same way. Full working in
[accuracy-pipeline.md](accuracy-pipeline.md).

## Not on the list, on purpose

- **Voice commands** ("new line", "send it") — different product. Revisit
  after the top 5.
- **Telling speakers apart** (meeting-style transcription) — Susurrus is
  for one voice: yours.
- **Cloud transcription** — never. Everything stays on your Mac; that's
  the point.
