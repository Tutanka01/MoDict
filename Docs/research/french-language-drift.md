# Research: french-language-drift

## Summary

Parakeet-TDT 0.6B v3 transcrit souvent du français spontané **en anglais**, parfois
comme une traduction mot à mot. Exemple réel (podcast tech, audio 100 % français) :
« Et ces logiciels là, historiquement, pour des raisons de performance… » →
« These logic, historically, for reasons of performance history… ».

Le correctif livré est un **pilotage d'activation (activation steering) de l'encodeur**,
appliqué sans forker FluidAudio : un wrapper `MLModel` du réseau *joint* ajoute une
« direction française » fixe (1024 floats) à chaque trame d'encodeur qu'il lit. Toute
passe française (aperçu en direct compris) utilise une force douce (α = 1) ; une passe
qui contient encore des mots-outils anglais est redécodée à α = 2.

Sur un jeu de test **inédit** (7 vidéos, 506 énoncés, paramètres figés avant évaluation) :

| Configuration | Énoncés massivement anglais | Mots anglais intrus | WER |
| --- | ---: | ---: | ---: |
| Parakeet brut (`language: nil`) | 8,1 % | 5,86 % | 30,3 % |
| MoDict avant (`language: .french`, blocklist FluidAudio) | 4,3 % | 3,50 % | 28,8 % |
| **MoDict après (pilotage α=1 + redécodage α=2)** | **0,0 %** | **0,31 %** | **23,6 %** |

Français lu propre (FLEURS fr, 676 phrases, références humaines) : WER 7,91 % → 7,70 %.
Latence médiane inchangée (64 ms) : le redécodage ne concerne que 2,7 % des énoncés
(~+60 ms chacun). Les anglicismes légitimes (git, commit, merge, hotfix, meeting…) sont
conservés : leur rappel reste dans le bruit de mesure (67,5 % → 66,2 %, écart dû à la
graphie « big up » → « big-up »).

## Cause racine

- Parakeet v3 **n'a aucun conditionnement de langue** (pas de jeton `<|fr|>` comme Whisper
  ou Canary, pas de prompt comme Qwen3-ASR) : la langue est décidée implicitement par
  l'encodeur et le réseau de prédiction.
- Données d'entraînement (Sekoyan et al., arXiv 2509.14128) : sous-ensemble ASR de
  Canary-1B-v2, ~660 k h, dont ~40 % d'anglais, largement pseudo-étiquetées (Granary,
  pipeline Whisper). NVIDIA mentionne des hallucinations « héritées du pseudo-labelling
  Whisper » ; Whisper traduit lui-même vers l'anglais quand sa détection de langue échoue.
