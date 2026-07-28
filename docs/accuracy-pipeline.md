# Transcription Accuracy Pipeline — Reference

How Susurrus turns raw Whisper output into accurate text, and how it learns
from you. Layers are ordered by cost: the free deterministic work always
runs; the LLM is optional polish.

```
audio ──► streaming preview (no prompt tokens — latency)
      │      └── overlay shows corrected confirmed text live
      ──► final whole-buffer decode
      │      promptTokens = 48-token budget, relevance-ranked   (Layer 0)
      ──► deterministic corrector                                (Layer 1, always-on, ~0ms)
      ──► optional LLM polish, guarded                           (Layer 2, opt-in)
      │      └── corrector re-applied to LLM output
      ──► clipboard / notebook / history
user edits (History, Notebooks) ──► rules + vocab promotion + usage stats (Layer 3)
```

## Layer 0 — Relevance-ranked ASR bias

`VocabularyRanker` composes `DecodingOptions.promptTokens` **at stop time**,
not session start, using the streaming preview text:

1. **Evidenced terms** — vocab terms exact- or phonetically-present in the
   preview. A phonetic-but-wrong hit ("sparkle" when SPARQL is in vocab)
   ranks highest: that's precisely when biasing the final decode matters.
   Ties break by usage count, then alphabetically (reproducible packing).
2. **Context terms** — proper nouns from the active notebook's recent
   entries; falls back to recent dictation history when no notebook is
   active (`TranscriptionHistoryManager.recentBiasTerms`). Extraction is
   shared in `ProperNoun.extractBiasTerms` (CamelCase / ALLCAPS /
   capitalized-uncommon, sentence-initial words excluded).
3. **Evergreen fill** — remaining vocab by usage, then category priority.

Terms pack whole into the 48-token budget (`maxPromptTokens`); a term that
doesn't fit is skipped, never truncated mid-token. The streaming preview
decode stays prompt-free — prefill on every realtime pass is what made
uncapped vocab cost seconds.

## Layer 1 — Deterministic corrector (`TranscriptCorrector`)

Runs on every final transcript, and on the *confirmed* portion of the live
preview. Three passes:

1. **Learned rules** — exact n-gram (≤3 words) replacements from
   `CorrectionLearningManager.activeRules()`, longest-match-first,
   sentence-initial capitalization preserved.
2. **Vocabulary matching** — exact-normalized joins ("mark logic" →
   "MarkLogic", "sparql" → "SPARQL") and fuzzy hits ("sparkle" → "SPARQL",
   "susurus" → "Susurrus") via `isFuzzyMatch`: same phonetic key, length
   difference ≤ 2, Damerau-Levenshtein ratio ≤ 0.3, both sides ≥ 4 chars.
3. **Casing enforcement** — falls out of pass 2; acronym category forces
   uppercase.

False-positive guards: `CommonWords.top` (frequency list — never fuzzy-
rewrite a common English word) plus `CommonWords.domainStoplist` (explicit
fragments of multi-word vocab terms, e.g. "mark", "logic"). Multi-word
joins that normalize exactly to a vocab term bypass the guard by design.

That bypass is a **guarantee, not an incidental detail**: the `CommonWords`
check in `applyVocabulary` is gated on `isSingleWord`, which is what makes
"mark logic" → "MarkLogic" work with no rule involved. Layer 3 relies on
it to suppress redundant rules and to require corroboration for every
multi-word rule, so it is pinned by a corrector-level test.

## Layer 2 — LLM polish (optional)

`LLMService` providers: `local` (OpenAI-compatible — LM Studio :1234,
Ollama :11434), `cloud` (Anthropic-compatible), `auto` (local with a 2s
probe, then cloud). Default is `cloud` — legacy behaviour, no surprise
local-endpoint hang. Temperature 0 everywhere.

Context is filtered: only vocab entries evidenced in the transcript
(`llmContextString(relevantTo:)`), Jaccard-ranked few-shot correction
pairs, and notebook context.

**Guardrail**: `TranscriptGuardrail.accepts` rejects output whose word-LCS
similarity to the input is < 0.5 or whose length ratio leaves [0.5, 1.6] —
an LLM that rephrases, answers, or truncates loses to the Layer 1 text,
and the user gets a notification. Accepted output is run through the
corrector again so vocabulary casing survives.

## Layer 3 — Learning loop (`CorrectionLearningManager`)

Every edit in History or Notebooks calls `recordCorrection(raw:edited:)`:

- **LCS word alignment** of raw vs edited. Substitution regions (≤3 words
  per side) become `CorrectionRule`s — active after 2 sightings, or
  immediately when the replacement is a known vocab term / proper noun
  **and the match is a single word**.
