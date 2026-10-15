# Transcription quality: review and plan

*2026-10-15. Status: phases 1 (harness MVP) and 2 (real-voice tiers C and D)
implemented — see [eval-harness.md](eval-harness.md) for usage. Phases 3–4 are
proposals.*

## Summary

- **Testing is the bottleneck.** Susurrus keeps no audio, so every change to
  decoding, prompting or correction can only be judged by you dictating again.
  Nothing can be A/B tested or re-run, and every regression shows up in daily use.
- **An offline harness works.** A spike today rendered 13 of your own approved
  dictations to speech, ran them through WhisperKit with the app's exact
  final-decode options, and scored the output. It runs unattended, in about a
  minute per configuration, and it reproduced failure modes you have been
  fixing by hand.
- **The spike already found three problems:**
  1. The bias prompt causes errors as well as fixing them. It lifts exact
     vocabulary terms from 32 to 43 of 53, but its comma list of capitalized
     names pushes Whisper into Title-Case list mode, where ordinary words come
     out as invented names.
  2. Long dictations are decoded in independent pieces. Whisper's window is
     30 s, and 42% of your dictations run longer. Each extra piece starts
     with no context, which produces spurious sentence starts and mishearings
     at the seams.
  3. The model labelled "Large v3 Turbo" in Preferences is not OpenAI's turbo
     model. It has 32 decoder layers and is the slowest model tested: six
     times `small`'s decode time for 0.2–0.6 WER points. distil-large-v3 is
     worse than `small`. WhisperKit's own default for M2+ Macs
     (`large-v3-v20240930`, 4 decoder layers) is neither installed nor offered.
- **Plan:** build the harness first (a committed golden set plus a private set
  made from your own voice), then work through six experiments in order of
  expected payoff, each decided by harness numbers rather than by feel.

---

## 1. What the data says

### Where the errors are (your edits, last 200 dictations)

67 of 200 dictations were edited before being used. Diffing raw ASR against
the approved text gives about 170 edit regions. Counts are approximate
because some regions mix categories.

| Category | ≈ Count | Examples (raw → yours) |
|---|---|---|
| Names and jargon | 85 | query→XQuery (×22), Harned→Harnadh (×3), Belvinder→Balvinder, Jane Derrick→Jayendra, DevFall/Dev4/DoFour→dev-full, XTMP→xdmp, says→SAAS |
| Sound-alike common words | 20 | route→root, dirty→thirty, renewed→removed, suggestion→ingestion, merch→merge, Leeds→leads |
| Punctuation / sentence breaks at pauses | 15 | ". Per"→"per", ". Alignment"→"alignment", ". Different"→"; different" |
| Invented text (hallucination) | 15 | ", if you're interested in getting a copy of this, feel free", "and R.I.P.", "a great way to do this. Thank you." |
| Wrong mid-sentence capitals | 10 | "XTMP, Apply, To Then Call", "Dynamically Applier Function", Cache→cache |
| Dropped words | 7 | "tell them first", "in that document", "damage to my business" |
| Your own rewording (not ASR) | 10 | "some kind of formal communication" → "a meeting and an MVP being defined" |

Names and jargon are half of everything. The categories that matter most
for trust are invented and dropped text. They are rarer, but they are the
errors you can't see without re-reading carefully.

### Structural findings from code and logs

