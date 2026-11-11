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
jq -rs 'map(select(.kind == "preview")) | select(length > 0)
  | (map(select(.expect_speech))) as $speech | (map(select(.expect_speech | not))) as $silent
  | "preview: \($speech | length) speech clips, first update after \(($speech | map(.first_update_ms // 0) | add) / ([$speech | length, 1] | max) | floor) ms on average, longest gap \($speech | map(.longest_gap_ms) | max // 0) ms, \($speech | map(.edits_to_final) | add // 0) of \($speech | map(.final_words) | add // 0) final words differ from the last preview; \($silent | map(select(.last_preview != "")) | length)/\($silent | length) no-speech clips showed words"' "$results"
jq -r 'select(.kind == "load")
  | "load \(.load_ms) ms, reload \(.reload_ms) ms; footprint MB: loaded \(.loaded_mb), after decodes \(.after_decodes_mb), unloaded \(.unloaded_mb)"' "$results"
echo "details: $results (holds transcripts: delete it when done)"
