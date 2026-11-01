# Research: transcription benchmark

How to measure a change to capture, conditioning, the speech gate or an engine before
shipping it. The method follows Hex's (`anomalyco/hex`, MIT): a manifest, repeated passes,
JSONL output, and gates fixed in advance.

## Run it

```sh
make sign                                    # the mode runs inside the signed bundle
scripts/bench-fixtures.sh /tmp/modict-bench  # synthetic corpus, never the microphone
scripts/bench.sh /tmp/modict-bench/manifest.json parakeet-v3
```

`MODICT_BENCH_MANIFEST` makes the app binary score the manifest and exit before any app
state, UI, permission or instance lock exists. It uses the real engine, `SpeechGate` and
`TranscriptSanitizer`. It never uses a cloud model or the microphone, and never downloads a
speech model. `MODICT_BENCH_OUT`, `MODICT_BENCH_MODEL` and `MODICT_BENCH_PASSES` (default 3)
complete it. The first decode is a warm-up and excluded.

MoDict writes no transcript to disk in normal use. This mode writes them only to the output
path a developer asks for: delete the file when done, and never put real recordings or
results in the repository.

```json
{"language": "fr", "vocabulary": ["MoDict"], "clips": [
  {"id": "x", "audio": "x.wav", "expected": "…", "expected_terms": ["MoDict"],
   "group": "dictation", "expect_speech": true}]}
```

**WER:** lowercase, no punctuation, apostrophes and hyphens split, accents kept, Levenshtein
over words, total edits over total reference words. **False insertion:** a listed term written
where `expected` lacks it. **`silent_text`:** clips with `expect_speech: false` that produced
text. **`gate_lost`:** speech clips the gate refused.

## Corpus rules

- Never derive a reference from a model's output. Transcribe by hand, or use a dataset's.
- Synthetic `say` speech overestimates quality and has regular pauses: it can show a
  regression, not prove a win. A claim about quality needs real speech (FLEURS `fr_fr` for
  read speech, the spontaneous set in `french-language-drift.md`).
- Record the machine, power state, build and date beside each result, and alternate the order
  of what is compared. Differences under about 1.5 points on FLEURS-sized sets are ties.

## Gates

A change that touches the path from the microphone to the text must not, on the same corpus:

| Measure | Limit |
| --- | --- |
| WER | +0.3 point |
| False insertions | 0.5% of clips |
| p95 on a 10 s clip | +20 ms |
| `silent_text` | any increase |
| `gate_lost` | any increase |

## Baseline

2026-11-01, Apple M5 Pro, macOS 27.0.1, on AC power, signed release bundle, Parakeet v3,
French hint, three passes per clip. **Synthetic corpus**: 15 sentences by 3 `say` voices, plus
24 holds without speech (digital silence, white noise −60 to −30 dBFS, a synthesized cue in
noise) of 0.5 to 4 s. No microphone, no real speech.

| Group | Clips | WER | `silent_text` | `gate_lost` | p50 | p95 | Peak footprint |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Sentences | 45 | 2.9% (13/444) | | 0 | 51 ms | 57 ms | 51 MB |
| No speech | 24 | | 0/24 | | | | 51 MB |

The footprint does not include what the Neural Engine holds.

## Findings behind the current code

Measured 2026-10-31 on the same Mac, with the same engine code unless noted.

**Holds without speech.** Before the gate, 58 of 208 produced text (`Yeah.`, `C'est…`,
`Okay.`), 34 of 40 with the real Tink chime mixed in at −34 dB. Silero stayed at or below 0.367
on all of them, so the threshold is 0.4, the same as Hex's. It reached 1.0 on 96 of 96
synthetic speech clips, 48 of them attenuated by 30 dB.

**Level threshold.** −60 dBFS, not Hex's −50: 18 of 676 FLEURS `fr_fr` recordings (419 reference
words) have a loudest window between −50 and −53 dBFS, and Silero and both local engines still
hear them. At −60, none of the 676 is refused.

**Release tail.** Word errors per offset of the end of the buffer from the end of speech, over 474
words of synthetic French: 32 at −200 ms, 31 at −150, 22 at −100 and −50, 21 at 0 and +200. Clips kept their
closing punctuation in 335 of 336 runs, so Hex's added trailing silence does not apply to v3. On
real voices Hex keeps the last word 7 in 10 times at −100 ms and 2 in 10 at −200 ms.

**Paste key.** ⌘ + key 9 types `k` on Dvorak and `c` on Turkish. Of the 264 system layouts, 259 have
`v` at 9, 2 at 8 (Turkish), 1 at 47 (Dvorak), 1 at 43 (Dvorak Right), 1 has none in its Command
layer (Turkmen).
