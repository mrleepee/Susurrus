#!/usr/bin/env python3
"""Exhaustive llama.cpp server benchmark for Gemma 4 text cleanup.

Architecture: WhisperKit (ASR) → llama.cpp/Gemma4 (text cleanup) → clipboard

Tests:
  1. Model download + server startup time for E2B Q4_K_M, Q8_0, and Q4_K_S
  2. Text cleanup latency (short 10s, medium 20s, long 60s transcriptions)
  3. Throughput at different concurrency levels (1, 2, 4, 8 concurrent requests)
  4. Memory usage per quantization level

Usage:
    source .venv/bin/activate
    python scripts/benchmark_llamacpp.py
"""

import json
import subprocess
import sys
import time
import signal
import os
import httpx

# --- Config ---

MODELS = {
    "E2B Q4_K_S": "ggml-org/gemma-4-e2b-it-GGUF:Q4_K_S",
}

PORT = 8321

# Simulated WhisperKit transcriptions of varying length
TRANSCRIPTIONS = {
    "10s": (
        "I think uh a couple of high level uh important um important items here "
        "to to hit first. So um the main thing is we need to get the statement "
        "of work signed before the end of the month."
    ),
    "20s": (
        "so I I don't know how why how widely this was known but um and we may "
        "have referred to it yesterday but um the the statement of work that um "
        "ACS had with databid um had ended or was about to end and and so um "
        "we we need to think about um you know what what the next steps are "
        "going to be for for the the project going forward"
    ),
    "60s": (
        "um so I wanted to uh circle back on on the the Clay project um and "
        "and discuss um you know where we where we stand. Um I think the the "
        "first thing to to hit is is the statement of work um with ACS. So "
        "the the previous SOW um had had ended um or or was about to end and "
        "um we we need to um you know think about what what the renewal looks "
        "like. Um I think there were a couple of um high level important items "
        "that that came out of the the last meeting. Um one was was the the "
        "timeline um and and whether we can can meet the the deadlines that "
        "were were discussed. Um and and two was was the the budget um and "
        "whether the the numbers still still make sense given given the the "
        "scope changes that that happened. So um I I think we we should um "
        "you know set up a a follow up meeting um with with the the client "
        "to to go through the the revised SOW um and and make sure everyone "
        "is is aligned on on the on the deliverables and and timelines."
    ),
}

SYSTEM_PROMPT = "You are a transcription cleanup assistant. Output ONLY cleaned text. No explanations, no thinking, no preamble."

USER_PROMPT = """Clean up this transcription. Remove filler words (um, uh, like, you know), fix grammar, punctuation, remove false starts and repetitions.

Transcription:
{transcription}"""

BASE_URL = f"http://127.0.0.1:{PORT}"


def wait_for_server(timeout=120):
    """Wait for server to be ready."""
    start = time.time()
    while time.time() - start < timeout:
        try:
            r = httpx.get(f"{BASE_URL}/health", timeout=2)
            if r.status_code == 200:
                return True
        except (httpx.ConnectError, httpx.TimeoutException):
            pass
        time.sleep(0.5)
    return False


