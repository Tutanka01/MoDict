#!/bin/bash
# Writes a synthetic benchmark corpus with `say`: French sentences and holds with no
# speech. Never touches the microphone. See Docs/research/transcription-benchmark.md.
# usage: scripts/bench-fixtures.sh <outdir>
set -euo pipefail

out="${1:?usage: scripts/bench-fixtures.sh <outdir>}"
mkdir -p "$out/clips"

sentences=(
  "Envoie le compte rendu à toute l'équipe avant vendredi."
  "Je pense qu'on devrait déplacer la réunion à demain matin."
  "Peux-tu vérifier si le déploiement est bien terminé ?"
  "Le client nous a demandé une nouvelle version du contrat."
  "Il faut corriger ce bug avant la prochaine mise en production."
  "Merci pour ton aide, c'était vraiment très utile."
  "J'ai relu le document et tout me semble correct."
  "Nous allons présenter les résultats au comité de direction jeudi."
  "Ajoute une section sur les performances dans le rapport final."
  "Est-ce que tu peux m'envoyer le lien du dépôt ?"
  "Ce modèle tourne entièrement sur la machine, sans connexion."
  "La livraison est prévue pour la fin du mois prochain."
  "Je te rappelle dès que je sors de ma réunion."
  "Le budget a été validé par la direction hier soir."
  "Finalement, on garde la première option, d'accord ?"
)
voices=("Thomas (Français (France))" "Flo (Français (France))" "Eddy (Français (France))")

python_escape() { jq -Rn --arg s "$1" '$s'; }

clips=""
add_clip() { clips+="${clips:+,}$1"; }

i=0
for sentence in "${sentences[@]}"; do
  i=$((i + 1))
  for voice in "${voices[@]}"; do
    name="$(printf 's%02d-%s' "$i" "${voice%% *}")"
    say -v "$voice" -o "$out/clips/$name.wav" --data-format=LEI16@16000 "$sentence"
    add_clip "{\"id\":\"$name\",\"audio\":\"clips/$name.wav\",\"expected\":$(python_escape "$sentence"),\"group\":\"sentences\"}"
  done
done

# Holds with no speech: digital silence, white noise, and the start cue in noise.
/usr/bin/python3 -I - "$out/clips" <<'PY'
import math, random, struct, sys, wave
out = sys.argv[1]
def write(name, samples):
    with wave.open(f"{out}/{name}.wav", "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
        w.writeframes(b"".join(struct.pack("<h", max(-32768, min(32767, int(s * 32767)))) for s in samples))
random.seed(7)
for seconds in (0.5, 1, 2, 4):
    n = int(seconds * 16000)
    write(f"zero-{seconds}s", [0.0] * n)
    for db in (-60, -50, -40, -30):
        a = 10 ** (db / 20)
        write(f"noise{db}-{seconds}s", [random.gauss(0, a) for _ in range(n)])
    # A short decaying 2.6 kHz cue over a -60 dBFS room, standing in for the chime.
    a = 10 ** (-60 / 20)
    write(f"cue-{seconds}s", [random.gauss(0, a) + 0.02 * math.exp(-i / 800) * math.sin(2 * math.pi * 2600 * i / 16000) for i in range(n)])
PY
for f in "$out"/clips/zero-*.wav "$out"/clips/noise*.wav "$out"/clips/cue-*.wav; do
  name="$(basename "$f" .wav)"
  add_clip "{\"id\":\"$name\",\"audio\":\"clips/$name.wav\",\"group\":\"no-speech\",\"expect_speech\":false}"
done

printf '{"language":"fr","clips":[%s]}\n' "$clips" | jq . > "$out/manifest.json"
echo "wrote $(jq '.clips | length' "$out/manifest.json") clips to $out/manifest.json"
