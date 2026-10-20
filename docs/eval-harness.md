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
susurrus-eval run      --corpus <corpusDir> --config <config.json> --out <run.json> [--limit N] [--tag T] [--include-unverified]
susurrus-eval compare  <baseline.json> <candidate.json> [--gate]
susurrus-eval snapshot --out <dir>
susurrus-eval review   --corpus <corpusDir> [--no-play] [--threshold 0.15]
susurrus-eval record   --script <prompts.txt|scripts.jsonl> --out <corpusDir>
susurrus-eval segment  --audio <file> --out <corpusDir> [--reference-model large-v3] [--raw-model small] [--min 4] [--max 28] [--limit N]
susurrus-eval download --model <variant> [--list]
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

Optional fields, absent from older runs: `clips[].verified` (`false` only
on unverified clips, which appear in `unverifiedClips`); `unverifiedSkipped`
(count of unverified clips not scored, omitted with `--include-unverified`);
`unverifiedClips` (with `--include-unverified`, possibly empty);
`unverifiedSummary` (same shape as `summary`, present only when there are
unverified clips to score).

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

## Real-voice tiers

Tiers C and D use your own voice. Their audio and manifests stay on this Mac
and are never committed to the repo.

### Tier C — captured dictations

Opt-in: Preferences → Accuracy testing → "Keep recordings for accuracy
testing" (`keepRecordingsForEval`, off by default).

- **Trigger:** a review-panel dictation (Control+Option+Space) that you insert
  or copy. Other dictations are never kept. The clip is the whole streaming
  session buffer, 16 kHz mono.
- **Location:** `~/Library/Application Support/Susurrus/eval/captured/`, with
  `clips/<id>.wav` and `manifest.jsonl`. The app saves off the main thread. A
  failed save is written to `~/susurrus_debug.log`, not shown.
- **Ids:** `cap-<yyyyMMdd-HHmmss>-<4 hex>`. The time is local; `capturedAt`
  is UTC.
- **Manifest line** (the approved text is only a candidate reference until
  reviewed):

```json
{"audio": "clips/cap-20261015-201502-3fa1.wav", "capturedAt": "2026-10-15T19:15:02Z",
 "corrected": "Ask Balvinder to move the MarkLogic job to dev-full.", "id": "cap-20261015-201502-3fa1",
 "model": "openai_whisper-small", "promptTerms": ["Balvinder", "MarkLogic"],
 "raw": "Ask Balvinder to move the Markland job to dev-full.",
 "reference": "Ask Balvinder to move the MarkLogic job to dev-full.", "script": "cap-20261015-201502-3fa1",
 "seconds": 6.42, "source": "captured", "tags": ["captured", "short"], "variant": "captured",
 "verified": false, "voice": "user"}
```

  `raw`, `corrected`, `promptTerms`, `model`, `seconds` and `capturedAt` are
  the optional fields. `raw` is the stop-time ASR output, `corrected` the
  corrector's output.
- **Cap:** 500 clips. Over the cap, the oldest unverified clip is evicted
  first, and verified clips only once no unverified clip remains. Eviction
  deletes the WAV too.
- **Delete recordings** (Preferences) removes every clip, the manifest and
  the review verdicts after a confirmation. The panel shows the count, the
  size, and a Show in Finder button.

### Review — `susurrus-eval review`

Walks the unverified clips, oldest first. Each shows its id, length, model,
the approved text, the raw ASR and a diff (`[raw → approved]`). If the raw
and approved text differ by more than the threshold (normalized WER 0.15 by
default, `--threshold`), a "probable rewrite" warning appears: you may have
reworded the dictation rather than fixed a recognition error, so check the
approved text is what you said. Name fixes inflate it: "bell vinder
→ Balvinder" plus "mark logic → MarkLogic" in a 10-word dictation is 40%, so
expect the warning on jargon-heavy clips that are not rewrites.

| Key | Effect |
|---|---|
| `a` | accept: the approved text becomes the reference; verified |
| `e` | edit in `$VISUAL`, then `$EDITOR`, then `vi`; a saved edit becomes the reference and the clip is verified; an empty result cancels and the clip stays unverified |
| `r` | reject: removes the manifest line and the WAV |
| `s` | skip: stays unverified |
| `p` | play again |
| `q` | quit |

Each verdict is written at once under the corpus lock, so quitting loses
nothing and the app can keep capturing while a review is open. Keys are read
without Return. A pipe drives the same path, for example
`printf 'as' | susurrus-eval review --corpus <dir> --no-play`.

### Tier D — recorded prompts

`susurrus-eval record --script <prompts.txt|scripts.jsonl> --out <corpusDir>`

- **Prompts file:** one prompt per line. Blank lines, `#` comments and
  duplicates are skipped. Ids are `read-<8 hex>`, hashed from the text, so
  reordering is safe; editing a prompt makes it a new prompt.
- **`scripts.jsonl`:** the `synth` format. Ids and tags are kept and silence
  entries skipped, so the golden scripts can be read in your voice.
- **Clip ids:** `<scriptId>.user.read`. The manifest has `source: "read"`,
  `voice: "user"`, `variant: "read"` and `verified: true`, because the prompt
  text is the reference. Tags are the script's tags plus `read`, and
  `short` or `long` by length.
- **Keys:** Enter starts a take, Enter stops it. Then Enter keeps, `r` redoes,
  `p` plays back, `s` skips and `q` quits. A near-silent take gets a warning.
- **Resume:** rerun with the same script and output directory; prompts that
  already have a clip are skipped.
