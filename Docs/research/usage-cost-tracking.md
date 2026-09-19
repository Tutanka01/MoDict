# Research: usage-cost-tracking

## Summary

Objectif : suivre l'usage et le coût des dictées (cloud surtout) — coût de la dernière
dictée, total cumulé, agrégats par modèle — et l'afficher dans le popover du menu bar,
sous l'historique, avec une petite « mémoire » persistante. Rien ne doit être implémenté
avant validation de ce document.

Verdict : faisable **sans nouvelle dépendance et sans nouvel appel réseau obligatoire**.
La réponse du endpoint STT d'OpenRouter contient déjà `usage.cost` (USD) et
`usage.seconds`/tokens — il suffit de la décoder (aujourd'hui le code ne lit que `text`).
Le stockage recommandé est un **journal JSON Lines append-only** dans Application
Support, lu et agrégé en mémoire par un petit actor ; SQLite, SwiftData, GRDB et
UserDefaults sont écartés (détails plus bas). Côté UI, la section « Usage » du popover
est directe ; afficher un montant **dans l'icône du menu bar** est possible mais repose
sur le label `MenuBarExtra`, dont le cache est buggé (FB11857447) — à faire en **opt-in,
phase 2**, ou via NSStatusItem si la fiabilité devient un critère.

## Recommendations

### 1. Source du coût : `usage` de la réponse, rien d'autre

**Reco:** décoder le champ `usage` de la réponse STT :
`{ seconds, input_tokens, output_tokens, cost }`, où `cost` est le montant réellement
facturé en USD pour cette requête. Le schéma OpenAPI le marque *optional* → prévoir
l'absence. Garder `X-Generation-Id` (header de réponse) comme piste d'audit via
`GET /api/v1/generation?id=` (non nécessaire en v1).

**Pourquoi:**
- C'est le coût exact, par requête, déjà présent dans la réponse — zéro appel en plus,
  zéro latence, aucune clé supplémentaire à demander à l'utilisateur.
- `GET /api/v1/credits` est **compte entier** et exige une **clé management** → inutilisable
  avec la clé d'inférence de l'utilisateur.
- `GET /api/v1/key` est *key-scoped* (`usage_daily/weekly/monthly`) mais ne couvre que le
  jour/semaine/mois en cours, pas d'historique, et mélange toutes les apps qui utilisent
  la même clé. Utile seulement en réconciliation optionnelle, jamais comme source première.
- `GET /api/v1/activity` / `analytics/query` existent mais exigent aussi une clé
  management → à ne jamais embarquer dans un client macOS.
- Pour les modèles locaux : le coût est **0 $** (aucune API). On enregistre quand même
  l'événement (durée audio, temps de traitement, compteur) pour les statistiques
  « modèle utilisé », sans colonne coût.

**Fallback** (si `usage` absent malgré un 200) : enregistrer la dictée avec `cost = nil`
et l'afficher « — ». Une table de prix connus des 3 modèles cloud peut servir
d'estimation facultative, mais elle dérive avec le temps : ne pas en faire la source de
verité. Prix relevés le 2026-09-19 (à revérifier via `/api/v1/models` avant tout usage) :
`microsoft/mai-transcribe-2` ≈ 0,10 $/h d'audio, `meta/muse-voice-transcribe-1.0` et
`openai/gpt-transcribe` facturés à la seconde (0,00005 $/s et 0,000075 $/s).

### 2. Capture de l'info sans casser l'architecture

**Reco:** étendre `TranscriptionResult` (contrat gelé, `Docs/ARCHITECTURE.md`) avec un
champ optionnel `usage: TranscriptionUsage?` et une initialisation explicite **avec
valeur par défaut** (`usage: TranscriptionUsage? = nil`) pour que les 3 moteurs et les
tests existants continuent de compiler sans modification. `OpenRouterEngine` le remplit ;
`DictationController` écrit l'enregistrement d'usage quand une dictée cloud se termine.

**Pourquoi:**
- Le contrôleur est déjà l'unique propriétaire du flux (`finishTranscription`,
  `failTranscription`) — un seul point d'écriture, ordre garanti, aucun couplage de
  l'engine au stockage.
