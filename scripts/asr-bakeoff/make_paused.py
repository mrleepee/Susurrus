"""Build a pause-heavy copy of an eval corpus: each natural pause of 400 ms
or more is stretched to 6–8 s by looping the pause's own room tone, the way
a speaker stops to think mid-dictation. References are unchanged.

Usage: /usr/bin/python3 -I make_paused.py <corpusDir> <outDir> [maxPausesPerClip]
"""
import array, json, os, random, shutil, sys, wave

FRAME = 320  # 20 ms at 16 kHz


def read(path):
    with wave.open(path) as w:
        assert w.getnchannels() == 1 and w.getsampwidth() == 2 and w.getframerate() == 16000, path
        return array.array("h", w.readframes(w.getnframes()))


def write(path, samples):
    with wave.open(path, "w") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
        w.writeframes(samples.tobytes())


def pauses(samples):
    """(start, end) sample ranges of quiet runs >= 400 ms, away from the clip edges."""
    rms = []
    for i in range(0, len(samples) - FRAME, FRAME):
        chunk = samples[i:i + FRAME]
        rms.append((sum(x * x for x in chunk) / FRAME) ** 0.5)
    floor = sorted(rms)[len(rms) // 10]
    quiet = [r < max(floor * 2.5, 60) for r in rms]
    runs, start = [], None
    for i, q in enumerate(quiet + [False]):
        if q and start is None:
            start = i
        elif not q and start is not None:
            if i - start >= 20 and start > 25 and i < len(rms) - 25:
                runs.append((start * FRAME, i * FRAME))
            start = None
    return runs


def main():
    src, out = sys.argv[1], sys.argv[2]
    cap = int(sys.argv[3]) if len(sys.argv) > 3 else 4
    rng = random.Random(7)
    os.makedirs(os.path.join(out, "clips"), exist_ok=True)
    shutil.copy(os.path.join(src, "vocabulary.json"), out)
    lines = []
    for line in open(os.path.join(src, "manifest.jsonl")):
        c = json.loads(line)
        if not c.get("verified", True):
            continue
        s = read(os.path.join(src, c["audio"]))
        runs = sorted(pauses(s), key=lambda r: r[0] - r[1])[:cap]  # longest pauses first
        runs.sort()
        outs, pos = array.array("h"), 0
        for a, b in runs:
            outs.extend(s[pos:b])
            tone = s[a:b]
            target = rng.randint(6, 8) * 16000
            while target > 0:
                outs.extend(tone[:target]); target -= len(tone)
            pos = b
        outs.extend(s[pos:])
        cid = c["id"].replace(".read", ".paused")
        rel = f"clips/{cid}.wav"
        write(os.path.join(out, rel), outs)
        c.update(id=cid, audio=rel, seconds=round(len(outs) / 16000, 1), variant="paused",
                 tags=sorted(set(c.get("tags", [])) | {"stretched-pauses"}))
        lines.append(json.dumps(c))
        print(f"{cid:30} {len(s) / 16000:5.1f}s -> {len(outs) / 16000:5.1f}s  pauses {len(runs)}")
    open(os.path.join(out, "manifest.jsonl"), "w").write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
