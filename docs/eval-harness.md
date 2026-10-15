# Eval harness — reference

Offline accuracy testing for Susurrus. Background and rationale:
[transcription-quality-plan.md](transcription-quality-plan.md).

The harness runs the app's own stop-time code on recorded audio:
`StreamingTranscriptionService.transcribeOffline` (the same `finalDecode` the
app's stop path calls) then `TranscriptFinalizer.finalize` (corrector, the
same call the app makes), and scores both stages with `TranscriptScorer`.

## Commands

```
susurrus-eval synth    --scripts <scripts.jsonl> --out <corpusDir> [--voices "Daniel,Flo"] [--variants clean,paused,noisy]
susurrus-eval run      --corpus <corpusDir> --config <config.json> --out <run.json> [--limit N] [--tag T]
susurrus-eval compare  <baseline.json> <candidate.json> [--gate]
susurrus-eval snapshot --out <dir>
```

Make targets: `make eval-golden` (render the golden set), `make eval`
(run it with the production config), `make eval-baseline` (deliberately
replace the committed baseline), `make eval-compare A=… B=…`.

## Files

### Scripts — `scripts.jsonl` (input to `synth`)

One JSON object per line:

```json
{"id": "names-01", "text": "Ask Balvinder to move the MarkLogic job to dev-full.", "tags": ["names", "short"]}
{"id": "silence-room", "text": "", "tags": ["silence"], "silenceSeconds": 6}
```

- `id`: `[a-z0-9-]+`, unique.
- `text`: exactly what is spoken, and the reference transcript. Written as the
  user would want it typed: correct casing, punctuation and vocabulary
  spelling.
- `tags`: free-form; results are aggregated per tag. Conventional tags:
  `short` (< 30 s), `long` (> 30 s, exercises VAD chunking), `names`,
  `jargon`, `soundalike`, `numbers`, `pauses`, `silence`.
- `silenceSeconds`: only for `silence` entries (empty `text`). `synth` renders
  low-level room noise above the decoder's silence gate, as hallucination bait.
  The correct output is nothing.

### Corpus directory (output of `synth`, input to `run`)

```
<corpusDir>/manifest.jsonl
<corpusDir>/clips/<clipId>.wav       16 kHz mono PCM16
<corpusDir>/vocabulary.json          supplied by you (golden set: committed), not by synth
```

`manifest.jsonl`, one line per clip:

```json
{"id": "names-01.daniel.clean", "script": "names-01", "audio": "clips/names-01.daniel.clean.wav",
 "reference": "…", "tags": ["names", "short", "clean"], "source": "tts", "voice": "Daniel",
 "variant": "clean", "verified": true}
```

Clip ids are `<scriptId>.<voice lowercased>.<variant>`. The variant is
appended to `tags`. Variants:

- `clean`: read straight through.
- `paused`: `[[slnc 1500]]` after every second comma, and `[[slnc 1000]]`
  after each sentence end except the last. These mimic thinking pauses.
- `noisy`: clean render mixed with seeded white noise at 20 dB SNR.
- `silence` entries render once, with variant `silence` and voice `none`.

### Vocabulary snapshot — `vocabulary.json`

```json
{
  "snapshotDate": "2026-10-15T00:00:00Z",
  "entries": [ VocabularyEntry … ],
  "rules": [ CorrectionRule … ],
  "contextTerms": [ "…" ]
}
```

`entries` and `rules` use the models' own `Codable` encodings, with
ISO-8601 dates. `contextTerms` stands in for
`TranscriptionHistoryManager.recentBiasTerms()`. `snapshotDate` is passed as
`now:` to `VocabularyRanker.selectTerms`, so the grace tier is reproducible.
Scoring tracks every entry's display term (acronyms uppercased).

### Config — `config.json`

```json
{
  "name": "production",
  "model": "small",
  "decode": {"chunking": "vad", "concurrentWorkerCount": 4, "maxPromptTokens": 48},
  "prompt": "ranker",
  "preview": "decode",
  "corrector": true
}
```

