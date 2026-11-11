# Research: French engine comparison

## Decision

Cohere Transcribe 2B (5-bit, MLX, through the already pinned speech-swift) is the recommended
local model on Macs with 16 GB of memory or more. It is loaded when a dictation starts and
released a minute after the last one, and it writes its own live preview. Parakeet v3 stays the
light model and the default below 16 GB. Whisper large-v3 turbo was measured and not kept.
Qwen3-ASR stays selectable but is no longer described as the best French model: it is not.

## Why look again

The usage ledger of the machine this was written on shows what the code could not: about 30
dictations a day of 18 s on average with a cloud model in September 2026, then one or two a day
of 10 s after switching to Parakeet v3. The Mac is in French and steering was active, so the
setting was right and the model was the limit.

## Method

Same path as the app (`TranscriptionBenchmark`: real engines, `AudioConditioner`, `SpeechGate`,
`TranscriptSanitizer`), signed release bundle, one pass per clip, French hint, Apple M5 Pro,
24 GB, macOS 27.2, on AC power, 2026-11-11. WER as in `transcription-benchmark.md`. Human
references only:

- **FLEURS `fr_fr` test**: 676 read sentences, 17,997 reference words.
- **mTEDx `fr` test** (`BrunoHays/multilingual-TEDX-fr`, CC-BY-NC-ND, evaluation only, never
  shipped): 10 talks. *Sentences*: the 798 segments of 2 s or more with at least 3 words
  (15,536 words). *Long*: 136 runs of consecutive segments spanning 18 to 45 s (11,797 words),
  the length of a real dictation and past Parakeet's 15 s window. Stage annotations in
  parentheses are removed from the references.

References write numbers and punctuation their own way, so absolute WER is pessimistic for
every engine alike; the comparison is what counts.

## Results

| Engine | FLEURS | Talks, sentences | Talks, 18–45 s | p50 / p95 on talks | Peak footprint |
| --- | ---: | ---: | ---: | ---: | ---: |
| Parakeet v3 (steered, as shipped) | 7.8% | 10.5% | 14.3% | 63 / 238 ms | 139 MB |
| Parakeet v3, long audio cut at pauses | | 10.4% | 13.6% | 60 / 273 ms | 76 MB |
| Qwen3-ASR 1.7B 4-bit | 8.2% | 10.8% | 16.3% | 211 / 1128 ms | 7,233 MB |
| Whisper large-v3 turbo (Core ML, native runtime) | | 9.5% | 8.4% | 442 / 1435 ms | 450 MB |
| **Cohere Transcribe 2B 5-bit** | **6.6%** | **7.5%** | **7.8%** | 126 / 688 ms | 2,812 MB |

The footprint excludes what the Neural Engine holds (Parakeet, Whisper).

What the numbers hide: Parakeet's errors are not spread evenly. On some sentences it drops half
the words or slides into English despite steering (« À la fin de sa journée, le robot renvoie
toutes ces observations vers la Terre via un satellite-relais » → « At sesion versus satellite
relais »). Those are the dictations a user remembers. Cohere produced no empty transcript on the
798 sentences; Parakeet produced 3.

## What was tried and not kept

- **Cutting long audio at pauses for Parakeet** (15 s windows, each decoded alone, instead of
  FluidAudio's overlapping chunks): 14.3% → 13.6% on long talks. Real, small, and each seam gets
  a full stop and a capital. The model is the ceiling, not the chunking.
- **Whisper large-v3 turbo**: light, but 3.5 times slower than Cohere and less accurate. The
  native runtime has no temperature fallback and stops at the second repetition of a word, which
  cuts ordinary French (« Vous vous demandez… » came back as « Vous vous »), and it repeats or
  skips clauses. Also cut long audio at pauses for it (28 s) rather than at exactly 30 s.
- **Qwen3-ASR 1.7B 4-bit**: behind Parakeet on all three sets at fifty times the memory. The
  4-bit quantization costs it most outside English and Chinese (speech-swift reports 11.4% for
  4-bit against 8.5% for 8-bit on FLEURS French).
- **Cohere through FluidAudio's Core ML build**: a 3 min Neural Engine compile in every new
  process and 1.5 to 3.3 s per call whatever the length (FluidAudio `Cohere.md`).

## Memory: nothing at rest

Loaded, the 5-bit weights hold about 1.9 GB; a decode peaks at 2.8 GB with MLX's buffer cache
capped at 256 MB (3.2 GB uncapped). That is too much to keep for a menu bar app, so:

- `prepare()` only checks that the files are on disk. A fresh download is loaded once, to fail
  early if it is broken.
- `wake()` at key-down loads the weights while the user speaks: 0.3 to 1.4 s measured, from
  disk, never the network.
- Each use rearms a 60 s timer; then the weights are released. Measured after release: 113 to 158 MB for the whole process.
- Dropping the model object does not free MLX memory. The module's arrays must be replaced by
  empty ones and `Memory.clearCache()` called; the footprint falls about two seconds later.

## Live preview

Cohere is not a streaming model, but it decodes 10 s of speech in about 140 ms, so the preview
decodes the audio so far again once a second. Past 18 s of undecided audio, the part before a
pause is decoded one last time and kept. Words that survive two decodes are confirmed, the rest
volatile. The final text still comes from one pass over the whole utterance.

Measured by playing clips to the session in real time (`MODICT_BENCH_PREVIEW=1`), 12 talk clips
of 3 to 42 s: first words after 1.1 s, an update every second (longest gap 1.14 s), and 30 of 647
final words differ from the last preview. On the 45 synthetic sentences, 18 of 446.

Without a gate the preview wrote words on 12 of 24 holds with no speech (« Merci. »,
« Sous-titrage Société Radio-Canada »). It now asks `SpeechGate` before its first decode: 0 of 24.

## Limits

- Cohere does not detect the language. Automatic means the Mac's language; dictating in another
  one requires choosing it in Settings › Dictation. Fourteen languages.
- No vocabulary prompt. Vocabulary rules still apply after transcription.
- TED talks are prepared speech into a good microphone. They are closer to dictation than
  conversation is, but nobody's real dictation was measured here.
- The first dictation after a pause of more than a minute waits for the load if it is shorter
  than the load itself (a one-word dictation: up to about a second longer).
- One decode in flight cannot be interrupted: the final pass can wait for the last preview
  decode, about 0.3 s with the 18 s bound.

## Reproduce

```sh
make sign
MODICT_BENCH_PASSES=1 scripts/bench.sh <manifest.json> cohere-transcribe-2b-5bit
MODICT_BENCH_PREVIEW=1 MODICT_BENCH_PASSES=1 scripts/bench.sh <manifest.json> cohere-transcribe-2b-5bit
```

The bench prints load and reload times and the footprint loaded, after decoding and unloaded.