- **Vocabulary first.** Before minting a rule, the learner asks
  `TranscriptCorrector.vocabularyAlreadyProduces` whether the vocabulary
  pass alone yields the same result; if so it promotes the term and skips
  the rule, which would add only exact-match false-positive risk. The
  check runs the real corrector rather than re-implementing `isFuzzyMatch`,
  so it honours the `CommonWords` guard (rules that *are* needed survive),
  best-match selection, and multi-word joins. Suppression is self-healing:
  delete the term and the next identical edit mints the rule again.
- **Multi-word corroboration.** A multi-word match never activates on one
  sighting, whatever the replacement. `'your eyes' → 'URIs'` reached
  production this way — `isRiskyCommonPhraseMatch` requires *every* word to
  be common, and ~700 `CommonWords` entries cannot cover the tail of
  ordinary English ("eyes", "paths"). Corroboration needs no word list.
- **Case-only fixes** at aligned positions ("databid" → "DataBid") promote
  straight to vocabulary with a guessed category (ALLCAPS → acronym).
- **Promotion guards** (from production data): the promoted form must pass
  `ProperNoun.looksLikeProperNoun` (sentence-position aware — pure case
  churn from restructuring, e.g. "Voice" → "voice", is not a term), and
  must not fuzzy-match an existing vocabulary entry (no "Sussurus" beside
  "Susurrus"). A rule whose match is entirely common English words mapped
  to a *different* word ("and while" → "Anwar") never fast-path activates
  off a known replacement — it needs the second sighting. Join/casing
  fixes ("mark logic" → "MarkLogic") no longer need a rule at all; Layer 1
  pass 2 delivers them. `runLearningQualityMigration()`
  (key `learningQualityMigration3`) repairs data written before these
  guards, once — retiring vocabulary-redundant and uncorroborated
  multi-word rules, restoring the canonical app name, dropping explicit
  junk terms, and deduplicating near-identical entries. Every rule sweep
  is restricted to `.learned`; manual rules are never touched.
- **Reversals** — an edit that turns a rule's replacement back into its
  match disables that rule.

### Telemetry — four counters, two distinctions

Effectiveness was unmeasurable until 2026-07-27, which is how a layer that
had fired once in ~2,000 opportunities survived two rounds of guards.

| Counter | Means | Bumped by |
|---|---|---|
| `CorrectionRule.hitCount` | times the **user made** this edit | `addRule` merge |
| `CorrectionRule.fireCount` | times the rule **repaired** a transcript | `recordFires`, once per dictation |
| `VocabularyEntry.useCount` | sessions where the term appeared at all | `recordUsage` |
| `VocabularyEntry.fixCount` | sessions where the corrector had to **repair** it | `recordFixes` |

`hitCount` was previously displayed as "N fixes", conflating the first two.
Read the pairs together: a rule with many edits and zero fires is being
taught repeatedly and never paying off, and **high `useCount` with zero
`fixCount` is the success signal** — Whisper getting a term right unaided
because Layer 0 biased it at the source.

`CorrectionChange` carries a `CorrectionOrigin` so credit lands on the
exact rule or entry. `TranscriptCorrector` records nothing itself and must
stay that way: it runs on the ~10 Hz streaming preview, so a self-counting
corrector would inflate every figure. The app layer commits fires from the
final pass only — never the preview, never the post-LLM re-correction.

Rules are visible and editable in **Preferences → Corrections** (toggle,
delete, add manual find→replace rules), showing edits taught and fires
delivered as separate labels.

## Concurrency

`VocabularyManager` and `CorrectionLearningManager` serialize all
load-modify-write on UserDefaults behind an `NSRecursiveLock`;
`NotebookManager` uses a barrier queue for its JSON files. Production code
must use the `.shared` singletons — separate instances on the same keys
would race despite the locks.

## Key files

| Piece | File |
|---|---|
| Corrector | `Sources/SusurrusKit/Services/TranscriptCorrector.swift` |
| Ranker | `Sources/SusurrusKit/Services/VocabularyRanker.swift` |
| Guardrail | `Sources/SusurrusKit/Services/TranscriptGuardrail.swift` |
| Learning | `Sources/SusurrusKit/Services/CorrectionLearningManager.swift` |
| Rules model | `Sources/SusurrusKit/Models/CorrectionRule.swift` |
| Word guards | `Sources/SusurrusKit/Services/CommonWords.swift` |
| Proper nouns | `Sources/SusurrusKit/Services/ProperNoun.swift` |
| LLM providers | `Sources/SusurrusKit/Services/LLMService.swift` |
| Stop-time tokens | `Sources/SusurrusKit/Services/StreamingTranscriptionService.swift` (`composeStopTimePromptTokens`) |
| Wiring | `Sources/Susurrus/SusurrusApp.swift` (`stopStreamingSession`) |
