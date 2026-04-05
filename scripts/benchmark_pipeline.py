#!/usr/bin/env python3
"""Benchmark chunked Gemma 4 pipeline — sequential vs simulated parallel.

Metal doesn't support concurrent command buffer encoding on a single GPU,
so true parallelism isn't possible. Instead we:
  1. Time each chunk individually (sequential)
  2. Calculate what parallel time WOULD be (slowest chunk wall-clock)
  3. Compare sequential vs theoretical parallel

Usage:
    source .venv/bin/activate
    python scripts/benchmark_pipeline.py --model e2b --audio test_clip_20s.wav
    python scripts/benchmark_pipeline.py --model e2b --audio /path/to/long.mp3 --max-chunk-s 8
"""

import argparse
import time
import numpy as np
import soundfile as sf


def detect_silence_boundaries(audio, sr, min_silence_ms=300, silence_thresh_db=-40,
                               min_chunk_ms=2000, max_chunk_ms=10000):
    """Split audio on silence boundaries."""
    window_samples = int(sr * 0.03)
    hop_samples = window_samples // 2

    energies = []
    for i in range(0, len(audio) - window_samples, hop_samples):
        chunk = audio[i:i + window_samples]
        energies.append(np.sqrt(np.mean(chunk ** 2)))

    thresh = 10 ** (silence_thresh_db / 20)
    is_silent = np.array(energies) < thresh

    silence_regions = []
    in_silence = False
    start = 0
    for i, s in enumerate(is_silent):
        if s and not in_silence:
            start = i
            in_silence = True
        elif not s and in_silence:
            silence_regions.append((start * hop_samples, i * hop_samples))
            in_silence = False
    if in_silence:
        silence_regions.append((start * hop_samples, len(audio)))

    min_silence_samples = int(sr * min_silence_ms / 1000)
    split_points = [0]
    for s, e in silence_regions:
        if (e - s) >= min_silence_samples:
            split_points.append((s + e) // 2)
    split_points.append(len(audio))
    split_points.sort()

    chunks = []
    current_start = split_points[0]
    max_samples = int(sr * max_chunk_ms / 1000)
    min_samples = int(sr * min_chunk_ms / 1000)

    for sp in split_points[1:]:
        chunk_len = sp - current_start
        if chunk_len >= max_samples:
            offset = 0
            while offset < chunk_len:
                end = min(offset + max_samples, chunk_len)
                if (end - offset) < min_samples and chunks:
                    prev_s, _ = chunks.pop()
                    chunks.append((prev_s, current_start + end))
                else:
                    chunks.append((current_start + offset, current_start + end))
                offset = end
        else:
            if chunk_len < min_samples and chunks:
                prev_s, _ = chunks.pop()
                chunks.append((prev_s, sp))
            else:
                chunks.append((current_start, sp))
        current_start = sp

    return chunks


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", choices=["e2b", "e4b"], default="e2b")
    parser.add_argument("--audio", required=True)
    parser.add_argument("--max-chunk-s", type=float, default=10.0)
    args = parser.parse_args()

    model_name = {
        "e2b": "google/gemma-4-e2b-it",
        "e4b": "google/gemma-4-e4b-it",
    }[args.model]

    from mlx_vlm import load, generate as gen
    from mlx_vlm.prompt_utils import apply_chat_template

    print(f"Loading {model_name}...")
    t0 = time.time()
    model, processor = load(model_name)
    print(f"Loaded in {time.time() - t0:.1f}s")

    # Warmup
    wp = apply_chat_template(processor, model.config, "Hi")
    gen(model=model, processor=processor, prompt=wp, max_tokens=5, temperature=0.0)
    data, sr = sf.read(args.audio)
    warmup_path = "/tmp/_pipeline_warmup.wav"
    sf.write(warmup_path, data[:sr], sr)
    wap = apply_chat_template(processor, model.config, "Transcribe", num_audios=1)
    gen(model=model, processor=processor, prompt=wap, audio=[warmup_path], max_tokens=10, temperature=0.0)
    print("Warmup complete.\n")

    # Load audio
    data, sr = sf.read(args.audio)
    if data.ndim > 1:
        data = data.mean(axis=1)
    duration = len(data) / sr
    print(f"Audio: {args.audio} ({duration:.1f}s, {sr}Hz)\n")

    # VAD split
    t0 = time.time()
    chunks = detect_silence_boundaries(
        data, sr, min_silence_ms=300, silence_thresh_db=-40,
        min_chunk_ms=2000, max_chunk_ms=int(args.max_chunk_s * 1000),
    )
    vad_time = time.time() - t0

    print(f"VAD split ({vad_time*1000:.0f}ms) → {len(chunks)} chunks:")
    for i, (s, e) in enumerate(chunks):
        print(f"  Chunk {i+1}: {(e-s)/sr:.1f}s [{s/sr:.1f}s - {e/sr:.1f}s]")

    # Write chunk files
    chunk_paths = []
    for i, (s, e) in enumerate(chunks):
        p = f"/tmp/_chunk_{i}.wav"
        sf.write(p, data[s:e], sr)
        chunk_paths.append(p)

    raw_prompt = "Transcribe this audio verbatim. Output only the spoken text, nothing else."

    # --- Transcribe chunks sequentially, timing each ---
    print(f"\n--- TRANSCRIBE CHUNKS ---")

    chunk_data = []  # (time_s, text, duration_s)
    for i, cp in enumerate(chunk_paths):
        prompt = apply_chat_template(processor, model.config, raw_prompt, num_audios=1)
        t0 = time.time()
        result = gen(model=model, processor=processor, prompt=prompt,
                     audio=[cp], max_tokens=500, temperature=0.0)
        elapsed = time.time() - t0
        text = result.text.strip() if hasattr(result, 'text') else str(result).strip()
        chunk_dur = (chunks[i][1] - chunks[i][0]) / sr
        chunk_data.append((elapsed, text, chunk_dur))
        print(f"  Chunk {i+1} ({chunk_dur:.1f}s): {elapsed:.2f}s → \"{text[:70]}\"")

    combined_raw = " ".join(t[1] for t in chunk_data)

    # --- LLM cleanup ---
    print(f"\n--- LLM CLEANUP ---")
    clean_prompt_text = (
        "Clean up the following transcription for professional use. "
        "Remove filler words (um, uh, like, you know), fix grammar and punctuation, "
        "remove false starts and repetitions, and produce polished text. "
        "Output only the cleaned text, nothing else.\n\n"
        f"Transcription:\n{combined_raw}"
    )
    clean_prompt = apply_chat_template(processor, model.config, clean_prompt_text)
    t0 = time.time()
    clean_result = gen(model=model, processor=processor, prompt=clean_prompt,
                       max_tokens=1000, temperature=0.0)
    cleanup_time = time.time() - t0
    cleaned = clean_result.text.strip() if hasattr(clean_result, 'text') else str(clean_result).strip()
    print(f"  Cleanup: {cleanup_time:.2f}s")

    # --- Calculate theoretical parallel times ---
    chunk_times = [t[0] for t in chunk_data]
    sequential_time = sum(chunk_times)

    # For N workers, assign chunks round-robin, wall-clock = max(sum of times per worker)
    parallel_results = {}
    for n_workers in [2, 3, 4]:
        worker_buckets = [[] for _ in range(n_workers)]
        for i, ct in enumerate(chunk_times):
            worker_buckets[i % n_workers].append(ct)
        wall_clock = max(sum(bucket) for bucket in worker_buckets)
        parallel_results[n_workers] = wall_clock

    # --- Summary ---
    seq_total = vad_time + sequential_time + cleanup_time

    print(f"\n{'='*70}")
    print(f" RESULTS — {model_name} | {duration:.0f}s audio | {len(chunks)} chunks")
    print(f"{'='*70}\n")

    print(f"  VAD split:    {vad_time*1000:.0f}ms")
    print(f"  Chunk times:  {', '.join(f'{t:.2f}s' for t in chunk_times)}")
    print(f"  Cleanup:      {cleanup_time:.2f}s")
    print()

    print(f"  {'Config':>12} | {'Transcribe':>11} | {'+VAD+Cleanup':>12} | {'Total':>7} | {'RTF':>6}")
    print(f"  {'-'*65}")
    print(f"  {'Sequential':>12} | {sequential_time:>10.2f}s | {vad_time+cleanup_time:>10.2f}s | {seq_total:>6.2f}s | {seq_total/duration:>5.2f}x")

    for n, wall in parallel_results.items():
        total = vad_time + wall + cleanup_time
        print(f"  {f'{n} parallel':>12} | {wall:>10.2f}s | {vad_time+cleanup_time:>10.2f}s | {total:>6.2f}s | {total/duration:>5.2f}x")

    print(f"  {'-'*65}")
    print()
    print(f"  NOTE: Metal GPU doesn't support concurrent inference on a single device.")
    print(f"  Parallel times are theoretical (best wall-clock if chunks ran on separate GPUs).")
    print(f"  On Apple Silicon with unified memory, sequential is the real ceiling.")
    print()
    print(f"  RAW:     {combined_raw}")
    print(f"  CLEANED: {cleaned}")


if __name__ == "__main__":
    main()
