"""Score hypothesis JSON (from SpikeEval) against manifest references.
Metrics: normalized WER, vocab-term exact recall (case-sensitive),
dropped runs (>=3 consecutive deleted words), inserted runs (>=3 words),
spurious sentence breaks (hyp has '.', ref has none between same words)."""
import json, re, sys
TERMS = ["MarkLogic","XQuery","Datavid","Wrangler","Frankendoc","CTS","Claude","StarRocks","SciFinder","Balvinder",
         "Rodney","Divya","Silvia","Rasher","Crossref","CAS","SFN","Medline","iceberg","OpenAlex","SAAS"]
def words(s):
    s = s.lower().replace("’", "'")
    s = re.sub(r"(\d)%", r"\1 percent", s)
    s = re.sub(r"[^\w' ]+", " ", s.replace("-", " "))
    return s.split()
def align(r, h):
    n, m = len(r), len(h)
    d = [[0]*(m+1) for _ in range(n+1)]
    for i in range(n+1): d[i][0] = i
    for j in range(m+1): d[0][j] = j
    for i in range(1, n+1):
        for j in range(1, m+1):
            d[i][j] = min(d[i-1][j]+1, d[i][j-1]+1, d[i-1][j-1]+(r[i-1]!=h[j-1]))
    ops, i, j = [], n, m
    while i or j:
        if i and j and d[i][j] == d[i-1][j-1]+(r[i-1]!=h[j-1]):
            ops.append('C' if r[i-1]==h[j-1] else 'S'); i-=1; j-=1
        elif i and d[i][j] == d[i-1][j]+1: ops.append('D'); i-=1
        else: ops.append('I'); j-=1
    return d[n][m], ops[::-1]
def runs(ops, kind, k=3):
    c = best = 0; out = 0
    for o in ops:
        c = c+1 if o == kind else 0
        if c == k: out += 1
    return out
def breaks(ref, hyp):
    # count sentence-final '.' in hyp followed by a word that, in ref, is not after a sentence end
    hs = len(re.findall(r"[.?!]\s", hyp + " ")); rs = len(re.findall(r"[.?!]\s", ref + " "))
    return max(0, hs - rs)
def main(manifest, hyp_path, variant_filter=None):
    refs = {m["id"]: m["text"] for m in json.load(open(manifest))}
    hyps = json.load(open(hyp_path))
    tot_e = tot_n = 0; tterm = hterm = 0; drops = ins = brk = 0; ms = secs = 0
    rows = []
    for h in hyps:
        base, variant = h["id"].rsplit("_", 1)
        if variant_filter and variant != variant_filter: continue
        ref = refs[base]; r, w = words(ref), words(h["text"])
        e, ops = align(r, w)
        tot_e += e; tot_n += len(r)
        for t in TERMS:
            c = ref.count(t)
            if c: tterm += c; hterm += min(c, h["text"].count(t))
        dr, ir, b = runs(ops, 'D'), runs(ops, 'I'), breaks(ref, h["text"])
        drops += dr; ins += ir; brk += b; ms += h["ms"]; secs += h["seconds"]
        rows.append((h["id"], round(100*e/len(r),1), dr, ir, b, h["ms"]))
    print(f"WER {100*tot_e/tot_n:5.1f}%  terms {hterm}/{tterm}  dropRuns {drops}  insRuns {ins}  extraBreaks {brk}  decode {ms/1000:.1f}s for {secs:.0f}s audio (RTF {ms/1000/secs:.3f})")
    return rows
if __name__ == "__main__":
    rows = main(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
    if "-v" in sys.argv:
        for r in rows: print("   ", r)
