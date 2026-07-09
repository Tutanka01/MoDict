# MoDict - QA pre-prod P1

Checklist de sortie pour une build pre-prod. Elle complete le test manuel court de
`CONTRIBUTING.md`; ici le but est de casser l'app volontairement avant distribution.

## Regle de sortie P1

Une build P1 est **bloquee** si un seul point ci-dessous echoue:

- l'app ne se lance pas depuis un vrai bundle `build/MoDict.app`;
- une permission TCC n'apparait pas, ne se demande pas, ou se perd avec une signature stable;
- le modele pret/non pret ne produit pas un etat utilisateur clair;
- la touche droite `Cmd` demarre mal, reste bloquee, casse les raccourcis `Cmd+C`/`Cmd+V`, ou Esc ne permet pas d'annuler pendant l'enregistrement;
- une insertion reussie ne restaure pas le presse-papiers quand l'option est active;
- un champ securise recoit du texte, ou la transcription est perdue au lieu d'aller dans l'historique;
- un changement de micro/AirPods, un sleep/wake ou une permission retiree crash l'app;
- une donnee sensible de dictee est ecrite sur disque ou envoyee hors du telechargement modele attendu.

## Artefacts locaux

Commandes existantes du repo:

```sh
swift --version
security find-identity -v -p codesigning
./scripts/dev-cert.sh
make clean
make
make run
make universal
make sign IDENTITY=-
make diagnose-signature
make validate-release
make developer-id IDENTITY="Developer ID Application: <name> (<TEAMID>)"
make notarize NOTARY_PROFILE=<notarytool-profile>
make sign IDENTITY="Developer ID Application: <name> (<TEAMID>)"
lipo -info build/MoDict.app/Contents/MacOS/MoDict
codesign --verify --strict --verbose=2 build/MoDict.app
codesign -d --entitlements :- build/MoDict.app
codesign -dv --verbose=4 build/MoDict.app
spctl --assess --type execute --verbose=4 build/MoDict.app
```

Chemins a connaitre:

- bundle QA: `build/MoDict.app`;
- bundle id TCC/UserDefaults: `com.modict.app`;
- entitlements: `Support/MoDict.entitlements`;
- cache modele FluidAudio v3: `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3`;
- preferences: `~/Library/Preferences/com.modict.app.plist`.

## Preparation machine QA

Sur une machine dediee, quitter MoDict puis repartir proprement:

```sh
pkill -x MoDict || true
defaults delete com.modict.app 2>/dev/null || true
tccutil reset Microphone com.modict.app
tccutil reset Accessibility com.modict.app
tccutil reset ListenEvent com.modict.app
```

Pour retester le premier telechargement modele, supprimer seulement le dossier v3
ci-dessous, pas tout `FluidAudio/Models` si d'autres apps FluidAudio existent:

```sh
rm -rf "$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3"
```

Avant chaque run, enregistrer l'environnement:

```sh
sw_vers
uname -m
swift --version
security find-identity -v -p codesigning
```

## Build et signature

### Signature stable dev

- [ ] `./scripts/dev-cert.sh` cree ou detecte l'identite `MoDict Dev`.
- [ ] `security find-identity -v -p codesigning` liste `MoDict Dev`.
- [ ] `make clean && make` construit et signe sans warning de fallback ad-hoc.
- [ ] `codesign --verify --strict --verbose=2 build/MoDict.app` passe.
- [ ] `codesign -dv --verbose=4 build/MoDict.app` affiche `Identifier=com.modict.app`,
  `Runtime Version` et une authority liee a `MoDict Dev`.
- [ ] `codesign -d --entitlements :- build/MoDict.app` contient
  `com.apple.security.device.audio-input` et `com.apple.security.device.microphone`;
  il ne contient pas `com.apple.security.app-sandbox`.
- [ ] Accorder Microphone, Accessibility et Input Monitoring une fois, relancer
  `make && make run`: les trois autorisations restent accordees.

### Signature ad-hoc

- [ ] `make clean && make sign IDENTITY=-` affiche explicitement `DEV/CI ONLY`.
- [ ] `codesign --verify --strict --verbose=2 build/MoDict.app` passe.
- [ ] `make diagnose-signature` passe avec warnings ad-hoc/Gatekeeper attendus.
- [ ] `make validate-release` echoue en refusant l'ad-hoc, sans produire une fausse
  validation pre-prod.
