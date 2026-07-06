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
  immediately when the replacement is a known vocab term / proper noun.
- **Case-only fixes** at aligned positions ("databid" → "DataBid") promote
  straight to vocabulary with a guessed category (ALLCAPS → acronym).
- **Reversals** — an edit that turns a rule's replacement back into its
  match disables that rule.
- **Usage stats** — after each session, `VocabularyManager.recordUsage`
  bumps `useCount`/`lastUsedAt` for terms present in the final text,
  feeding Layer 0's ranking.

Rules are visible and editable in **Preferences → Corrections** (toggle,
delete, add manual find→replace rules).

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
