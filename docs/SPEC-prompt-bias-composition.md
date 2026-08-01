# Susurrus — Prompt Bias Composition

*Written 2026-07-31. Companion to [accuracy-pipeline.md](accuracy-pipeline.md) Layer 0.*

## Summary

Whisper's final decode is biased by a prompt of at most 48 tokens — roughly 14
terms. Those 14 slots are chosen by `VocabularyRanker` from four tiers, of which
tier 2 (proper nouns scraped from recent dictation history) currently fills most
of them.

Measured on 2026-07-31 across 14 live dictations: the prompt was saturated at
48/48 tokens with **14 of 61** candidate terms fitting, and only **3 of 34**
distinct terms across the day came from curated vocabulary. The rest were
scraped from history, including ordinary English words Whisper had title-cased
(`Document`, `Fast`, `Programmatic`, `Comparison`), near-duplicates (`Zips` and
`Zip`, `URIs` and `URI`), and transcription garbage (`Frontfile`,
`StarrocksMiddleT`, `Grity`).

Two defects cause this. Both are in the scraping step, not the ranking budget.

**Defect A — the layers contradict each other.** `ProperNoun.extractBiasTerms`
promotes any capitalised word not in the 721-word `CommonWords` list. When
Whisper title-cases an ordinary word, the approved transcript keeps the capital,
the scraper promotes it to a bias term, and the prompt then instructs Whisper to
expect that capital next time. Meanwhile `CasingProfile` — shipped 2026-07-29 —
flags the same word as wrongly capitalised and offers the user a chip to fix it.
Observed on 2026-07-31: `Document` held 9 of 14 prompt slots while
`CasingProfile` suggested `Document→document` at 08:56 the same day.

**Defect B — one-off terms are indistinguishable from recurring ones.** Tier 2
has no notion of how often a term appeared. A word said once in a single
dictation takes the same priority as a term used daily, and holds a slot until
it rolls out of the 10-item history window (about a day).

## Requirements

| ID | Requirement | Priority | Phase |
|---|---|---|---|
| B1 | A word the user's own prose writes in lowercase must not become a bias term | Must | 1 |
| B2 | The lowercase test must not demote genuine names that happen to be dictionary words (`Rajesh`, `Julia`, `Paul`) | Must | 1 |
| B3 | The test must use evidence from the user's own transcripts, not a fixed word list | Must | 1 |
| B4 | Terms repeated across recent dictations must outrank terms said once | Should | 2 |
| B5 | A term said once must still be reachable when budget allows — demoted, not banned | Should | 2 |
| B6 | Newly taught vocabulary must keep its tier-3 head start regardless of tier-2 changes | Must | 2 |
| B7 | Bias-term selection must stay deterministic for identical input | Must | 1, 2 |

## Phase 1 — Stop promoting words the user writes in lowercase

Addresses B1, B2, B3, B7. Fixes defect A.

### Behaviour

**Given** the user's approved history contains "we reviewed the document
yesterday" and "attach the document to the ticket"
**And** the current transcript contains mid-sentence "Document"
**When** bias terms are extracted from history
**Then** `Document` is not offered as a bias term.

**Given** the user's history contains "Rajesh opened the ticket" and never
writes "rajesh" in lowercase
**When** bias terms are extracted
**Then** `Rajesh` is still offered, even though `rajesh` appears in the system
dictionary.

**Given** a word that appears in no English dictionary (`Kalpesh`, `Starrocks`,
`Subha`)
**When** bias terms are extracted
**Then** it is offered regardless of its casing record — the dictionary gate is
checked first and short-circuits.

**Given** a word the user has never written in lowercase and never in uppercase
**When** bias terms are extracted
**Then** it is offered — absence of evidence is not evidence, and the cost of a
wrong call here is one prompt slot.

**Given** the same history and the same transcript
**When** extraction runs twice
**Then** the term list is identical in content and order.

### The rule

A candidate is rejected when **all four** hold:

0. It is not ALL-CAPS, **and**
1. Its lowercase form appears in the system English dictionary, **and**
2. The user has written it in lowercase mid-sentence at least once, **and**
3. At least 50% of its mid-sentence sightings are lowercase.

Condition 1 alone is not sufficient — the macOS `web2` dictionary contains given
names, and testing it alone wrongly rejected 11 of 20 real names from the live
corpus (`Rajesh`, `Erica`, `Julia`, `Elizabeth`, `Rachel`, `Jonathan`, `Paul`,
`John`, `Carter`, `Ricardo`, `Carina`). Conditions 2 and 3 are what separate
them: the user writes "document" in lowercase and has never written "julia" that
way.