- [ ] Apres un rebuild ad-hoc, macOS peut redemander les TCC. C'est acceptable
  uniquement pour CI/dev ponctuel, jamais comme critere UX pre-prod.
- [ ] La build ad-hoc n'est pas vendue comme stable pour permissions persistantes.

### Developer ID / distribution

- [ ] `make clean && make developer-id IDENTITY="Developer ID Application: <name> (<TEAMID>)"` passe.
- [ ] `codesign -dv --verbose=4 build/MoDict.app` affiche `TeamIdentifier=<TEAMID>`.
- [ ] `make validate-release` passe sur la build Developer ID.
- [ ] `make notarize NOTARY_PROFILE=<profile>` soumet, attend, staple, puis
  `make validate-notarized-release` passe.
- [ ] `spctl --assess --type execute --verbose=4 build/MoDict.app` passe pour une
  build notariee/staplee; si l'artefact pre-prod n'est pas notarise, le rapport QA
  le dit explicitement.
- [ ] Si un zip/release est teste, verifier la quarantaine et le comportement Gatekeeper:

  ```sh
  xattr -l build/MoDict.app
  xattr -dr com.apple.quarantine build/MoDict.app
  ```

## TCC permissions

### Microphone

- [ ] Etat frais: l'onboarding montre la demande Microphone avant le premier essai.
- [ ] Le bouton `Allow microphone` declenche le prompt systeme.
- [ ] Refus: l'etape reste actionable, propose Settings, et aucune dictee ne demarre.
- [ ] Autorisation: l'etape passe en granted et auto-avance apres un court feedback visuel.
- [ ] Retrait depuis System Settings pendant que l'app tourne: prochaine dictee affiche
  `Microphone access needed` ou `Microphone unavailable`, sans modal bloquante et sans crash.

### Accessibility

- [ ] Etat frais: l'onboarding explique que l'autorisation sert a inserer dans l'app cible.
- [ ] Le bouton ouvre `Privacy_Accessibility`; l'app apparait dans la liste.
- [ ] Sans Accessibility mais avec transcription reussie: rien n'est tape dans l'app cible,
  le texte va dans l'historique, et le HUD demande `Grant Accessibility to insert text`.
- [ ] Une fois accordee, l'insertion par `Cmd+V` fonctionne dans les apps de la matrice.

### Input Monitoring

- [ ] Etat frais: l'onboarding explique que l'autorisation sert a detecter la touche droite `Cmd`.
- [ ] Le bouton ouvre `Privacy_ListenEvent`; l'app apparait dans Input Monitoring.
- [ ] Sans Input Monitoring, l'app ne voit pas la touche droite `Cmd`; elle reste recuperable
  par Settings/onboarding, sans faux etat `Ready`.
- [ ] Apres accord et relance si macOS le demande, la touche droite `Cmd` declenche la dictee.

## Onboarding

- [ ] Reset: `defaults delete com.modict.app` et resets TCC ci-dessus, puis `make run`.
- [ ] Fenetre onboarding: 5 etapes, taille stable, pas de Dock permanent apres fermeture.
- [ ] Welcome: le message annonce le flux reel `hold right Cmd, speak, release`.
- [ ] Microphone: demande systeme, refus puis re-autorisation testees.
- [ ] Keyboard access: Accessibility et Input Monitoring sont deux cartes separees, avec
  statut qui se met a jour sans redemarrage inutile.
- [ ] Speech model sans cache: bouton `Download model`, progression checking/downloading/
  compiling, erreur retry si reseau coupe, pas de dictee possible tant que non pret.
- [ ] Speech model avec cache deja present: l'etape verifie/charge puis auto-avance.
- [ ] Try it: le `TextEditor` recoit une vraie dictee, `onboardingCompleted=true`, puis
  l'app revient en menu-bar accessory.
- [ ] Reouverture apres onboarding termine et permissions presentes: pas d'onboarding.
- [ ] Reouverture apres retrait d'une permission ou suppression du modele: onboarding
  revient sur le chemin de remediation.

## Modele pret / non pret

- [ ] Cache absent: menu bar indique preparation/download et Settings > Model indique
  `Not downloaded` ou progression.
- [ ] Appuyer sur droite `Cmd` avant `ready`: HUD `Model not ready yet`, aucun enregistrement,
  aucun presse-papiers modifie.
- [ ] Telechargement interrompu: etat `Model download failed`, bouton Retry dans menu bar
  ou Settings, pas de crash.