1. **42% of dictations are longer than 30 s** (252 of 607 in the debug log;
   median 24.5 s, p90 86 s). For those, WhisperKit's VAD chunker splits the
   buffer at the longest silence in the second half of each 30 s window. The
   pieces are decoded **in parallel, independently**. Each starts with no
   previous-text context, and WhisperKit's sequential path has no
   previous-text conditioning either. The July latency model ("one fixed
   window decode regardless of length") only holds for the other 58%. Long
   dictations take 3–12 s at stop; the 96.8 s dictation on 2026-10-06 took
   12.1 s.
2. **The bias prompt is a near-static comma list.** Every recent stop packed
   the same 12–13 terms (`MarkLogic, CTS, XQuery, Datavid, IGI, Starrocks,
   TFIDF, Crossref, Claude, Frankendoc, Wrangler, It's, CAS`). The spike shows
   this format inducing list-style Title Case (see "Spike").
3. **Vocabulary data has junk in it.**
   - `It's` (54 uses) and `He's` were promoted into vocabulary by the learning
     loop. `It's` wins a prompt slot on almost every dictation.
   - `Starrocks` is stored with the casing you keep correcting to `StarRocks`,
     so the corrector re-imposes the wrong form.
   - `Tivat’s` sits beside `Tivat`.
   - `XQuery` has 27 uses and 29 repairs: Whisper almost never produces it
     itself, even with the term in the prompt every time.
4. **The model is multilingual `small`, with English pinned.** Larger and
   English-only models are on disk but have never been compared on accuracy.
   Only latency was measured, and the turbo comparison used the wrong model
   (finding 3 in the Summary).
5. **The existing audio tests have no ground truth.** `StopLatencyPerfTests`
   uses `test_clip_10s.wav`, which is gitignored, absent from worktrees, and
   has no reference transcript. Nothing in the suite measures accuracy.

---

## 2. Spike: does an offline harness work?

**Method.** I picked 13 approved dictations from history (8 short, 5 of
48–67 s). The approved text is the reference. Each was rendered with macOS
`say` (Daniel, en-GB, 16 kHz) in two variants: *clean*, read straight through,
and *paused*, with a 1.5 s silence at every second comma to mimic thinking
pauses. The audio was decoded by a 40-line runner that uses the app's
final-decode options exactly: `language: "en"`, `chunkingStrategy: .vad`,
`concurrentWorkerCount: 4`, and prompt tokens from `tokenizer.encode`
capped at 48. The prompt is the one the app used this morning. Scoring uses
normalized WER, exact case-sensitive vocabulary hits, runs of 3+
dropped/inserted words, and extra sentence breaks. M2 Pro; the app was
running in the background.

| Config | WER clean / paused | Vocab terms exact | Extra sentence breaks clean / paused | Decode time (RTF) |
|---|---|---|---|---|
| small, no prompt | 3.2% / 4.0% | 32/53 | 11 / 17 | 0.05 |
| **small, current prompt (production)** | 2.4% / 3.2% | 43/53 | 9 / 17 | 0.07 |
| large-v3 (installed as "large-v3_turbo"), current prompt | 2.2% / 2.6% | 42/53 | 8 / 20 | 0.42–0.47 |
| distil-large-v3, current prompt | 5.1% / 6.5% | 28/53 | 6 / 20 | 0.09 |

RTF (real-time factor) is decode time divided by audio length. 0.07 means a
30 s dictation decodes in about 2 s.

**Model results.** On this set, full large-v3 gains 0.2–0.6 WER points over
`small` at six times the decode time. distil-large-v3 is clearly worse than
`small`, mostly on names. Neither justifies a switch. The model that might,
OpenAI's 4-layer-decoder turbo, is untested (E1). TTS is easy audio, so the
gap between model sizes may be wider on your real voice; tiers C and D will
show that.

**The prompt causes errors as well as fixing them.** Same audio, same model:

- No prompt: "Those CTS functions. Like co-occurrence, have a skip, limit,
  truncate, read those parameters"
- Current prompt: "those CTS functions. Like Co-Occurrence, Havaskit, Limit,
  Tronkate, Read those parameters"

That passage sits at the start of a VAD chunk, with no prior text. All the
decoder has to go on is the prompt, a comma list of capitalized names, and it
continues in that style. This may be a large part of the "Whisper
Title-Cases noun phrases" problem that Layer 1.5 casing chips were built to
catch after the fact.

**Chunk seams show up in the long clips.** In h10, a new chunk at 22.7 s
starts "For example, we get…", where the speaker said "…at 1 million, for
example. We get…". The phrase is attached to the wrong sentence because the
chunk can't see the one before it.

**What the spike can't tell us.** TTS is cleaner and more regular than your
voice through the Studio Display mic, so absolute WER is optimistic. Your
real-use edit rate is a 1.5% *lower bound*, since it only counts errors you
chose to fix. TTS also pronounces "Frankendoc" or "Jayendra" its own way. A
synthetic set is good for *comparing configurations* and catching regressions.
Absolute accuracy has to come from recordings of you, which is why the
harness has both tiers.

---

## 3. The harness

### Goals

1. Any change to model, decoding, prompt, chunking or correction is scored in
   minutes, with no human in the loop.
2. It runs **the app's code**, not a copy. If the harness and the app can
   drift apart, the numbers mean nothing.
3. Metrics map to the failure classes above, not just WER.
4. Two sets: a small committed **golden set** that gates regressions, and a
   private **personal set** made from your own voice and words that never
   leaves the Mac.

### Corpus

```
<corpus>/manifest.jsonl     one line per clip:
  {"id", "audio": "clips/x.wav", "reference", "source": "tts|captured|read",
   "voice", "tags": ["long","pauses","names","silence"], "verified": true}
<corpus>/clips/*.wav        16 kHz mono PCM16
<corpus>/vocabulary.json    vocabulary + rules snapshot the clip set is scored against
```

Four sources, in the order they become available:

| Tier | Source | Effort for you | Where | Good for |
|---|---|---|---|---|
| A. Golden synthetic | 16 authored scripts covering your vocabulary and each failure class: names, sound-alikes, pauses, 60–90 s long-form, room-noise silence (hallucination bait). Rendered with 2 `say` voices × clean/paused/noisy. | none | `Tests/Fixtures/eval/golden/`: scripts, vocabulary and baseline committed; audio regenerated by `make eval-golden` (gitignored), with audio hashes in the baseline to detect voice drift | regression gate, reproducible |
| B. Personal synthetic | Your approved history texts rendered to speech, as in the spike | none | `~/Library/Application Support/Susurrus/eval/` | realistic vocabulary and sentence shapes, at scale |
| C. Captured dictations | Opt-in preference **"Keep recordings for accuracy testing"**. On Insert/Copy from the review panel, write the session buffer as WAV with a sidecar: raw ASR, corrected, approved text, prompt terms, model, duration. | a few minutes a week confirming references | `~/Library/Application Support/Susurrus/eval/captured/` | the real thing: your voice, mic, pace and pauses |
| D. Read-aloud session | `susurrus-eval record` shows 25 prompts and records you reading each one | one 10-minute sitting | same | exact references in your voice, available on day one |

**Tier C needs a review step,** because approved text is not always what you
said. Sometimes you reword, and sometimes you leave an error in. Clips start
`verified: false`. `susurrus-eval review` plays each one (`afplay`), shows the
approved text, and takes accept / edit / reject in one keystroke. Clips whose
approved text differs heavily from raw ASR are flagged as probable rewrites.
Unverified clips are reported separately, never mixed into headline numbers.

**Storage:** 32 KB/s as PCM16, so a typical 25 s dictation is about 0.8 MB.
Cap captured audio at around 500 clips (oldest dropped first), or store ALAC
(lossless, about half the size).

### Runner: `susurrus-eval` (new SPM executable target)

```
susurrus-eval run      --corpus <dir> --config <config.json> --out runs/<name>.json
susurrus-eval compare  runs/baseline.json runs/candidate.json   # per-clip diffs + regressions
susurrus-eval synth    --texts <file> --voices daniel,eddy,flo  # build a TTS tier
susurrus-eval review   --corpus <captured dir>                  # verify captured references
susurrus-eval record   --script <prompts.txt>                   # tier D
susurrus-eval snapshot                                          # export live vocab/rules to JSON
```

A **config** fixes every variable: model folder, chunking strategy, worker
count, prompt strategy (none / production ranker / prose template / fixed
string), decoding thresholds, corrector on or off, LLM on or off. The
vocabulary snapshot comes from the corpus, never from live UserDefaults, so
runs are reproducible and your live data is never written.

**Fidelity modes:**

- `--replay realtime` pushes audio through the real `AudioStreamTranscriber`
  at 1×, using `FakeAudioProcessor` promoted from Tests into SusurrusKit. The
  ranker then sees the same preview text the app would, which feeds prompt
  selection. It's slow (wall time = audio length), so it's for final
  confirmation.
- `--replay none` (default) skips the preview. The ranker gets a promptless
  decode of the clip as a stand-in for the preview. It runs about 15–50×
  faster than real time, which is good for sweeps.

### Code seams this needs

These refactors are worth doing anyway. The stop path is currently a
150-line closure inside `SusurrusApp`.

1. **`FinalTranscriber`** (SusurrusKit), extracted from
   `StreamingTranscriptionService`. It covers what happens at stop:
   prompt-token composition from preview text, whole-buffer decode and noise
   stripping. It takes `[Float]` and returns the text plus segments with
   their logprob/no-speech values. The streaming service and the harness
   both call it.
2. **`TranscriptFinalizer`** (SusurrusKit), extracted from
   `SusurrusApp.stopStreamingSession`. It covers corrector → optional LLM →
   guardrail → corrector re-pass, takes injected vocabulary and rules, and
   returns text plus changes. The app keeps only UI, clipboard and history.
3. **`TranscriptScorer`** (SusurrusKit, pure, unit-tested without a model):
   - normalization: case, punctuation, hyphens, numbers ("30" ≡ "thirty"),
     en-GB/en-US spelling
   - word alignment
   - the metric set below
4. **Audio capture hook** in the panel finalization path, behind the new
   preference (tier C).

### Metrics (per clip, aggregated by tag)

| Metric | Catches |
|---|---|
| WER (normalized) | overall accuracy |
| Formatted error rate (case- and punctuation-sensitive) | casing and punctuation, which you also fix |
| Vocabulary term recall: exact, case-sensitive, for terms in the reference | names and jargon, the biggest class |
| Vocabulary false fires: terms in the output but not in the reference | corrector or prompt over-reach |
| Dropped runs (≥3 consecutive deleted words) | lost speech |
| Inserted runs (≥3 consecutive inserted words) | hallucination |
| Extra sentence breaks | pause and chunk-seam punctuation |
| Stage attribution: raw → corrected → LLM, scored separately | which layer helped or hurt |
| Decode ms, RTF, stop-to-text ms | the latency budget |

### Regression gate

- `Tests/SusurrusTests/TranscriptionQualityTests.swift` runs tier A against a
  committed `baseline.json`. It is gated by `SUSURRUS_EVAL_TESTS=1`, because
  it needs a model on disk and about 2 minutes.
- It fails on: WER more than 0.5 points worse; term recall more than 1 term
  worse; any new dropped or inserted run; any output on the silence clips.
- `make eval` runs tiers A+B, `make eval-baseline` deliberately re-baselines,
  and `make eval-compare A=… B=…` diffs two runs.

---

## 4. Improvement experiments, in order

Each one is decided by harness numbers. "Ship if" is the rule written down
before running, so the result can't be argued with after the fact.

| # | Hypothesis | Change to test | Ship if | Cost |
|---|---|---|---|---|
| E1 | The large encoder helps (spike: modestly, on TTS), and only OpenAI's 4-layer turbo decoder makes it affordable | Add `openai_whisper-large-v3-v20240930` (OpenAI turbo, 4 decoder layers; WhisperKit's default for M2+). Compare against small, medium and large-v3 on tiers B–D. Relabel the 32-layer "turbo"; drop distil-large-v3 from the picker if real voice confirms the spike. | WER −25% relative and term recall up, with p50 stop latency for a 25 s clip ≤ 1.5 s | ~1.6 GB download |
| E2 | Independent parallel chunks cause seam errors on the 42% of long dictations | Our own chunker: split at real pauses ≤ 28 s, decode sequentially, condition each chunk on the previous chunk's last ~100 tokens plus vocabulary. Then go further: **finalize chunks while you're still talking**, so stop only decodes the last open chunk. | Extra sentence breaks and dropped/inserted runs on the long tag fall; stop latency on 60–120 s clips drops from 3–12 s to under 2 s | medium; the latency win pays for a bigger E1 model |
| E3 | The comma-list prompt induces Title Case and invented names | Try: none / current list / short prose ("Notes on MarkLogic and XQuery at Datavid…") / list capped at 6 terms / evidenced terms only | Keep the term-recall gain while the formatted error rate and false fires drop | small |
| E4 | Hallucinated tails can be detected | Drop segments with low avgLogprob plus high noSpeechProb, or text that matches a known outro phrase, at chunk ends. Re-score inserted runs. | Inserted runs → 0 on silence/pause clips with no WER cost elsewhere | small |
| E5 | Vocabulary hygiene | Remove `It's`, `He's`, `Tivat’s`; fix `Starrocks`→`StarRocks`; add a guard so contractions and possessives can never be promoted. Then look at why `XQuery` fails at the source (spoken "ex-query"? Try a prompt form like "XQuery (ex-query)", or a rule that only fires next to CTS/xdmp). | Term recall up; no false fires | tiny, but it edits your live vocabulary, so it needs your OK |
| E6 | Corrector and LLM layers, re-measured | Stage attribution across the personal set: does fuzzy vocab ever make things worse? Does LLM polish (local model) reduce formatted errors within the guardrail? | Keep any layer only if it is net-positive | small |