def kill_server(proc):
    """Kill server process."""
    if proc and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def start_server(model_id: str):
    """Start llama-server with given model. Returns (proc, startup_time)."""
    print(f"  Starting server with {model_id}...")
    t0 = time.time()
    proc = subprocess.Popen(
        ["llama-server", "-hf", model_id, "--port", str(PORT),
         "-ngl", "99", "--host", "127.0.0.1"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )

    if not wait_for_server(timeout=180):
        kill_server(proc)
        print("  ERROR: Server failed to start within 180s")
        return None, 0

    startup = time.time() - t0

    # Get model info
    try:
        info = httpx.get(f"{BASE_URL}/props", timeout=5).json()
        mem = info.get("default_generation_settings", {}).get("n_gpu_layers", "?")
        print(f"  Server ready in {startup:.1f}s (GPU layers: {mem})")
    except Exception:
        print(f"  Server ready in {startup:.1f}s")

    return proc, startup


def benchmark_cleanup(label: str, transcription: str, runs: int = 3) -> dict:
    """Benchmark text cleanup. Returns {times, texts, avg, min}."""
    prompt = USER_PROMPT.format(transcription=transcription)

    times = []
    texts = []

    for i in range(runs):
        t0 = time.time()
        r = httpx.post(
            f"{BASE_URL}/v1/chat/completions",
            json={
                "model": "gemma-4",
                "messages": [
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": prompt},
                ],
                "max_tokens": 500,
                "temperature": 0.0,
            },
            timeout=30,
        )
        elapsed = time.time() - t0

        if r.status_code != 200:
            print(f"    Run {i+1}: ERROR {r.status_code}")
            continue

        data = r.json()
        text = data["choices"][0]["message"]["content"].strip()
        usage = data.get("usage", {})
        prompt_tok = usage.get("prompt_tokens", 0)
        gen_tok = usage.get("completion_tokens", 0)

        times.append(elapsed)
        texts.append(text)
        tok_s = gen_tok / elapsed if elapsed > 0 else 0
        print(f"    Run {i+1}: {elapsed:.2f}s ({gen_tok} tok, {tok_s:.1f} tok/s)")

    return {
        "label": label,
        "times": times,
        "texts": texts,
        "avg": sum(times) / len(times) if times else 0,
        "min": min(times) if times else 0,
    }


def benchmark_concurrency(transcription: str, workers: int, requests: int = 8) -> dict:
    """Benchmark concurrent cleanup requests."""
    prompt = USER_PROMPT.format(transcription=transcription)

    def do_request():
        t0 = time.time()
        r = httpx.post(
            f"{BASE_URL}/v1/chat/completions",
            json={
                "model": "gemma-4",
                "messages": [
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": prompt},
                ],
                "max_tokens": 500,
                "temperature": 0.0,
            },
            timeout=60,
        )
        elapsed = time.time() - t0
        gen_tok = r.json().get("usage", {}).get("completion_tokens", 0) if r.status_code == 200 else 0
        return elapsed, gen_tok

    import concurrent.futures

    t0 = time.time()
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        futures = [executor.submit(do_request) for _ in range(requests)]
        results = [f.result() for f in concurrent.futures.as_completed(futures)]
    wall_time = time.time() - t0

    times = [r[0] for r in results]
    total_tok = sum(r[1] for r in results)

    return {
        "workers": workers,
        "requests": requests,
        "wall_time": wall_time,
        "avg_per_req": sum(times) / len(times),
        "total_tokens": total_tok,
        "throughput_tok_s": total_tok / wall_time if wall_time > 0 else 0,
    }


def main():
    print("=" * 70)
    print(" LLAMA.CPP + GEMMA 4 — EXHAUSTIVE BENCHMARK")
    print("=" * 70)
    print(f" Hardware: M2 Pro 32GB")
    print(f" Server:   llama.cpp {subprocess.run(['llama-server', '--version'], capture_output=True, text=True).stdout.strip()}")
    print()

    all_results = {}

    for model_label, model_id in MODELS.items():
        print(f"\n{'='*70}")
        print(f" MODEL: {model_label}")
        print(f"{'='*70}")

        proc, startup = start_server(model_id)
        if proc is None:
            continue

        model_results = {"startup_s": startup, "cleanup": {}, "concurrency": {}}

        # --- Cleanup latency tests ---
        print(f"\n  --- CLEANUP LATENCY ---")
        for clip_label, transcription in TRANSCRIPTIONS.items():
            print(f"\n  [{clip_label} transcription]")
            r = benchmark_cleanup(clip_label, transcription, runs=3)
            model_results["cleanup"][clip_label] = r

        # --- Concurrency tests (20s transcription) ---
        print(f"\n  --- CONCURRENCY (20s transcription) ---")
        for workers in [1, 2, 4, 8]:
            r = benchmark_concurrency(TRANSCRIPTIONS["20s"], workers, requests=8)
            model_results["concurrency"][workers] = r
            print(f"    {workers} workers x 8 req: {r['wall_time']:.2f}s wall, "
                  f"{r['avg_per_req']:.2f}s/req, {r['throughput_tok_s']:.1f} tok/s total")

        # --- Memory check ---
        try:
            props = httpx.get(f"{BASE_URL}/props", timeout=5).json()
            print(f"\n  Server props: {json.dumps(props, indent=2)[:300]}")
        except Exception:
            pass

        kill_server(proc)
        time.sleep(2)  # let GPU memory clear

        all_results[model_label] = model_results

    # --- Final Summary ---
    print(f"\n\n{'='*70}")
    print(f" FINAL SUMMARY")
    print(f"{'='*70}\n")

    # Startup
    print(f"{'Model':>16} | {'Startup':>8}")
    print("-" * 30)
    for label, r in all_results.items():
        print(f"{label:>16} | {r['startup_s']:>7.1f}s")
    print()

    # Cleanup latency
    print(f"{'Model':>16} | {'10s clip':>10} | {'20s clip':>10} | {'60s clip':>10}")
    print("-" * 55)
    for label, r in all_results.items():
        c = r["cleanup"]
        vals = []
        for clip in ["10s", "20s", "60s"]:
            if clip in c and c[clip]["times"]:
                vals.append(f"{c[clip]['avg']:>8.2f}s")
            else:
                vals.append(f"{'N/A':>10}")
        print(f"{label:>16} | {vals[0]:>10} | {vals[1]:>10} | {vals[2]:>10}")
    print()

    # Concurrency
    print(f"{'Model':>16} | {'1w':>8} | {'2w':>8} | {'4w':>8} | {'8w':>8}")
    print("-" * 55)
    for label, r in all_results.items():
        conc = r["concurrency"]
        vals = []
        for w in [1, 2, 4, 8]:
            if w in conc:
                vals.append(f"{conc[w]['avg_per_req']:>6.2f}s")
            else:
                vals.append(f"{'N/A':>8}")
        print(f"{label:>16} | {vals[0]:>8} | {vals[1]:>8} | {vals[2]:>8} | {vals[3]:>8}")
    print()

    # Show sample output
    for label, r in all_results.items():
        c = r.get("cleanup", {}).get("20s", {})
        if c.get("texts"):
            print(f"  [{label}] 20s cleaned: {c['texts'][0][:120]}")
    print()


if __name__ == "__main__":
    main()
