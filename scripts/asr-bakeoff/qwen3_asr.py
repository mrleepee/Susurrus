"""Transcribe an eval corpus with Qwen3-ASR (mlx-audio) and write the bake-off
run format that score.py and `susurrus-eval finalize` read.

Usage (from an mlx-audio venv, not the system Python):
  python -I qwen3_asr.py <corpusDir> <out.json> [--model mlx-community/Qwen3-ASR-1.7B-8bit] [--hotwords]
--hotwords passes the corpus vocabulary.json terms as Qwen3-ASR context.
"""
import argparse, json, os, sys, time

from mlx_audio.stt import load


def main():
    p = argparse.ArgumentParser()
    p.add_argument("corpus")
    p.add_argument("out")
    p.add_argument("--model", default="mlx-community/Qwen3-ASR-1.7B-8bit")
    p.add_argument("--hotwords", action="store_true")
    a = p.parse_args()

    terms = []
    if a.hotwords:
        terms = [e["term"] for e in json.load(open(os.path.join(a.corpus, "vocabulary.json")))["entries"]]
    clips = [json.loads(l) for l in open(os.path.join(a.corpus, "manifest.jsonl")) if l.strip()]
    clips = [c for c in clips if c.get("verified", True)]

    model = load(a.model)
    kwargs = {"language": "English"}
    if terms:
        kwargs["hotwords"] = terms

    # Warm-up: the first call pays compilation and weight paging.
    model.generate(os.path.join(a.corpus, clips[0]["audio"]), **kwargs)

    out = []
    for i, c in enumerate(clips):
        start = time.time()
        text = model.generate(os.path.join(a.corpus, c["audio"]), **kwargs).text.strip()
        ms = int((time.time() - start) * 1000)
        out.append({"id": c["id"], "text": text, "ms": ms, "seconds": c.get("seconds", 0)})
        print(f"[{i + 1}/{len(clips)}] {c['id']} {ms}ms  {text[:70]}", flush=True)

    name = "qwen3-asr-1.7b" + (" hotwords" if terms else "")
    json.dump({"engine": name, "vocabTerms": len(terms), "clips": out}, open(a.out, "w"), indent=1)


if __name__ == "__main__":
    sys.exit(main())