- **Vocabulary:** a `vocabulary.json` beside the script file is copied into
  the corpus if the corpus has none. Otherwise create one before `run`:
  `susurrus-eval snapshot --out <corpusDir>` writes `vocabulary.json` (the
  app's vocabulary, rules and recent-context terms, read-only) and
  `history-texts.jsonl`.
- **Microphone:** macOS attributes `record`'s microphone use to the terminal
  app. Grant it under System Settings → Privacy & Security → Microphone.
- **Testing the app's own capture (tier C):** use `make install` and
  `make launch`. The ad-hoc signed `make dev` binary gets a new code hash on
  every rebuild, and macOS revokes its microphone grant each time.

**Ready-made scripts:** `Tests/Fixtures/eval/golden/read-scripts.jsonl` has 25
scripts (16 short, 9 over 30 s, about 11 minutes of reading) written in your
dictation register. They cover every golden vocabulary term, the sound-alikes
from the error table, numbers, mid-sentence pauses and lowercase nouns after
jargon. Reading them from that path also brings the golden `vocabulary.json`:

```
susurrus-eval record --script Tests/Fixtures/eval/golden/read-scripts.jsonl \
  --out ~/Library/Application\ Support/Susurrus/eval/read
```

The same scripts can be dictated through the review panel with capture on,
which exercises the app's live path as tier C.

### Long recordings — `susurrus-eval segment`

Turns one long recording (a meeting; mp3, m4a, wav or anything else AVFoundation reads) into
unverified clips. It cuts at pauses into segments of `--min` to `--max`
seconds. The cut is the longest pause in that window, which in a meeting is
usually a turn change, with a hard cut at `--max` only when there is no
pause. Silence is relative to the recording's own level distribution
(30 ms frames, p10/p90). The `reference` is a promptless decode by
`--reference-model`, the strongest local model, and `raw` is the same decode
by `--raw-model`, the production model. `review` then shows where the two
disagree, which is where to listen.

- Clip ids are `<file-slug>-NNN`; `source: "conversation"`, `voice: "unknown"`,
  `verified: false`, tags `conversation` plus `short`/`long`.
- Each clip is written as soon as its reference is decoded, and the raw pass
  fills in `raw` afterwards, so an interrupted run resumes where it stopped.
- Until reviewed, references are a large model's output, so an unreviewed
  conversation corpus favours that model. `run` keeps it out of the headline
  numbers until clips are verified.
- Recordings of other people are private: keep the corpus under Application
  Support, as with tier C.

### Running with unverified clips

`run` scores verified clips only and notes how many unverified clips it
skipped. `--include-unverified` scores them too, in `unverifiedClips` and
`unverifiedSummary`. The headline `summary`, `compare` and the gate never
include them. Review a corpus before quoting its numbers.

## Model comparison — 2026-10-20

Each model with and without the vocabulary prompt, on the golden set (86
TTS clips) and the user's read-aloud set (25 clips, 11 min, real voice).
WER is after the corrector. Decode time is the median for 15–30 s clips on
the read set, M2 Pro with the app idle in the background.

| Model, prompt | Golden WER | Read WER | Read terms | Read dropped / inserted | Read extra breaks | Decode 15–30 s |
|---|---|---|---|---|---|---|
| small, prompt (production) | 6.4% | 7.8% | 55/71 | 1 / 4 | 33 | 1.3 s |
| small, none | 8.1% | 7.7% | 41/71 | 0 / 2 | 26 | 0.8 s |
| large-v3, prompt | 7.5% | 8.4% | 48/71 | 4 / 2 | 13 | 7.2 s |
| large-v3, none | 3.9% | 4.6% | 45/71 | 1 / 1 | 10 | 4.3 s |
| large-v3-v20240930_turbo, prompt | 45.4% | 77.0% | 20/71 | 23 / 1 | 3 | 1.4 s |
| large-v3-v20240930_turbo, none | 4.9% | 9.4% | 44/71 | 5 / 2 | 11 | 1.0 s |
| …_turbo_632MB, none | 6.1% | 11.3% | 39/71 | 4 / 5 | 22 | 1.0 s |

- The prompt helps `small` and hurts the large-v3 family. With the prompt,
  large-v3 drops phrases and OpenAI's 4-layer turbo decodes whole segments
  to empty text. The app therefore decodes the large-v3 family with no
  prompt (`FinalDecodeConfig.production(forModel:)`); the corrector still
  applies vocabulary afterwards.
- No model replaces `small` as the default. large-v3 without the prompt has
  about 40% fewer errors on the user's voice but takes about 3× as long to
  finish. Turbo is fast and looked good on TTS, but on the real voice it is
  worse than `small` and drops phrases.
- `susurrus-eval download --model <variant>` fetches a WhisperKit model into
  the app's model folder (`--list` shows what is there).

## Baseline — 2026-10-15

Production config (`small`, VAD chunking, ranker prompt, corrector on). 86
clips, 38 min of audio, Daniel and Flo voices, M2 Pro with the app running.

| Group | Clips | WER raw → final | Formatted err | Terms hit | Dropped / inserted runs | Extra breaks |
|---|---|---|---|---|---|---|
| overall | 86 | 6.4% → 6.4% | 8.9% | 230/324 | 1 / 2 | 88 |

*Re-baselined 2026-10-20 after the corrector fix ("says"→SAAS and "CTS
query"→"CTS XQuery" no longer fire): overall 6.4% → 6.3% final, 8.8%
formatted, terms unchanged. The table above is the original.*
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
