#!/bin/bash
# Runs the hidden benchmark mode of the signed bundle and prints its summaries. Build
# first with `make sign`. See Docs/research/transcription-benchmark.md.
# usage: scripts/bench.sh <manifest.json> [model] [results.jsonl]
set -euo pipefail

manifest="${1:?usage: scripts/bench.sh <manifest.json> [model] [results.jsonl]}"
model="${2:-parakeet-v3}"
results="${3:-${manifest%.json}.results.jsonl}"
binary="build/MoDict.app/Contents/MacOS/MoDict"
[ -x "$binary" ] || { echo "error: $binary not found - run 'make sign' first." >&2; exit 2; }

MODICT_BENCH_MANIFEST="$manifest" MODICT_BENCH_MODEL="$model" MODICT_BENCH_OUT="$results" "$binary"

jq -r 'select(.kind == "summary")
  | [.group, .clips, (.wer_percent // "-"), "\(.edits)/\(.ref_words)", .term_recall, .false_insertions,
     "\(.no_speech_with_text)/\(.no_speech_clips)", .speech_clips_rejected_by_gate,
     (.p50_ms // "-"), (.p95_ms // "-"), (.max_ms // "-"), .peak_footprint_mb] | @tsv' "$results" \
  | { printf 'group\tclips\tWER%%\tedits\tterms\tfalse\tsilent_text\tgate_lost\tp50\tp95\tmax\tpeak_MB\n'; cat; } \
  | column -t -s "$(printf '\t')"
echo "details: $results (holds transcripts: delete it when done)"