- Mécanisme observé en traçant les 64 meilleurs candidats du joint (voir « Expériences ») :
  aux points de bifurcation, la branche française est souvent **toute proche**
  (« log|ic » vs « log|ici » : 0,4 nat ; « These » vs « C(es) » : 1,2 nat). Une fois un
  token anglais émis, le LSTM de prédiction verrouille l'anglais et les continuations
  françaises tombent à −10/−15 nats, hors du top-64. Le blocklist FluidAudio (48 mots-outils,
  PR #630) ne remplace qu'un token isolé et n'agit que si une alternative est dans le top-64
  (l'auteur mesurait 31 % → 13,5 % sur son pire enregistrement).

## État de l'art examiné

- **Blocklist + filtre d'alphabet FluidAudio** (PR #630, `TokenLanguageFilter`) : déjà actif
  dans MoDict via `language: .french`. Insuffisant sur la traduction soutenue.
- **Language-Aware Token Boosting** (arXiv 2606.08994) et **Language Confusion Gate**
  (arXiv 2510.17555, Qwen) : biais/masques de logits, idéalement adaptatifs (n'intervenir
  qu'en cas de doute). Leur classification Unicode ne sépare pas français et anglais ;
  il faut une classification lexicale. LCG observe aussi que la norme des embeddings de sortie
  favorise les langues dominantes — même famille de biais que celui de Parakeet.
- **Shallow fusion unigramme / rapport de densités, recherche en faisceau + LM**
  (arXiv 2012.00133, NGPU-LM NeMo) : la voie « décodage » classique. Testée ici (voir plus bas),
  efficace mais complexe, et incapable de trouver une branche française quand l'encodeur
  « pense » déjà en anglais.
- **Modèles conditionnés par la langue** : Canary-1B-v2 (pas de build CoreML), Nemotron
  Streaming Multilingual 0.6B avec `prompt_id` (présent dans FluidAudio 0.15.7 mais sans dépôt
  HF, conversion CUDA à faire soi-même, WER FLEURS fr 9,4 % contre 5,2 % pour Parakeet v3),
  Qwen3-ASR (déjà dans MoDict, 2,3 Go).
- **Vecteurs de pilotage de langue** (arXiv 2602.02326, 2601.16390 ; SALSA 2606.00460 pour la
  parole côté LLM) : différence de moyennes d'activations entre langues, ajoutée à l'inférence.
  À notre connaissance jamais appliqué au joint d'un transducteur ASR ; c'est ce qui marche ici.

## Méthodologie d'évaluation

Banc d'essai Swift hors dépôt, lié à la même révision FluidAudio 0.15.7, qui reproduit le
pipeline MoDict (`AudioConditioner`, nouvel essai sur l'audio brut si vide) et remplace le
joint par un proxy `MLModel` configurable.

Corpus (audio public YouTube, segmenté aux pauses en énoncés de 3–14 s comme une dictée) :

- **train** (787 énoncés) : archives INA (météo enfants, argot 1981, parler picard,
  haltérophilie, phonographe 1912), interview et podcast tech, micro-trottoirs, vlogs.
  Sert uniquement à calculer le vecteur.
- **dev** (273) : tutoriel Git (anglicismes légitimes), podcast tech à forte dérive,
  conversation entre amis. Sert au réglage.
- **test** (517) : 7 vidéos jamais utilisées (débat politique, chef cuisinier, live Twitch,
  reconversion dev, data science, conversation YouTubeurs, monologue). Évaluation finale.
- **FLEURS fr** (676, références humaines) : non-régression sur du français lu.

Références = sous-titres automatiques YouTube alignés au mot (bruités : utile pour comparer
des configurations, pas pour un WER absolu). Les énoncés dont la référence a < 3 mots sont
exclus (musique, TV anglaise en fond).

Métriques : mot anglais intrus = mot 12× plus fréquent en anglais qu'en français
(fréquences OpenSubtitles) et absent de la référence ; « massivement anglais » = ≥ 3 intrus et
≥ 30 % des mots ; WER normalisé ; rappel des anglicismes présents dans la référence.

## Expériences (dev, 270 énoncés notés)

| Approche | Massivement anglais | Mots anglais | WER | Rappel anglicismes |
| --- | ---: | ---: | ---: | ---: |
| MoDict avant (blocklist FR) | 15,9 % | 9,83 % | 46,8 % | 70,9 % |
| Pénalité lexicale statique sur le top-64 (λ = 6) | 11,5 % | 6,07 % | 45,4 % | — |
| Faisceau 4 + a priori token et mots anglais (λ = 3, −3, bonus 1) | 1,9 % | 1,06 % | 42,8 % | 50,2 % |
| Faisceau 8 + a priori mots-outils/mots + porte | 0 % | 0,86 % | 43,3 % | 66,0 % |
| Pilotage seul α = 1,5 (glouton) | 1,1 % | 1,77 % | 38,3 % | 63,5 % |
| Pilotage seul α = 5 | 0 % | 0,13 % | 92,3 % | 3,0 % |
| Pilotage par la porte seule (α = 2) | 0 % | 0,99 % | 39,8 % | 70,0 % |
| **Retenu : α = 1 partout + redécodage α = 2** | **0 %** | **1,09 %** | **38,1 %** | 66,5 % |
| Retenu + faisceau 8 piloté en redécodage | 0 % | 1,08 % | 35,9 % | 65,5 % |

Enseignements :

1. **Pénaliser des tokens** ne suffit pas : en mode traduction, le top-64 ne contient souvent
   plus de français. Le glouton ne peut pas revenir en arrière.
2. **La recherche en faisceau** avec a priori (mots-outils anglais −6, mots anglais −1,
   pénalité provisoire remboursée si le mot continue, bonus d'insertion) trouve le français
   quand il existe, mais produit des sorties **vides** quand l'encodeur est déjà « anglais » ;
   sans bonus d'insertion elle supprime des mots (biais de longueur : WER 61 % sur le podcast
   le plus touché). Pénaliser tous les mots anglais abîme les anglicismes (git → « guit »,
   redesign → « redesigner ») : il faut viser les mots-outils.
3. **Le pilotage de l'encodeur** agit à la source : il supprime la dérive et **améliore** le
   WER. La zone utile est étroite : au-delà de α ≈ 3 les trames sortent de la distribution et
   le joint prédit du blanc (suppressions).
4. Un vecteur calculé en **contraste intra-énoncé** (trames françaises vs anglaises d'un même
   énoncé, 70 énoncés) est *moins* bon (WER 46,6 % à α = 2) : le contraste global capture aussi
   un « mode français » plus général, bénéfique.
5. La **porte** (redécoder seulement si la 1re passe contient un mot-outil anglais) protège les
   énoncés propres ; seuil 1 ≈ seuil 2, on garde 1 et on ignore les mots-outils pris dans un
   titre (« Game of Thrones », « The Voice »). Ajouter les mots anglais pleins à la porte
   dégrade le WER (38,9 %) et les anglicismes (62,6 %).
6. Règle d'acceptation du redécodage : « non vide et pas plus anglais » (≤) égale
   « toujours » et bat « strictement moins anglais ».

## Solution livrée

- `Sources/MoDict/Core/Transcription/FrenchSteering.swift`
  - `FrenchSteering.direction` : 1024 floats (base64, norme 0,17 contre ~0,89 pour une trame
    de parole), `baselineStrength = 1`, `driftStrength = 2`.
  - `SteeredJointModel` : sous-classe de `MLModel` qui enveloppe `JointDecisionv3` et ajoute
    `α × direction` à `encoder_step` (copie : FluidAudio réutilise son tampon). FluidAudio
    n'appelle que `prediction(from:options:)` sur le joint, donc batch, fenêtres longues et
    aperçu glissant sont tous pilotés. Une entrée inattendue passe telle quelle.
  - `EnglishDriftDetector` : 268 mots-outils et contractions anglais, homographes français
    exclus (a, as, on, me, or, but, off, must, go, back…), titres ignorés.
- `FluidAudioEngine` : trois `AsrManager` partageant les mêmes modèles (brut, français α = 1,
  redécodage α = 2) ; `language == .french` choisit la voie pilotée ; l'aperçu en direct
  français charge les modèles pilotés.
- Aucune dépendance, aucun téléchargement, aucune donnée sous licence tierce livrée.

## Limites connues

- En mode Français, une **phrase entièrement anglaise** (citation) est francisée ; c'était déjà
  partiellement le cas avec le blocklist. Pour dicter en anglais, choisir Anglais ou Automatique.
- Il reste des mots anglais isolés **cognats** (« developers », « memory », « security ») quand
  aucun mot-outil ne déclenche le redécodage.
- Le vecteur est propre à l'espace de sortie de l'encodeur Parakeet v3 int8
  (`Encoder.mlmodelc`). Une nouvelle version d'encodeur demande de le recalculer.
- En Automatique sur un Mac réglé en anglais, `language` vaut nil : aucun pilotage.
- Qwen3-ASR (prompt de langue) et les modèles OpenRouter ne sont pas concernés ; avec Qwen
  actif, seul l'aperçu Parakeet en bénéficie.

## Pistes non retenues

- Redécodage par faisceau 8 piloté (+ a priori de mots) : WER dev 38,1 → 35,9 %, mais ~500
  lignes de décodeur TDT maison (≤ 15 s seulement) à maintenir en parallèle de FluidAudio.
- Table de pénalités lexicales dans le proxy : WER 38,1 → 37,5 % sur dev, 23,6 → 23,5 % sur
  test, mais dérivée de listes de fréquences CC-BY-SA.
- Vecteur appris par gradient (SALSA) : demanderait le modèle NeMo en PyTorch.
- Vecteurs pour d'autres langues (de, es, it…) : même procédure, non mesurée.

## Reproduire le vecteur

1. Construire un corpus de français spontané où Parakeet dérive (plusieurs centaines
   d'énoncés de 3–14 s), conditionnés par `AudioConditioner`.
2. Décoder en glouton (équivalent FluidAudio, `language: nil`) en conservant l'index de trame
   d'encodeur de chaque token émis.
3. Classer les tokens de début de mot par dominance log(P_en/P_fr) calculée en segmentant des
   listes de fréquences de mots avec le vocabulaire Parakeet : > 2,5 anglais, < −2,5 français.
4. `direction = moyenne(trames françaises) − moyenne(trames anglaises)` (ici 8 466 et 1 036
   tokens), sans normalisation ; régler α sur un jeu séparé, valider sur un jeu inédit et FLEURS.

## Sources

- Sekoyan et al., *Canary-1B-v2 & Parakeet-TDT-0.6B-v3*, arXiv 2509.14128
- FluidAudio PR #630 (blocklist français), `Documentation/ASR/TokenLanguageFilter.md`,
  `Documentation/ASR/NemotronMultilingual.md` (0.15.7)
- Thoth, « Parakeet translates French audio » (2026-05-19), mesures de dérive INA
- Ukarapol et al., *Language-Aware Token Boosting*, arXiv 2606.08994
- Zhang et al., *Language Confusion Gate*, arXiv 2510.17555
- *Language Steering for Multilingual In-Context Learning*, arXiv 2602.02326 ;
  *Cross-Lingual Activation Steering*, arXiv 2601.16390 ; SALSA, arXiv 2606.00460
- *Improving accuracy of rare words for RNN-T through unigram shallow fusion*, arXiv 2012.00133
- FLEURS (google/fleurs), OpenSubtitles word frequencies (hermitdave/FrequencyWords,
  utilisées seulement pour l'évaluation et le calcul du vecteur, non livrées)
