# Research: dual-decode arbitration on long dictation

## Decision

`ASRConfig.dualDecodeArbitration` stays off (the FluidAudio default). The rule was fixed before
any decoding: turn it off if, on real French, WER without it is no worse by more than 0.3 point. It
lowers WER by 2.5 points and cuts the median latency to about a third.

## Method

FLEURS `fr_fr` test split: all 676 recordings, 332 sentences, 117 distinct minutes, human
references. Long clips of 20 to 90 s built by concatenating recordings with no added silence: 901
clips, 584.5 minutes, 89,805 reference words. MoDict's French path: `AudioConditioner`,
`language: .french`, steering strength 1, without the drift re-decode. Mode order alternated between
clips. FluidAudio 0.15.7, Parakeet v3, Apple M5 Pro, 2026-10-31, with builds running on the
machine, so timings are noisy.

## Results

| Length | Clips | WER on | WER off | Off − on (95% CI) | Off better / worse | Median ms on / off |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 20 s | 317 | 12.62 | 11.64 | −0.98 [−1.63, −0.43] | 17 / 2 | 271 / 117 |
| 30 s | 233 | 13.75 | 12.35 | −1.40 [−2.07, −0.80] | 30 / 7 | 503 / 159 |
| 45 s | 155 | 14.70 | 11.89 | −2.80 [−3.87, −1.84] | 40 / 2 | 702 / 176 |
| 60 s | 118 | 14.34 | 11.46 | −2.88 [−4.02, −1.81] | 36 / 6 | 757 / 222 |
| 90 s | 78 | 16.33 | 11.76 | −4.57 [−5.91, −3.32] | 49 / 1 | 920 / 357 |
| **All** | **901** | **14.35** | **11.82** | **−2.53 [−2.98, −2.11]** | **172 / 18** | **530 / 164** |

Block bootstrap over recordings, the more cautious interval since lengths share them: [−3.06, −2.05].
The loss with arbitration is content: 82,969 words written with it, 85,572 without, whole passages
dropped. Two robustness variants agree: file order (16.80 vs 13.90, 905 clips) and edge silences
trimmed to 30 ms (25.41 vs 18.77, 706 clips). Rerunning 40 clips in another process and order gave
identical text.

## Limits

Read speech joined across speakers, not continuous dictation, and recordings keep about 1.7 s of edge
silence at the joins. The mechanism was not established: the chosen strategy is not logged. The raw
results were in a temporary folder and are gone; this table is the record.

## Still open

Turning it off does not end content loss at chunk seams. Without arbitration, 106 of 901 clips still
lose over 15% of their words, 208 of 706 with trimmed silences (WER 18.77%), so speech with no
pauses over 15 s remains a weak spot of the v3 long-form path. Worth checking on the FluidAudio
release in use before raising that pin, with `transcription-benchmark.md`.