E1 and E2 interact. A bigger model is affordable only if long dictations stop
paying for the whole buffer at stop time, and E2's finalize-while-talking
is what makes that true. Their results should be read together.

---

## 5. Phases

| Phase | Delivers | Needs from you |
|---|---|---|
| 0. Quick fixes | E5 vocabulary hygiene and the contraction guard; Preferences model label fix | OK to edit live vocabulary |
| 1. Harness MVP | `TranscriptScorer` + tests; `FinalTranscriber` / `TranscriptFinalizer` extraction (app behaviour unchanged, existing tests green); `susurrus-eval run/compare/synth`; tier A golden set; tier B from your history; first baseline | nothing |
| 2. Real voice | tier C capture preference + `review`; tier D `record` | turn capture on; one 10-minute read-aloud |
| 3. Experiments | E1 → E3 → E4 → E2 → E6, each as its own PR with before/after harness tables | model download OK (E1); latency trade-off call after E1/E2 numbers |
| 4. Gate | `TranscriptionQualityTests` + `make eval*` targets; the harness becomes the definition of done for any accuracy PR | — |

E3 and E4 come before E2 because they are small and the harness will show
them clearly. E2 is the biggest engineering item and benefits from a
trustworthy baseline.

---

## 6. Risks

- **Synthetic speech flatters the model.** Mitigation: tiers C and D; read
  tier A/B results as relative only.
- **Captured references are noisy.** Mitigation: `verified` flag, review
  step, rewrite detection, separate reporting.
- **Privacy.** Captured audio and tier B texts are your conversations. They
  stay in Application Support, are never committed, are off by default, and
  can be deleted from Preferences.
- **ANE contention** with the running app skews latency numbers. Mitigation:
  quit Susurrus for latency runs, or report latency only from dedicated runs.
- **Overfitting the golden set.** Mitigation: tier A guards against
  regressions; improvement claims must hold on tiers B–D.