- [ ] Retry avec reseau restaure: progression reprend et finit en `Ready`.
- [ ] Cache present: lancement suivant ne retélécharge pas, passe par checking/ready.
- [ ] Settings > Model > Reveal in Finder ouvre le dossier modele v3.

## Insertion dans apps courantes

Phrase QA recommandee, non sauvegardee dans un document: `qa preprod modict clipboard sentinel`.

Pour chaque app cible:

- [ ] placer le curseur dans une zone editable deja remplie;
- [ ] mettre au presse-papiers un contenu temoin avant la dictee;
- [ ] dicter la phrase QA;
- [ ] verifier insertion au curseur, pas en fin de document, pas dans MoDict;
- [ ] verifier que le presse-papiers temoin revient apres ~0,25 s quand `Restore clipboard
  after insert` est active;
- [ ] verifier que la derniere dictee apparait dans l'historique menu bar, max 5 elements.

Matrice minimale:

- [ ] TextEdit document texte simple.
- [ ] TextEdit document riche avec texte colore ou lien copie avant dictee.
- [ ] Notes.
- [ ] Mail ou Messages.
- [ ] Safari: champ de recherche, textarea web, champ contenteditable.
- [ ] Chrome ou Arc: champ de recherche, textarea web, champ contenteditable.
- [ ] VS Code ou autre app Electron.
- [ ] Terminal/iTerm dans un shell normal.
- [ ] Slack/Discord/Teams si disponible sur la machine QA.

Cas longs:

- [ ] dictee courte > 0,35 s: inseree.
- [ ] tap accidentel < 0,35 s: rien n'est insere, HUD disparait silencieusement.
- [ ] phrase multi-lignes ou ponctuee: pas de troncature visible.
- [ ] cible non editable: texte non perdu, historique utilisable pour copier.

## Secure Input

- [ ] Champ mot de passe natif ou navigateur: la dictee ne tape rien dans le champ.
- [ ] Terminal > Secure Keyboard Entry active: la dictee ne tape rien dans Terminal.
- [ ] HUD affiche l'etat champ securise (`Secure field - copied to history instead`).
- [ ] Le texte transcrit est present dans l'historique menu bar et copiable.
- [ ] Esc, `Cmd+C`, `Cmd+V` de l'app cible ne sont pas casses apres le test.
- [ ] Desactiver Secure Keyboard Entry: la dictee fonctionne de nouveau sans relancer MoDict.

## Hotkey modes

Tester depuis Settings > General > Activation. Entre les modes, attendre > 0,4 s pour
eviter le cooldown.

### Hold

- [ ] Maintenir droite `Cmd`: HUD visible au key-down, waveform active.
- [ ] Relacher: transcription puis insertion.
- [ ] Tap bref: rien n'est insere.
- [ ] Gauche `Cmd`: ne demarre jamais MoDict.
- [ ] Droite `Cmd` + `C` dans la premiere seconde: annule MoDict et laisse `Cmd+C` passer.

### Toggle

- [ ] Premier tap droite `Cmd`: demarre l'enregistrement mains libres.
- [ ] Deuxieme tap droite `Cmd`: stoppe, transcrit, insere.
- [ ] `Cmd+C`/`Cmd+V` ordinaires restent utilisables quand MoDict n'enregistre pas.
- [ ] Changement de mode pendant l'app ouverte prend effet sans relance.

### Hybrid

- [ ] Maintien >= 0,5 s: comportement push-to-talk.
- [ ] Tap < 0,5 s: passe en mains libres; tap suivant stoppe.
- [ ] Maintien puis touche non-modificatrice dans la fenetre combo: MoDict annule et ne
  vole pas le raccourci.
- [ ] Declenchements rapides repetes: pas de double insertion ni HUD bloque.

## Annulation Esc

- [ ] Pendant un enregistrement Hold: Esc annule, rien n'est insere, rien n'est ajoute a
  l'historique, et Esc n'atteint pas l'app cible.
- [ ] Pendant un enregistrement Toggle/Hybrid mains libres: Esc annule de la meme maniere.
- [ ] Apres annulation, une nouvelle dictee fonctionne sans relancer.
- [ ] Esc hors enregistrement reste le comportement normal de l'app cible.

## Microphones, devices, AirPods