Condition 0 was **added during implementation**, when a test written from the
verification table below failed. `web2` also contains `dom`, `stem`, `uri` and
`mrs`, so without the exemption a single lowercase prose sighting of "stem"
would knock the acronym `STEM` out of the prompt. The acronym and the noun are
not the same word, and casing evidence about one says nothing about the other.
This is the only condition not derived from measurement — it came from the tests.

The thresholds here are deliberately **looser** than `CasingProfile`'s
suggestion thresholds (≥3 lowercase sightings, ≥90% ratio). Those guard an edit
to the user's text, where a wrong call is unacceptable. This guards one prompt
slot, where a wrong call costs almost nothing. Reusing the strict thresholds was
measured and rejected: it caught only 2 of 23 known-bad words.

### Measured effect

Simulated over the 60 most recent dictations, 14 slots each, against the live
220-dictation corpus:

| | junk share of slots | curated vocabulary share |
|---|---|---|
| current | 25% | 23% |
| with phase 1 as shipped | **18%** | **26%** |

Terms removed: `Comparison`, `Delta`, `Document`, `Fast`, `Frontier`, `Measure`,
`Merge`, `Pipeline`, `Reaction`, `Reference`, `Request`, `Substance`, `Zip`,
`Zips`. Terms wrongly removed: **none measured** — zero of the 20 real names in
the corpus were affected.

The ALL-CAPS exemption costs about 3 points of junk reduction (15% without it,
18% with). It keeps `4QAS`, `JMX29`, `LXP29`, `POC` and `URI` in play —
acronym-shaped transcription garbage that condition 0 cannot distinguish from a
real acronym. Every one of those is a one-off, which is precisely what phase 2
removes; paying 3 points to avoid dropping `STEM` and `DOM` is the right trade.

`Frontier` is the one debatable removal: an ordinary word that is also part of a
tool name the user references. It is recoverable by adding it to curated
vocabulary, which is the correct place for an explicit statement that a word is
a name.

### Not caught by phase 1, and why that is acceptable

`Programmatic`, `Chain`, `Handle`, `Expert`, `Appreciate`, `Supplier`, `Prompt`,
`Save`, `Integers` survive, because the user has not yet written any of them in
lowercase mid-sentence. There is no evidence to act on. Each is caught
automatically the first time the user writes it lowercase — the rule
self-improves with use and needs no list maintenance.

## Phase 2 — Rank recent context by repetition

Addresses B4, B5, B6, B7. Fixes defect B. Depends on phase 1.

### Behaviour

**Given** `Kalpesh` appears in 6 of the last 30 dictations and `Grity` appears in
1
**When** bias terms are ranked
**Then** `Kalpesh` is ordered before `Grity`.

**Given** the prompt budget fits 14 terms and 40 candidates qualify
**When** the budget is packed
**Then** the 14 most-repeated are taken and the remainder are dropped for this
dictation only — no term is permanently excluded (B5).

**Given** a term added to vocabulary 2 minutes ago with zero uses
**When** terms are selected
**Then** it still receives its tier-3 grace slot ahead of the evergreen tier,
unchanged by this phase (B6).

**Given** two candidates with equal repetition counts
**When** they are ranked
**Then** first-appearance order breaks the tie, so packing is reproducible (B7).

### Change

Widen the history window from 10 items to 30, and order tier-2 candidates by the
number of distinct dictations containing them, descending.

The window widening is what makes repetition measurable — across only 10 items
almost every term has a count of 1, and ranking changes nothing (measured: 25%
junk before, 25% after).

### Measured effect

| | junk share | curated vocabulary share |
|---|---|---|
| current | 25% | 23% |
| phase 1 (shipped) | 18% | 26% |
| phase 1 + 2 | **11%** | **36%** |

Most of what phase 2 removes on top of phase 1 is the acronym-shaped garbage
that condition 0 deliberately spares — `4QAS`, `JMX29`, `LXP29`. They never
recur, so repetition ranking drops them without needing to judge whether they
are real acronyms.

### Accepted risk

Repetition ranking demotes one-off proper nouns. In simulation, 17 plausible
real names said in exactly one recent dictation lost their slot: `Elizabeth`,
`Erica`, `Hanad`, `John`, `Jonathan`, `Julia`, `Paul`, `Rachel`, `Rajesh`,
`Ricardo`, `Airbnb`, `Architect`, `Carter`, `DevSmall`, `Haiku`, `TimingApp`,
`UltraCode`.

This is the phase's real cost and is why it is separated from phase 1. The
mitigation already exists: any name that matters gets corrected once, which adds
it to vocabulary, which gives it a tier-3 grace slot for 14 days. Tier 2 becomes
"what you keep talking about"; tier 3 remains "what you just taught me". A name
said once and never corrected is the only case that loses, and for that case
biasing was speculative anyway.

