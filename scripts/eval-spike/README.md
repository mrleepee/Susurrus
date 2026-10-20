# Eval spike (2026-10-15)

Throwaway proof that an offline accuracy harness works. See
[docs/transcription-quality-plan.md](../../docs/transcription-quality-plan.md) §2.
These will be replaced by the Swift `susurrus-eval` target (plan §3); kept so
the spike numbers can be reproduced.

- `gen_tts.py <corpus>` — renders `<corpus>/manifest.json` (`[{id, text}]`) to
  16 kHz WAV with `say`, in `clean` and `paused` variants.
- `SpikeEval.swift` — `main.swift` of an executable target added to a scratch
  copy of WhisperKit 0.17.0. Loads a model once and decodes WAVs with the app's
  final-decode options. Usage: `SpikeEval <modelFolder> <out.json> <prompt|-> <wav>...`
- `score.py <manifest> <out.json> [clean|paused] [-v]` — WER, exact vocab-term
  hits, dropped/inserted 3-word runs, extra sentence breaks, RTF.

The spike corpus was built from personal dictation history and is deliberately
not in the repo.