- [ ] Settings > Dictation liste `System default` et les entrees micro disponibles.
- [ ] Micro systeme par defaut: happy path OK.
- [ ] Micro selectionne explicitement: happy path OK.
- [ ] Deconnecter le micro selectionne: Settings garde `Unavailable device`, la dictee
  affiche une erreur micro claire et ne retombe pas silencieusement sur un autre input.
- [ ] Brancher AirPods avant lancement: capture OK, niveau HUD non bloque a zero.
- [ ] Brancher ou basculer vers AirPods pendant une utterance: pas de crash, pas de tap
  audio bloque, prochaine dictee OK.
- [ ] Revenir au micro interne pendant que MoDict tourne: prochaine dictee OK.
- [ ] Aucun micro disponible: HUD `Microphone unavailable`, pas de crash.

Commandes utiles:

```sh
system_profiler SPAudioDataType
```

## Sleep / wake

- [ ] App prete, permissions accordees, modele pret.
- [ ] Lancer une dictee, l'annuler proprement, puis mettre en veille:

  ```sh
  pmset sleepnow
  ```

- [ ] Au reveil: pas de HUD reste visible, pas d'enregistrement fantome.
- [ ] Droite `Cmd` fonctionne dans les 10 s apres wake.
- [ ] AirPods reconnectes apres wake: prochaine dictee OK.
- [ ] Apres sleep/wake avec l'app cible en plein ecran: HUD apparait sur le bon Space,
  n'active pas MoDict, insertion va dans l'app cible.
- [ ] Apres changement reseau pendant sleep: pas de nouveau telechargement si modele pret.

## Clipboard restore

Avec `Restore clipboard after insert` active:

- [ ] Texte simple: `printf 'clipboard-before' | pbcopy`, dictee, puis `pbpaste` retourne
  `clipboard-before`.
- [ ] Texte riche/lien depuis TextEdit ou navigateur: apres dictee, coller dans TextEdit
  conserve le contenu riche original, pas la phrase dictee.
- [ ] Fichier copie depuis Finder: apres dictee, coller dans Finder ou un dossier conserve
  le fichier copie original.
- [ ] Copier autre chose pendant la fenetre de paste/restauration: MoDict ne remplace pas
  le nouveau presse-papiers utilisateur.

Avec `Restore clipboard after insert` desactive:

- [ ] La dictee reste dans le presse-papiers apres insertion.
- [ ] Les marqueurs transitoires n'apparaissent pas dans les gestionnaires de presse-papiers
  comme une entree utilisateur durable.

## Non-regression confidentialite

- [ ] Aucune connexion reseau en usage normal lorsque le modele est deja pret:

  ```sh
  lsof -i -n -P -c MoDict
  ```

- [ ] Pendant premier telechargement, la seule activite reseau attendue est le modele
  FluidAudio/Hugging Face. Aucune telemetrie, aucun compte, aucun endpoint produit.
- [ ] L'historique est memoire seulement: faire 5 dictees, quitter MoDict, relancer,
  l'historique est vide.
- [ ] Preferences sans phrase dictee:

  ```sh
  defaults read com.modict.app
  ```

- [ ] Recherche disque avec une phrase QA unique non sauvegardee dans un document:

  ```sh
  rg -n "qa preprod modict clipboard sentinel" \
    "$HOME/Library/Application Support" \
    "$HOME/Library/Preferences" \
    "$HOME/Library/Logs" 2>/dev/null
  ```

  Resultat attendu: aucune occurrence hors artefacts explicitement crees par le testeur.

- [ ] Le presse-papiers est restaure apres insertion si l'option est active; la phrase dictee
  ne reste pas dans `pbpaste`.
- [ ] Aucun fichier audio brut, wav, m4a ou transcription persistante n'est cree par MoDict
  hors cache modele FluidAudio.

## Rapport QA

Coller ce bloc dans le ticket/release candidate:

```md
Build:
- commit:
- macOS:
- machine:
- signature: stable dev / ad-hoc / Developer ID
- notarisation: oui / non / n/a
- modele: cache present / premier download

Commandes passees:
- swift --version:
- make:
- codesign:
- lipo:
- spctl:

Matrice P1:
- TCC:
- onboarding:
- model ready/non-ready:
- insertion apps:
- secure input:
- hotkey modes:
- Esc:
- micro/AirPods:
- sleep/wake:
- clipboard restore:
- privacy:

Blockers:
- aucun / liste

Notes:
- 
```
