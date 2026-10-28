"""Summarise lfm_eval.py outputs. Usage: python3 -I summarise.py run1.json [run2.json ...]"""
import json, sys

KEYS = ["refWords", "wordErrors", "fmtTokens", "fmtErrors", "termsExpected", "termsHit", "termFalseFires", "extraBreaks"]


def total(rows, which):
    return {k: sum(r[which][k] for r in rows) for k in KEYS}


def line(name, t, lat=""):
    return (f"{name:22} WER {t['wordErrors'] / t['refWords']:6.1%}  fmt-err {t['fmtErrors'] / t['fmtTokens']:6.1%}  "
            f"terms {t['termsHit']}/{t['termsExpected']} (+{t['termFalseFires']} false)  extra-breaks {t['extraBreaks']:3}  {lat}")


first = True
for path in sys.argv[1:]:
    d = json.load(open(path))
    rows = d["rows"]
    if first:
        print(line("production (no LLM)", total(rows, "base")))
        first = False
    ms = sorted(r["ms"] for r in rows if r["ms"] >= 0)
    rej = sum(not r["accepted"] for r in rows)
    lat = f"latency median {ms[len(ms) // 2] / 1000:.1f}s max {ms[-1] / 1000:.1f}s  rejected {rej}/{len(rows)}"
    print(line(d["config"], total(rows, "scored"), lat))
