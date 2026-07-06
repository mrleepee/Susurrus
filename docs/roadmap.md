# Susurrus Roadmap

*Written 2026-07-06, after the accuracy pipeline landed (see
[accuracy-pipeline.md](accuracy-pipeline.md)).*

---

## Notebooks: keep, but understand what they are

A notebook is a named collection that your dictations get saved into. You
pick an "active" notebook, and everything you dictate lands there. That's
the whole idea.

### What notebooks are good at

- **They tell Susurrus what you're working on.** Dictate into a "MarkLogic
  migration" notebook and the names from your recent entries get fed to
  the speech model as hints. Your project's jargon gets recognised without
  you maintaining a vocabulary list.
- **They catch your fixes at the best moment.** Notebook mode opens the
  window right after you dictate. You fix mistakes while you still
  remember what you said, and every fix teaches Susurrus a rule.
- **They cost nothing when ignored.** No active notebook = no overhead.

### What notebooks are bad at

- **They need a habit.** All the value depends on you remembering to pick
  an active notebook. If you never do, notebooks do nothing.
- **Unfixed mistakes spread.** If Whisper writes a name wrong and you
  don't correct it, the wrong spelling sits in the notebook and gets fed
  back as a "hint".
- **The LLM context dump is weak.** Sending your last 10 entries to the
  LLM as prose was the notebook's original job. It's the least useful
  part, and it only works when the LLM is switched on.

### The verdict

Keep them — but stop *depending* on them. As of today, if you have no
active notebook, Susurrus gets the same context boost from your recent
dictation history automatically. Notebooks are now a bonus for people who
like organising, not a requirement for accuracy.

---

## Top 5 long-term improvements

Ranked. Number 1 matters most.

### 1. Context without asking

Susurrus should know what you're talking about without being told.
Today it looks at your active notebook, then your recent dictations.
Next: look at **where you're pasting**. Dictating into Xcode? Bias
toward code words. Into Slack? Names of your colleagues. The goal: delete
every setup step between "install app" and "it knows my words".

### 2. Effortless corrections

Right now, teaching Susurrus means opening History or a notebook and
editing text. Too much work. Instead:

- A "fix that" button (or hotkey) right after a dictation pastes.
- Highlight the words Whisper itself wasn't sure about, so you can see
  at a glance what to check.
- After you fix the same mistake twice, ask once: *"Always replace
  'core bee' with 'CoRB'?"* — one click, learned forever.

Every fix you make today saves ten fixes later. Making fixes cheap is
the highest-leverage accuracy work left.

### 3. Local LLM polish, on by default

The cleanup LLM is optional today because it needs setup (an API key or
LM Studio running). Long term: ship or auto-detect a small local model so
polish is free, private, and always on — with the existing guardrail so
it can never rewrite what you actually said. Nothing leaves the Mac.

### 4. Dictate longer than 60 seconds

The recording cap exists because Whisper decodes 30-second windows and
long audio needs careful chunking. Solve that properly (decode in chunks
while you keep talking) and Susurrus becomes usable for meetings, memos,
and thinking out loud — not just short bursts.

### 5. Your words on every Mac

Vocabulary, learned rules, and notebooks should follow you via iCloud.
Teach Susurrus a name on your desktop, and your laptop knows it too.
Without sync, every machine starts from zero — and the learning loop is
the product.

---

## Not on the list, on purpose

- **Voice commands** ("new line", "send it") — different product. Revisit
  after the top 5.
- **Speaker diarization** — Susurrus is for one voice: yours.
- **Cloud transcription** — never. On-device is the point.