**Ship phase 1 first and measure before committing to phase 2.** Phase 1 has no
measured downside; phase 2 trades recall for precision and the trade should be
observed on live data rather than assumed.

## Constraints

- No new dependencies. The system dictionary at `/usr/share/dict/words` ships
  with macOS; load it once and cache.
- Bias terms are composed when a dictation *starts*
  (`SusurrusApp.startStreamingSession` → `setVocabularySelector`), not at stop.
  Nothing here may add perceptible latency to that path. Measured on the live
  200-item history: dictionary load **210ms**, casing-profile build **8.9ms**,
  extraction **1.5ms**. The 210ms is a one-time cost that would otherwise land
  on the first dictation after launch, so it is warmed in the background
  alongside the model preload; the two per-dictation costs are acceptable.
- A missing or unreadable dictionary must degrade to current behaviour, never to
  an empty term list.
- `CasingProfile`'s suggestion thresholds must not change. Phase 1 adds a second,
  looser query against the same evidence; it does not retune the existing one.
- Bias-term output must remain deterministic (B7) — the existing tier-1 tiebreak
  comment in `VocabularyRanker` explains why: Swift's sort is not stable.

## Not in scope

- **Raising the 48-token prompt budget.** Untested against decode latency and
  accuracy, and it treats the symptom. Composition is the cheaper lever: phase
  1+2 raises curated-vocabulary share from 23% to 36% within the existing budget.
- **Deduplicating near-identical terms** (`Zips`/`Zip`, `URIs`/`URI`). Real, but
  it needs a stemmer or a fuzzy-merge rule with its own false-positive profile.
  Phase 1 removes both `Zip` and `Zips` incidentally; revisit if the pattern
  survives.
- **Filtering transcription garbage** (`Frontfile`, `StarrocksMiddleT`,
  `Grity`, `4QAS`). Phase 2's repetition ranking demotes these for free, since
  garbage does not recur. A dedicated filter would need to distinguish garbage
  from genuine unknown names — the same unsolved problem `CasingProfile`
  documents.
- **Changing what enters curated vocabulary.** The vocabulary store is clean —
  43 entries on 2026-07-31, all genuine proper nouns. The defect is entirely in
  the history scraper.

## Verification

| # | Check | Expected |
|---|---|---|
| 1 | `swift build` | clean |
| 2 | `swift test` | 560 existing pass, plus new cases below |
| 3 | Unit: word in dictionary, written lowercase 3× in history | rejected as bias term |
| 4 | Unit: word in dictionary, never written lowercase (`Julia`) | accepted |
| 5 | Unit: word absent from dictionary (`Kalpesh`) | accepted, dictionary gate short-circuits |
| 6 | Unit: word with no casing record at all | accepted |
| 7 | Unit: ALL-CAPS acronym with lowercase evidence against it (`STEM`) | accepted — condition 0 exempts it |
| 8 | Unit: extraction run twice on identical input | byte-identical output |
| 9 | Unit (phase 2): term in 6 of 30 items vs term in 1 | 6-item term ordered first |
| 10 | Unit (phase 2): equal counts | first-appearance order decides |
| 11 | Unit (phase 2): newly added vocabulary entry | still receives tier-3 grace slot |
| 12 | Live: dictate, read `stop: prompt N/48 tokens` in `~/susurrus_debug.log` | no ordinary lowercase-written word in the term list |
| 13 | Live: same session | no term simultaneously in the prompt list and in a `casing suggestions:` line |

Check 13 is the direct test that defect A is closed: the two layers must never
disagree about the same word in the same dictation.

## Appendix — how this was found

Investigation on 2026-07-30 and 2026-07-31, reading live data from
`~/susurrus_debug.log` and `com.susurrus.app.plist`.

### Measurement that started it

Residual word error rate (raw ASR → user-approved text) across 220 dictations,
2026-07-12 to 2026-07-31:

| period | dictations | words | WER | 95% CI |
|---|---|---|---|---|
| baseline 07-12→07-28 | 150 | 5,287 | 0.51% | [0.35, 0.74] |
| 07-29 (casing chips shipped) | 27 | 1,840 | 0.7% | |
| 07-30 (outlier) | 29 | 2,135 | 2.3% | |
| 07-31 | 14 | 861 | 0.70% | [0.32, 1.51] |
| 07-29 + 07-31, excluding 07-30 | 41 | 2,701 | 0.67% | [0.42, 1.05] |

No detectable change either way once the 07-30 outlier is excluded — the
intervals overlap. 07-30 was the corpus's hardest day: 8.0 proper nouns per 100
words and 55 first-ever-seen names, roughly double any other day, with the top 4
dictations accounting for 47% of the day's word-level edits.

