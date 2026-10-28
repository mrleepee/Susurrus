"""Render manifest texts to 16 kHz mono WAV with macOS `say`.
Variant 'clean' reads straight through; 'paused' inserts 1.5s thinking
pauses at every second comma to mimic real dictation hesitations."""
import json, subprocess, sys, re
corpus = sys.argv[1]
voice = sys.argv[2] if len(sys.argv) > 2 else "Daniel (English (UK))"
items = json.load(open(f"{corpus}/manifest.json"))
for it in items:
    for variant in ("clean", "paused"):
        text = it["text"]
        if variant == "paused":
            n = 0
            def pause(m):
                global n
                n += 1
                return m.group(0) + (" [[slnc 1500]] " if n % 2 == 0 else "")
            text = re.sub(r",", pause, text)
        out = f"{corpus}/{it['id']}_{variant}.wav"
        subprocess.run(["say", "-v", voice, "-o", out, "--file-format=WAVE",
                        "--data-format=LEI16@16000", text], check=True)
print("ok", len(items))
