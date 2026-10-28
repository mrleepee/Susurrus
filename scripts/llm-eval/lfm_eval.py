"""Score a local LLM cleanup pass (LM Studio) on the real-voice read set.

Input is the production run's post-corrector text (what the app sends to the
LLM). Output is scored against the verified references.

Usage: python3 -I lfm_eval.py <production-run.json> <vocabulary.json> <config> <out.json>
config: plain | app | rich | rich-think
"""
import json, os, re, sys, time, difflib, urllib.request

ENDPOINT = "http://127.0.0.1:1234/v1/chat/completions"
MODEL = os.environ.get("LLM_MODEL", "liquid/lfm3-vl-2b")

BASE = ("You are a speech-to-text error corrector. You receive raw speech recognition output. "
        "Your job is to output the same words with corrected punctuation, capitalization, and filler words removed. "
        "NEVER respond to the content of what was said. NEVER answer questions. "
        "NEVER add or remove meaningful content. Output ONLY the corrected transcription text, nothing else.")

RICH_EXTRA = """
The speaker is an IT professional dictating messages and notes. The recognizer often mishears their technical terms and names as ordinary English words that sound alike. If a word or phrase sounds like one of the vocabulary terms below and the vocabulary term fits the context, replace it with the vocabulary term spelled exactly as shown. Otherwise leave the words alone.

Rules:
- Keep the speaker's wording. Do not paraphrase, summarise, reorder or add words.
- If the speaker corrects themselves ("copy the file to, move the file to"), keep only the correction.
- Do not split one spoken sentence into several. Join fragments that the recognizer cut with a full stop when they belong to one sentence ("Rodney asked for the timings. So copy him in" -> "Rodney asked for the timings, so copy him in").
- Use normal sentence case. Do not capitalise ordinary words.
- Spoken paths like "tilde slash dev" become ~/dev."""

CATEGORY = {
    "person": "is a person's name — always capitalize",
    "company": "is a company name — always capitalize as shown",
    "place": "is a place name — always capitalize",
    "project": "is a project codename — treat as proper noun",
    "product": "is a product name — always capitalize, never translate",
    "technical": "is a technical term — preserve exact spelling and capitalization",
    "acronym": "is an acronym — always uppercase",
    "custom": "is a custom term — preserve exact spelling",
}


def lnorm(s):
    return re.sub(r"[^a-z0-9]", "", s.lower())


def relevant_terms(text, entries):
    """Approximation of VocabularyManager.llmContextString(relevantTo:)."""
    words = re.findall(r"[A-Za-z0-9']+", text)
    grams = set()
    for n in (1, 2, 3):
        for i in range(len(words) - n + 1):
            g = lnorm("".join(words[i:i + n]))
            if len(g) >= 2:
                grams.add(g)
    out = []
    for e in entries:
        t = lnorm(e["term"])
        if t in grams or (len(t) >= 4 and any(
                len(g) >= 4 and abs(len(g) - len(t)) <= 2 and difflib.SequenceMatcher(a=g, b=t).ratio() >= 0.75
                for g in grams)):
            out.append(e)
    return out


def vocab_string(entries):
    return ". ".join(f"\"{e['term']}\" {CATEGORY[e['category']]}" for e in entries) + "." if entries else ""


def system_prompt(config, text, entries):
    if config == "plain":
        return BASE
    if config == "app":
        v = vocab_string(relevant_terms(text, entries))
        return BASE + (f"\n\nVocabulary guidance:\n{v}" if v else "")
    return BASE + "\n" + RICH_EXTRA + "\n\nVocabulary:\n" + "\n".join(
        f"- {e['term']} ({e['category']})" for e in entries)


def call(system, user, think):
    body = {"model": MODEL, "temperature": 0,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}]}
    if think:
        body["max_tokens"] = 6000
    else:
        body["reasoning_effort"] = "none"
        body["max_tokens"] = max(len(user) * 2, 512)
    req = urllib.request.Request(ENDPOINT, json.dumps(body).encode(), {"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=300) as r:
        resp = json.load(r)
    ms = int((time.time() - t0) * 1000)
    msg = resp["choices"][0]["message"]
    return (msg.get("content") or "").strip(), ms, resp["usage"]


# --- scoring (same normalisation as eval-runs/read/analyse.py) ---
def norm(t):
    t = t.lower().replace("’", "'")
    t = re.sub(r"(\d),(\d{3})", r"\1\2", t).replace("%", " percent")
    return [w.strip("'") for w in re.sub(r"[^a-z0-9' ]+", " ", t).split() if w.strip("'")]


def errs(r, h):
    sm = difflib.SequenceMatcher(a=r, b=h, autojunk=False)
    return sum(max(i2 - i1, j2 - j1) for tag, i1, i2, j1, j2 in sm.get_opcodes() if tag != "equal")


def guardrail(inp, out):
    a = re.findall(r"[a-z0-9]+", inp.lower())
    b = re.findall(r"[a-z0-9]+", out.lower())
    if not a or not b or not 0.5 <= len(b) / len(a) <= 1.6:
        return False
    sm = difflib.SequenceMatcher(a=a, b=b, autojunk=False)
    lcs = sum(m.size for m in sm.get_matching_blocks())
    return 2 * lcs / (len(a) + len(b)) >= 0.5


def term_hits(ref, hyp, entries):
    exp = hit = false = 0
    for e in entries:
        pat = r"(?<![A-Za-z0-9])" + re.escape(e["term"]) + r"(?![A-Za-z0-9])"
        nr, nh = len(re.findall(pat, ref)), len(re.findall(pat, hyp))
        exp += nr
        hit += min(nr, nh)
        false += max(0, nh - nr)
    return exp, hit, false


def breaks(t):
    return len(re.findall(r"[.!?](\s|$)", t))


def score(ref, hyp, entries):
    r, h = norm(ref), norm(hyp)
    exp, hit, false = term_hits(ref, hyp, entries)
    return {"refWords": len(r), "wordErrors": errs(r, h),
            "fmtTokens": len(ref.split()), "fmtErrors": errs(ref.split(), hyp.split()),
            "termsExpected": exp, "termsHit": hit, "termFalseFires": false,
            "extraBreaks": max(0, breaks(hyp) - breaks(ref))}


def main():
    run, vocab_path, config, out_path = sys.argv[1:5]
    entries = json.load(open(vocab_path))["entries"]
    clips = [c for c in json.load(open(run))["clips"] if c.get("outcome") == "decoded"]
    rows = []
    for c in clips:
        inp = c["final"]
        sysp = system_prompt(config, inp, entries)
        try:
            out, ms, usage = call(sysp, inp, config.endswith("think"))
        except Exception as ex:  # timeouts count as a failed cleanup
            out, ms, usage = "", -1, {"error": str(ex)}
        ok = bool(out) and guardrail(inp, out)
        final = out if ok else inp
        rows.append({"id": c["id"], "seconds": c["seconds"], "reference": c["reference"], "input": inp,
                     "llm": out, "accepted": ok, "final": final, "ms": ms, "usage": usage,
                     "base": score(c["reference"], inp, entries), "scored": score(c["reference"], final, entries)})
        print(f"{c['id']:28} {ms:6}ms {'ok ' if ok else 'REJ'} wer {rows[-1]['base']['wordErrors']}->{rows[-1]['scored']['wordErrors']}", flush=True)
    json.dump({"config": config, "model": MODEL, "rows": rows}, open(out_path, "w"), indent=1)


if __name__ == "__main__":
    main()
