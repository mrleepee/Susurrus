"""Score asr-bakeoff runs and susurrus-eval runs on the same corpus.

Usage: python3 -I score.py <corpusDir> <run.json> [<run.json> ...]
A susurrus-eval run contributes two rows: its raw ASR text and its final
(post-corrector) text. Bake-off runs contribute their text as-is.
"""
import json, os, re, sys, difflib, statistics


def norm(t):
    t = t.lower().replace("’", "'")
    t = re.sub(r"(\d),(\d{3})", r"\1\2", t).replace("%", " percent")
    return [w.strip("'") for w in re.sub(r"[^a-z0-9' ]+", " ", t).split() if w.strip("'")]


def ops(r, h):
    sm = difflib.SequenceMatcher(a=r, b=h, autojunk=False)
    sub = ins = dele = 0
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "replace":
            n, m = i2 - i1, j2 - j1
            sub += min(n, m)
            ins += max(0, m - n)
            dele += max(0, n - m)
        elif tag == "insert":
            ins += j2 - j1
        elif tag == "delete":
            dele += i2 - i1
    return sub, ins, dele


def term_hits(ref, hyp, terms):
    exp = hit = 0
    for t in terms:
        pat = r"(?<![A-Za-z0-9])" + re.escape(t) + r"(?![A-Za-z0-9])"
        nr = len(re.findall(pat, ref, flags=re.I if t.isupper() else 0))
        nh = len(re.findall(pat, hyp, flags=re.I if t.isupper() else 0))
        exp += nr
        hit += min(nr, nh)
    return exp, hit


def breaks(t):
    return len(re.findall(r"[.!?](\s|$)", t))


def main():
    corpus = sys.argv[1]
    refs = {}
    with open(os.path.join(corpus, "manifest.jsonl")) as f:
        for line in f:
            c = json.loads(line)
            if c.get("verified", True):
                refs[c["id"]] = c
    terms = [e["term"] for e in json.load(open(os.path.join(corpus, "vocabulary.json")))["entries"]]

    rows = []
    for path in sys.argv[2:]:
        d = json.load(open(path))
        if "engine" in d:
            rows.append((d["engine"] + (" +vocab" if d.get("vocabTerms") else ""),
                         {c["id"]: (c["text"], c["ms"]) for c in d["clips"]}))
        else:
            rows.append((d["name"] + " raw", {c["id"]: (c["raw"], c.get("decodeMs", 0)) for c in d["clips"]}))
            rows.append((d["name"] + " final", {c["id"]: (c["final"], c.get("decodeMs", 0)) for c in d["clips"]}))

    print(f"{'engine':34} {'WER':>6} {'sub':>4} {'ins':>4} {'del':>4} {'fmtErr':>7} {'terms':>6} {'xBrk':>5} "
          f"{'≤21s':>6} {'50-62s':>7}")
    for name, hyp in rows:
        R = S = I = D = FT = FE = EX = HT = XB = 0
        short, long_ = [], []
        for cid, c in refs.items():
            if cid not in hyp:
                continue
            text, ms = hyp[cid]
            ref = c["reference"]
            s, i, d = ops(norm(ref), norm(text))
            R += len(norm(ref)); S += s; I += i; D += d
            fs, fi, fd = ops(ref.split(), text.split())
            FT += len(ref.split()); FE += fs + fi + fd
            e, h = term_hits(ref, text, terms)
            EX += e; HT += h
            XB += max(0, breaks(text) - breaks(ref))
            (short if c["seconds"] <= 21 else long_ if c["seconds"] >= 50 else []).append(ms)
        med = lambda xs: f"{statistics.median(xs) / 1000:.1f}s" if xs else "-"
        print(f"{name:34} {(S + I + D) / R:6.1%} {S:4} {I:4} {D:4} {FE / FT:7.1%} {HT:3}/{EX:<2} {XB:5} "
              f"{med(short):>6} {med(long_):>7}")


if __name__ == "__main__":
    main()