- `model`: a short name resolved under
  `~/Library/Application Support/Susurrus/models/argmaxinc/whisperkit-coreml/`
  (`small` → `openai_whisper-small`; `distil-large-v3` →
  `distil-whisper_distil-large-v3`), or an absolute folder path.
- `decode`: a `FinalDecodeConfig`; missing keys take production defaults.
- `prompt`: `ranker` (production `VocabularyRanker` over the snapshot) or
  `none`.
- `preview`: `decode` computes a promptless decode of the clip as the stand-in
  for the live streaming preview the ranker reads. `none` passes an empty
  preview.
- `corrector`: run `TranscriptFinalizer` (Layer 1) on the raw ASR output.

### Run output — `run.json`

```json
{
  "name": "production", "createdAt": "…", "gitCommit": "4e23d85", "osVersion": "…",
  "modelFolder": "…", "config": { … }, "corpus": "…",
  "clips": [{
    "id": "…", "tags": [], "seconds": 12.3, "audioSHA256": "…",
    "previewText": "…", "previewMs": 0,
    "promptTerms": [], "promptTokenCount": 0, "outcome": "decoded", "decodeMs": 0,
    "raw": "…", "final": "…",
    "scoreRaw": TranscriptScore, "scoreFinal": TranscriptScore,
    "segments": [FinalSegment]
  }],
  "summary": {
    "overall": {"raw": Aggregate, "final": Aggregate},
    "byTag": {"long": {"raw": Aggregate, "final": Aggregate}}
  }
}
```

`Aggregate` = the summed `TranscriptScore` (rates computed from summed
counts) plus `clips`, `audioSeconds`, `decodeSeconds` and
`rtf = decodeSeconds / audioSeconds`. Decode time excludes the preview decode.

### Regression gate (`compare --gate`)

The gate exits non-zero when the candidate, compared with the baseline on
`final` scores:

- has overall WER more than 0.5 points worse;
- hits more than 1 fewer vocabulary term overall;
- has more dropped runs or inserted runs overall;
- produces any text on a `silence` clip.

It warns, without failing, when any clip's `audioSHA256` differs. That
usually means a macOS update changed a `say` voice, and the baseline needs
regenerating.

## Baseline — 2026-10-15

Production config (`small`, VAD chunking, ranker prompt, corrector on). 86
clips, 38 min of audio, Daniel and Flo voices, M2 Pro with the app running.

| Group | Clips | WER raw → final | Formatted err | Terms hit | Dropped / inserted runs | Extra breaks |
|---|---|---|---|---|---|---|
| overall | 86 | 6.4% → 6.4% | 8.9% | 230/324 | 1 / 2 | 88 |
| clean | 28 | 4.8% → 4.8% | 5.8% | 79/108 | 0 / 0 | 8 |
| paused | 28 | 5.3% → 5.3% | 10.2% | 79/108 | 1 / 0 | 59 |
| noisy | 28 | 9.1% → 9.1% | 10.8% | 72/108 | 0 / 2 | 21 |
| long | 24 | 5.8% → 5.7% | 8.7% | 143/204 | 0 / 0 | 79 |
| silence | 2 | no output | — | — | 0 / 0 | 0 |

Decoding ran at RTF 0.08 (about 5 s for a 60 s clip).

What it already shows:

- **The corrector is net zero, and on one script it does harm.** On every
  variant of `short-jargon-03`, fuzzy vocabulary matching rewrites the
  ordinary word "says" to "SAAS". On the Flo variants it also turns "CTS
  query" into "CTS XQuery". Both rewrites are the ones that repair your real
  dictations, so this is a precision/recall trade-off for experiment E6, not
  a one-line fix.
- **Most-missed terms:** XQuery (15 misses), Harnadh (12), QA (12),
  Divya (10), SciFinder (10), CoRB (8).
- **Dropped tail:** in `short-jargon-04.daniel.paused`, the final clause
  after the last pause is lost.
- **Hallucination:** in `short-jargon-04.flo.noisy`, noise produces two
  invented runs, and the distractor term `Cypher` turns up where "SciFinder"
  was said.
- **Sentence breaks:** 79 of the 88 extra breaks are in the long clips,
  which is the chunk-seam problem (experiment E2).
