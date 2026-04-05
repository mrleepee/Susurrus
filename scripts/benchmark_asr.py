#!/usr/bin/env python3
"""Benchmark Gemma 4 MLX — hot runs only (model pre-loaded).

Tests two prompts per clip:
  1. RAW  — verbatim transcription
  2. CLEAN — transcribe + cleanup in one pass

Usage:
    source .venv/bin/activate
    python scripts/benchmark_asr.py --model e2b --audio clip1.wav clip2.wav
"""

import argparse
import time
import soundfile as sf


PROMPTS = {
    "RAW": "Transcribe this audio verbatim. Output only the spoken text, nothing else.",
    "CLEAN": (
        "Transcribe this audio and clean it up for professional use. "
        "Remove filler words (um, uh, like, you know), fix grammar and punctuation, "
        "remove false starts and repetitions, and produce polished text. "
        "Output only the cleaned text, nothing else."
    ),
}


def main():
    parser = argparse.ArgumentParser(description="Benchmark Gemma 4 MLX ASR (hot runs)")
    parser.add_argument("--model", choices=["e2b", "e4b"], default="e2b")
    parser.add_argument("--audio", nargs="+", required=True)
    parser.add_argument("--runs", type=int, default=3, help="Hot runs per combo (default 3)")
    args = parser.parse_args()

    model_name = {
        "e2b": "google/gemma-4-e2b-it",
        "e4b": "google/gemma-4-e4b-it",
    }[args.model]

    from mlx_vlm import load, generate as gen
    from mlx_vlm.prompt_utils import apply_chat_template

    # Load model
    print(f"\nLoading {model_name}...")
    t0 = time.time()
    model, processor = load(model_name)
    print(f"Loaded in {time.time() - t0:.1f}s")

    # Warmup — compile Metal shaders with a text-only gen
    print("Warming up Metal shaders...")
    wp = apply_chat_template(processor, model.config, "Hi")
    gen(model=model, processor=processor, prompt=wp, max_tokens=5, temperature=0.0)
    # Second warmup with audio to compile audio encoder shaders
    print("Warming up audio pipeline...")
    first_audio = args.audio[0]
    data, sr = sf.read(first_audio)
    warmup_path = "/tmp/_susurrus_warmup.wav"
    sf.write(warmup_path, data[:sr], sr)  # tiny clip
    wa_prompt = apply_chat_template(processor, model.config, PROMPTS["RAW"], num_audios=1)
    gen(model=model, processor=processor, prompt=wa_prompt, audio=[warmup_path], max_tokens=10, temperature=0.0)
    print("Warmup complete.\n")

    all_results = []

    for audio_path in args.audio:
        data, sr = sf.read(audio_path)
        duration = len(data) / sr

        print(f"{'='*60}")
        print(f"Audio: {audio_path} ({duration:.1f}s)")
        print(f"{'='*60}")

        for prompt_name, prompt_text in PROMPTS.items():
            prompt = apply_chat_template(
                processor, model.config, prompt_text, num_audios=1,
            )

            times = []
            texts = []
            tok_rates = []
            peak_mem = 0

            for i in range(args.runs):
                t0 = time.time()
                result = gen(
                    model=model, processor=processor, prompt=prompt,
                    audio=[audio_path], max_tokens=500, temperature=0.0,
                )
                elapsed = time.time() - t0
                text = result.text.strip() if hasattr(result, 'text') else str(result).strip()

                times.append(elapsed)
                texts.append(text)
                tok_rates.append(result.generation_tps)
                peak_mem = max(peak_mem, result.peak_memory)

                print(f"  [{prompt_name:>5} #{i+1}] {elapsed:.2f}s ({elapsed/duration:.2f}x RT, {result.generation_tps:.1f} tok/s)")

            all_results.append({
                "audio": audio_path,
                "duration_s": duration,
                "prompt": prompt_name,
                "times": times,
                "best_s": min(times),
                "avg_s": sum(times) / len(times),
                "tok_s": sum(tok_rates) / len(tok_rates),
                "peak_gb": peak_mem,
                "text": texts[0],
            })

            print(f"  [{prompt_name:>5}  avg] {sum(times)/len(times):.2f}s  best: {min(times):.2f}s")
            print(f"           Text: {texts[0][:150]}\n")

    # --- Summary table ---
    print(f"{'='*70}")
    print(f" SUMMARY — {model_name} (hot runs, {args.runs}x each)")
    print(f"{'='*70}\n")

    print(f"{'Clip':>6} {'Mode':>6} | {'Best':>7} | {'Avg':>7} | {'RTF':>6} | {'tok/s':>6} | {'GB':>4} | Text")
    print("-" * 85)

    for r in all_results:
        label = f"{r['duration_s']:.0f}s"
        print(f"{label:>6} {r['prompt']:>6} | {r['best_s']:>6.2f}s | {r['avg_s']:>6.2f}s | {r['best_s']/r['duration_s']:>5.2f}x | {r['tok_s']:>5.1f} | {r['peak_gb']:>3.1f} | {r['text'][:50]}")

    print("-" * 85)

    # --- RAW vs CLEAN ---
    print("\nRAW vs CLEAN comparison:")
    for af in sorted(set(r["audio"] for r in all_results)):
        raw = next(r for r in all_results if r["audio"] == af and r["prompt"] == "RAW")
        clean = next(r for r in all_results if r["audio"] == af and r["prompt"] == "CLEAN")
        overhead = clean["best_s"] - raw["best_s"]
        pct = ((clean["best_s"] / raw["best_s"]) - 1) * 100

        print(f"\n  {af} ({raw['duration_s']:.0f}s):")
        print(f"  RAW:   {raw['text']}")
        print(f"  CLEAN: {clean['text']}")
        print(f"  Cost:  +{overhead:.2f}s ({pct:+.0f}%)")
        print()


if __name__ == "__main__":
    main()