**Resolving a 30% improvement against a 0.51% baseline needs roughly 17,000
words per arm — about 283 dictations.** There were 70 post-change. WER cannot
adjudicate these fixes for weeks, which is why phases 1 and 2 are justified from
prompt composition instead, which is directly observable.

A methodological note worth keeping: *edit rate* (percentage of dictations
touched) is the wrong metric for comparing these periods. It scales with
dictation length — a 200-word dictation has more chances to contain one error —
and median length moved from 36 to 62 words across the window. An earlier pass
of this analysis read that as a quality regression. It was a length artefact.

### Prompt composition on 2026-07-31

14 dictations, prompt saturated at 48/48 tokens every time, 14 of 61 candidate
terms fitting. Distinct terms holding slots, `v` marking curated vocabulary:

```
14/14    Starrocks        7/14    Java             4/14    Chain
12/14  v MarkLogic        7/14    Frontfile        4/14    Zip
 9/14    Zips             7/14    Airbnb           4/14    Handle
 9/14    Document         7/14  v Apatin           4/14    StarrocksMiddleT
 9/14    Fast             6/14    Roaring          4/14    URI
 9/14    Programmatic     6/14    Delta            3/14    Expert
 9/14    Comparison       6/14    Belgrade         3/14    TSVs
 8/14  v URIs             5/14    Bitmaps          3/14    EMR
 8/14    MRs              5/14    UltraCode        3/14    AWS
 8/14    GitLab           5/14    Docker           3/14    LLM
                                                   2/14    Grity
                                                   2/14    Appreciate
```

3 of 34 terms curated. `Document` at 9/14 alongside a `Document→document`
casing suggestion at 08:56 is defect A in a single day's data.

### Decay behaviour

One-off junk does eventually clear. `JMX29`, `4QAS`, `CalPesh`, `Substance`,
`Reaction`, `Supplier` all held slots on 07-30 and had aged out by 07-31 as the
10-item window rolled. The defect is that they hold slots for about a day
against a saturated budget, not that they persist forever.

### Rejected designs

**Require a term in ≥2 of the last 10 dictations.** Simulated: removes 75% of
all bias terms, including `Subha`, `Ashish`, `Jayendra`, `Jira`, `GitLab`,
`AWS`, `Erica`, `Julia`. Across 10 items almost everything has a count of 1, so
the threshold acts as a near-total ban. This was the original framing of phase 2
and the simulation killed it.

**Reject any candidate found in the system dictionary.** Catches 22 of 23 known
ordinary words but wrongly rejects 11 of 20 real names, because `web2` includes
given names. Sound signal, unusable alone — it became condition 1 of the phase 1
rule.

**Reuse `CasingProfile`'s existing thresholds** (≥3 lowercase sightings, ≥90%
lowercase). Catches only 2 of 23 known ordinary words. The thresholds are tuned
for a decision with a much higher cost of error and do not transfer.

**Define the rule inline at its call site.** The first implementation composed
the three conditions inside `TranscriptionHistoryManager.recentBiasTerms`. That
left the rule untestable without going through history persistence, and the unit
test written against it restated the predicate rather than exercising it — the
two then disagreed the moment condition 0 was added, and the test passed while
the shipped rule was wrong. The rule now lives in
`ProperNoun.ordinaryWordExclusion(profile:dictionary:)` with exactly one
definition that both the manager and the tests call.

### Grace tier: confirmed working

Not a defect — recorded because it is the one part of this pipeline with clean
production evidence, and phase 2 depends on it as the safety net for one-off
names.

| term | learned | first reached prompt |
|---|---|---|
| `Posthog` | 07-28 12:57 | 07-29 07:15 — the morning the grace tier shipped; never before |
| `PoC` | 07-30 08:06:16 | 07-30 08:10:04, next dictation |
| `checkIn`, `Readme` | 07-30 08:37:29 | 07-30 08:39:53, 2m24s later |
| `Apatin` | 07-31 09:40 | 07-31, held 7 of 14 prompts that day |

### Source references

- `Sources/SusurrusKit/Services/ProperNoun.swift:39` — `extractBiasTerms`, the
  scraper both phases modify
- `Sources/SusurrusKit/Services/TranscriptionHistoryManager.swift:82` —
  `recentBiasTerms(itemLimit: 10, termLimit: 20)`, the window phase 2 widens
- `Sources/SusurrusKit/Services/VocabularyRanker.swift:108` — tier 2, which adds
  every context term unconditionally ahead of tiers 3 and 4
- `Sources/SusurrusKit/Services/CasingProfile.swift:47` — the strict thresholds
  phase 1 must not disturb
- `Sources/SusurrusKit/Services/CommonWords.swift` — the 721-word list that is
  the current and insufficient defence