- Une requête cloud **facturée** peut produire un texte vide après sanitizer/vocabulaire
  (chemin « Didn't catch that. ») ou une insertion échouée : dans tous ces cas l'appel a
  bien été payé → l'enregistrement d'usage doit se faire **à la réception d'un 200**,
  indépendamment du succès de l'insertion. Ne rien enregistrer sur erreur/timeout
  (les échecs upstream ne sont pas facturés — « failed generations are not billed »,
  Zero Completion Insurance).
- Piège à documenter : un timeout client peut laisser une requête se terminer côté
  serveur et être facturée — légère sous-estimation possible, réconciliation
  optionnelle avec `GET /api/v1/key`.

### 3. Stockage : journal JSONL + snapshot en mémoire

**Reco:** `~/Library/Application Support/MoDict/Usage/ledger.jsonl` — une ligne JSON par
dictée terminée, écriture *append* + `fsync` par un `actor UsageLedger`, agrégats
(`UsageSnapshot`) recalculés en une passe au lancement puis mis à jour de façon
incrémentale. Fichiers en `0o600`, dossier en `0o700`.

**Pourquoi (vs alternatives) :**
- JSON unique `Codable` + `.atomic` : O(N) par dictée. Mesuré : ~230 ms (encodage +
  décodage) et ~10 Mo écrits **par dictée** sur un historique de 5 ans ; un tableau JSON
  est de plus tout-ou-rien (1 corruption = tout l'historique perdu).
- UserDefaults : API Apple le déconseille pour des données qui grossissent (fichier
  plist non chiffré, écritures asynchrones, pas de mise à jour partielle).
- SQLite système (`import SQLite3`, vérifié : dispo dans le SDK, **zéro dépendance
  SwiftPM**) : excellent mais 200–400 lignes de wrapper C et ses pièges
  (`SQLITE_TRANSIENT`, `Int32` vs `Int64`…) pour 3 requêtes d'agrégat. Échappatoire
  documentée si le fichier dépasse ~100 k lignes (~20 Mo) — la migration est un simple
  import des lignes, schéma inchangé.
- GRDB : 4ᵉ dépendance pinnée à auditer → non. SwiftData : store opaque, init qui peut
  échouer, `ModelContainer` à câbler dans un MenuBarExtra ; Core Data ne compile même pas
  en SwiftPM sans `.xcodeproj`. À ce volume, aucun des deux n'apporte rien.
- JSONL : append ~1–2 ms (fsync inclus, mesuré), lecteur tolérant ligne par ligne,
  ~200 octets/ligne (~4 Mo/an à 50 dictées/jour), testable par URL injectée.
  Pattern éprouvé (ccusage agrége des coûts depuis des JSONL locaux).

### 4. Schéma d'un enregistrement

```swift
struct UsageRecord: Codable, Sendable, Equatable {
    var schemaVersion = 1
    var date: Date              // ISO8601
    var day: String             // "2026-09-19", jour LOCAL au moment de l'écriture
    var modelID: String         // SpeechModel.rawValue (déjà stable)
    var isCloud: Bool
    var audioSeconds: Double
    var processingSeconds: Double
    var inputTokens: Int?
    var outputTokens: Int?
    var costUSD: Decimal?       // nil = local, ou coût indisponible
}
```

- `init(from:)` custom avec `decodeIfPresent` pour **tous** les champs additifs : sinon
  ajouter un champ casse la lecture des anciennes lignes.
- `day` figé à l'écriture : les sommes « du jour » ne bougent pas si l'utilisateur change
  de fuseau.
- Aucun texte de transcription dans le ledger (l'historique reste en mémoire, par
  confidentialité) — uniquement des métriques.
- `Decimal` (ou micro-USD entiers) pour l'argent, jamais `Double` pour les sommes.

### 5. UI popover : section « Usage » sous l'historique

**Reco:** entre `historySection` et le `Divider` du footer de `MenuBarView`, une section
du même vocabulaire visuel que « Recent » : en-tête 11 pt medium secondaire, lignes
12–13 pt, montants alignés à droite en `monospacedDigit()`, devise ISO (USD) — une seule
fois dans l'en-tête. Contenu : `Today`, `Total`, puis jusqu'à 3 lignes par modèle (nom
tronqué au milieu). Section **masquée si `total == 0`** (esprit « Invisible until
needed »). Le détail complet et un éventuel « Reset » iraient en Settings, pas dans un
popover de 300 pt (progressive disclosure).

**Pourquoi:** c'est exactement l'emplacement demandé (« en bas de l'historique »), le
budget 300 pt le permet (3 lignes + total ≈ 70 pt), et le style reste sobre/sans fond.

### 6. Icône du menu bar : opt-in, phase 2

**Reco:** par défaut, **l'icône reste seule**. Un toggle dans Settings → General
(off par défaut) peut afficher le coût du **jour** à côté du `waveform` — pas le total
cumulé (il grandit sans fin et devient large). Si l'affichage temps réel devient un
critère, la voie fiable est `NSStatusItem` + `button.title` en police à chasse fixe
(~60–80 lignes AppKit) ; la voie rapide est `MenuBarExtra` + label
`HStack { Image(systemName:) ; Text(...) }`.

**Pourquoi (prudence) :**
- Le label de `MenuBarExtra` est un snapshot mis en cache : les changements peuvent
  rester invisibles jusqu'au survol (FB11857447) ; gel documenté après réveil ;
  styles/couleurs ignorés ; largeur instable (jitter d'une zone entière de la barre).
  Acceptable pour un compteur « au meilleur effort » mis à jour lors des dictées, pas
  pour un affichage garanti.
- HIG : icône + préférence utilisateur ; l'espace est rare (notch : les items en trop
  disparaissent en silence). Un montant permanent est aussi une fuite visuelle en
  partage d'écran.
- `MenuBarExtra("$1.24", systemImage:)` ne marche pas : le titre de cet init est réservé
  à l'accessibilité, il faut la closure `label:`.
- Sur macOS 26, une app MenuBarExtra-only dont l'extra est masqué peut ne plus se lancer ;
  si on migre un jour vers NSStatusItem, prévoir un fallback d'entrée.

### 7. Formatage des montants

**Reco:** `Decimal` + `FormatStyle.Currency(code: "USD")` (code ISO, jamais de symbole en
dur), avec **arrondis adaptatifs** : 2 décimales ≥ 1 $, 3 en dessous de 0,01 $, 4 en
dessous, et `< $0.0001` pour les valeurs plus petites encore. Jamais `$0.00` pour un
montant strictement positif.

**Pourquoi:** une dictée de 15 s coûte ~0,0004–0,0011 $ selon le modèle ; les dashboards
LLM affichent couramment 4 décimales. `monospacedDigit()` évite les sauts de largeur.

### 8. Ce qu'on peut dire du « local »

Les modèles locaux (Parakeet, Qwen) ne coûtent **rien** en API : le ledger enregistre le
compteur, la durée audio et le temps de traitement (et le modèle), ce qui permet des
stats du type « 123 dictées locales · 2 h 14 transcrites · temps moyen 0,4 s ». Une
estimation « coût équivalent cloud » est possible avec la table de prix, mais à afficher
comme estimation ailleurs (Settings), pas dans le popover — c'est une fiction, pas une
dépense.

## Code notes

Implémentation livrée (fichiers et points d'accroche réels) :

- **Nouveau** `Sources/MoDict/Core/UsageLedger.swift` [core] — `UsageRecord`,
  `UsageSnapshot`, `actor UsageLedger(fileURL:)` (`load()`, `record(_:)`,
  `snapshot()`), agrégats en mémoire.
- **Nouveau** `Sources/MoDict/Core/UsageStore.swift` (ou dans `AppModel`) [menubar] —
  `@MainActor ObservableObject` qui possède le ledger, publie le snapshot, expose
  `refresh()` ; lu par `MenuBarView`.
- `Core/Transcription/TranscriptionEngine.swift` [stt] — ajouter `TranscriptionUsage`
  et le champ optionnel de `TranscriptionResult` (init explicite avec défaut `nil`).
- `Core/Transcription/OpenRouterEngine.swift` [stt] — décoder `usage`
  (`{"text": ..., "usage": {...}}`), remplir `TranscriptionResult.usage` sur 200 ;
  lire `X-Generation-Id` si on veut l'audit plus tard.
- `Core/DictationController.swift` [core] — après un 200 cloud : construire le
  `UsageRecord` (modèle capturé **avant** l'appel, pas relu après) et l'écrire dans le
  ledger — y compris quand le texte final est vide ou l'insertion échoue.
- `UI/MenuBar/MenuBarView.swift` [menubar] — `MenuBar.UsageSection` + positionnement
  sous l'historique ; `App/MoDictApp.swift` — label conditionnel (phase 2, toggle).
- `Core/SettingsStore.swift` + `UI/Settings/SettingsView.swift` — toggle
  « Show cloud spend in the menu bar » (off par défaut), éventuel onglet/section Usage
  avec reset.
- Tests (Swift Testing, CI uniquement côté exécution) :
  `Tests/MoDictTests/UsageLedgerTests.swift` — round-trip, lecteur tolérant (ligne
  tronquée/illisible/ancienne version), agrégats (jour/total/par modèle, `cost == nil`),
  concurrence (N écritures sérialisées par l'actor) ; et l'extension des tests
  `OpenRouterEngineTests` pour le décodage de `usage` (présent/absent).

Squelette de décodage côté moteur :

```swift
private struct Response: Decodable {
    let text: String
    let usage: Usage?
    struct Usage: Decodable {
        let seconds: Double?
        let inputTokens: Int?
        let outputTokens: Int?
        let cost: Decimal?
    }
}
```

Écriture (l'`await` est à la frontière de l'actor, jamais à l'intérieur) :

```swift
func record(_ record: UsageRecord) throws {
    var data = try encoder.encode(record)
    data.append(0x0A)
    if fileExists { handle.seekToEnd(); handle.write(data); handle.synchronize() }
    else { try data.write(to: fileURL, options: .atomic) }
    records.append(record)
}
```

## Pitfalls

- **`usage` est optionnel** dans le schéma OpenAPI : ne jamais forcer son décodage ;
  afficher « — » si absent.
- **Ne pas déduire le prix de `pricing.prompt`** de `/api/v1/models` pour ces modèles :
  le champ est documenté « par token » mais contient en réalité un prix par seconde ou
  par heure selon le modèle, sans unité dans l'API.
- **Ne pas utiliser `/credits`** (clé management + compte entier) ni promettre un
  « solde restant » par clé d'inférence.
- **Coût et succès d'insertion sont découplés** : une réponse 200 est facturée même si
  le texte est vide après sanitizer ou si le collage échoue.
- **Timeouts** : requête possiblement facturée côté serveur après abandon client —
  sous-estimation marginale, assumée ou réconciliée via `GET /api/v1/key`.
- **Icône menu bar** : ne pas compter sur `MenuBarExtra` pour un compteur fiable
  (cache, gel après réveil, attributs ignorés) ; jitter de largeur si chiffres non
  tabulaires.
- **Micro-copie** : phrases en anglais, calmes, sans « ! » (DESIGN.md) ; montants en USD.
- **Ne pas écrire dans `HistoryStore`** ni y ajouter de la persistance : la séparation
  « historique en mémoire (texte) / ledger sur disque (métriques) » est le point de
  confidentialité du design.
- **Attribution** : ne pas toucher à README/Settings → About.

## Décisions retenues (implémentées le 2026-09-19)

1. Barre de menus : icône seule par défaut ; `Settings → Usage → Menu bar` propose
   *Icon only* / *Today's spend* / *Total spend*. Le badge est masqué quand il n'y a rien
   à montrer (pas de `$0`).
2. Détail : section `Usage` dans le popover (Today / Total / modèles cloud payants, 3 max)
   + onglet **Usage** dans Settings (par modèle avec compteurs, durée audio, coût, reset,
   révélation du fichier). Pas d'export.
3. Modèles locaux : comptés (`N dictations`, durée audio) et affichés `Free` — pas
   d'estimation « coût équivalent cloud ».
4. Aucune réconciliation réseau : `usage.cost` de la réponse OpenRouter est la source
   unique ; aucune requête `/key` ni `/credits`.

## Sources

- OpenRouter — [STT guide](https://openrouter.ai/docs/guides/overview/multimodal/stt.md) ·
  [create-transcription OpenAPI](https://openrouter.ai/docs/api/api-reference/stt/create-transcription.md) ·
  [generation metadata](https://openrouter.ai/docs/api/api-reference/generations/get-request-&-usage-metadata-for-a-generation.md) ·
  [get current key](https://openrouter.ai/docs/api/api-reference/api-keys/get-current-api-key.md) ·
  [credits](https://openrouter.ai/docs/api/api-reference/credits/get-remaining-credits.md) ·
  [activity](https://openrouter.ai/docs/api/api-reference/analytics/get-user-activity-grouped-by-endpoint.md) ·
  [limits](https://openrouter.ai/docs/api_reference/limits.md) ·
  [zero completion insurance](https://openrouter.ai/docs/guides/features/zero-completion-insurance.md) ·
  pages modèles : [mai-transcribe-2](https://openrouter.ai/microsoft/mai-transcribe-2) ·
  [muse-voice-transcribe-1.0](https://openrouter.ai/meta/muse-voice-transcribe-1.0) ·
  [gpt-transcribe](https://openrouter.ai/openai/gpt-transcribe)
- Apple — [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra) ·
  [MenuBarExtraStyle.window](https://developer.apple.com/documentation/swiftui/menubarextrastyle/window) ·
  [NSStatusBar](https://developer.apple.com/documentation/AppKit/NSStatusBar) ·
  [currency FormatStyle](https://developer.apple.com/documentation/foundation/formatstyle/currency(code:)-6fhr2) ·
  HIG [The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar) ·
  [UserDefaults](https://developer.apple.com/documentation/foundation/userdefaults) ·
  [isExcludedFromBackupKey](https://developer.apple.com/documentation/foundation/urlresourcekey/isexcludedfrombackupkey)
- Bugs connu — [FB11857447 / FB13683941](https://github.com/feedback-assistant/reports/issues/474)
- Migrations NSStatusItem — [DevWatchdog 3b27824](https://github.com/Kanevry/DevWatchdog/commit/3b27824e94c6e589fcd882e82309f49eedc172cb) ·
  [ClaudeBar #211](https://github.com/tddworks/ClaudeBar/pull/211) ·
  [MenuBarExtraAccess](https://github.com/orchetect/MenuBarExtraAccess) ·
  [Multi.app — NSStatusItem limits](https://multi.app/blog/pushing-the-limits-nsstatusitem)
- Stockage — [ccusage](https://github.com/ryoppippi/ccusage) ·
  [VoiceInk](https://github.com/Beingpax/VoiceInk) · [Maccy](https://github.com/p0deje/Maccy) ·
  [swift-toolchain-sqlite (SQLite système)](https://forums.swift.org/t/announcing-swift-toolchain-sqlite/73745) ·
  [GRDB](https://github.com/groue/grdb.swift)
- Prior art coûts — [Tokens4Breakfast](https://github.com/onekapisch/Tokens4Breakfast-daily) ·
  [CodexBar](https://github.com/anirudhvee/CodexBar) · [TokenBar](https://github.com/saphid/TokenBar) ·
  [opencode-bar](https://github.com/cpiprint/opencode-bar)
