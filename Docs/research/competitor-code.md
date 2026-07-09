# Research: competitor-code

## Summary
VoiceInk (Beingpax/VoiceInk, GPL-3.0, Swift/AppKit) est l'app open source la plus proche de MoDict et confirme la faisabilité complète du design MoDict. Son architecture sépare : (1) un orchestrateur `VoiceInkEngine` (@MainActor ObservableObject) qui expose `@Published recordingState: RecordingState` (enum : idle/starting/recording/transcribing/enhancing/busy) ; (2) une capture audio bas niveau `CoreAudioRecorder` (AUHAL/AudioUnit, 16 kHz mono Int16) avec callback `onAudioChunk` ; (3) des services de transcription enfichables dont FluidAudio/Parakeet ET whisper.cpp ; (4) un panneau flottant en deux styles (`MiniRecorderPanel`, une sous-classe de `NSPanel`, et `NotchRecorderPanel`) ; (5) un monitor de raccourci global `ShortcutMonitor` basé sur **CGEventTap** ; (6) un injecteur de texte `CursorPaster` (CGEvent Cmd+V + sauvegarde/restauration du presse-papier). Point crucial pour MoDict : la touche Commande droite seule (push-to-talk modifier-only) est impossible avec la librairie KeyboardShortcuts de Sindre Sorhus — VoiceInk a donc écrit son propre CGEventTap qui écoute les évènements `.flagsChanged` et distingue gauche/droite par le keyCode (kVK_RightCommand = 0x36 vs kVK_Command = 0x37). L'affichage au-dessus des apps fullscreen repose sur `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` + un window level élevé (`.floating` ou `.statusBar + 3`) + `.nonactivatingPanel` pour ne pas voler le focus de l'app cible (indispensable pour que Cmd+V arrive au bon endroit). FluidAudio s'intègre via SPM (FluidInference/FluidAudio) avec l'API `AsrManager` + `AsrModels.downloadAndLoad(version:)` + `transcribe([Float])` sur l'ANE. La robustesse repose sur du suivi par UUID (activeRecordingStartID / activePipelineTranscriptionID) pour ignorer les callbacks obsolètes, un cooldown de 0,5 s, l'annulation via un flag `shouldCancelRecording` + set d'IDs annulés, et une gate audio thread-safe (OSAllocatedUnfairLock). Licence : on n'apprend QUE les patterns et les APIs Apple (non copyrightables), jamais le code GPL.</summary>
<recommendations>
<recommendation>
<topic>Hotkey Commande droite push-to-talk (LE point le plus critique)</topic>
<recommendation>Pour MoDict, écrire un monitor CGEventTap maison exactement comme le `ShortcutMonitor` de VoiceInk. NE PAS utiliser la librairie KeyboardShortcuts (Sindre Sorhus) : elle exige une touche non-modificatrice et ne peut pas capturer "Commande droite seule". Créer le tap avec `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask(keyDown|keyUp|flagsChanged), callback:, userInfo:)`, l'ajouter à la runloop, et détecter la touche via les évènements `.flagsChanged`. Distinguer Commande droite (kVK_RightCommand = 0x36) de Commande gauche (kVK_Command = 0x37) par le keyCode de l'évènement flagsChanged. Dériver keyDown (le flag apparait) / keyUp (le flag disparait) pour le push-to-talk. Ajouter un cooldown (~0,5 s) et une détection "interrompu par une autre touche".</recommendation>
<rationale>Le déclencheur central de MoDict est un modifier seul (Cmd droite). CGEventTap est la seule API système fiable pour ça et VoiceInk le prouve en production. Bonus : le même tap permet d'implémenter l'annulation par Échap (keyCode 0x35) pendant l'enregistrement.</rationale>
</recommendation>
<recommendation>
<topic>Panneau flottant au-dessus de TOUT (y compris fullscreen)</topic>
<recommendation>Utiliser une sous-classe de `NSPanel` avec : `styleMask = [.nonactivatingPanel, .fullSizeContentView]`, `level = .floating` (ou `.statusBar + N` pour coller à la notch), `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` (ajouter `.stationary, .ignoresCycle` pour la variante notch), `isFloatingPanel = true`, `hidesOnDeactivate = false`, `backgroundColor = .clear`, `isOpaque = false`, `hasShadow = false`, et override `canBecomeKey/canBecomeMain`. Héberger la vue SwiftUI via `NSHostingController` (`panel.contentView = hostingController.view`). Positionner via une méthode statique de calcul (centré horizontalement, ~24 pt sous le haut de l'écran).</recommendation>
<rationale>`.fullScreenAuxiliary` + `.canJoinAllSpaces` est précisément ce qui fait apparaître le panneau au-dessus des apps plein écran. `.nonactivatingPanel` est vital : le panneau ne prend jamais le focus, donc l'app cible reste frontmost et reçoit bien le Cmd+V au collage.</rationale>
</recommendation>
<recommendation>
<topic>Injection de texte au curseur (paste universel)</topic>
<recommendation>Reproduire le pattern `CursorPaster` : (1) snapshot du presse-papier via `NSPasteboard.general.pasteboardItems` ; (2) écrire le texte transcrit dans le presse-papier ; (3) attendre ~0,10 s (prePasteDelay) ; (4) synthétiser Cmd+V avec quatre `CGEvent(keyboardEventSource:virtualKey:keyDown:)` — cmd down (0x37), v down (0x09), v up, cmd up — chacun avec `.flags = .maskCommand`, postés sur `.cghidEventTap` avec ~0,01 s entre chaque ; (5) restaurer le presse-papier après ~0,25 s. Vérifier `AXIsProcessTrusted()` avant. Prévoir une option de repli AppleScript (`PasteMethod.appleScript`) comme VoiceInk pour les apps récalcitrantes.</recommendation>
<rationale>Le collage via CGEvent Cmd+V marche dans n'importe quelle app sans dépendre de l'API Accessibilité pour l'insertion (juste la permission). Le snapshot/restore du presse-papier évite d'écraser le contenu de l'utilisateur. Le délai de restauration >0,2 s évite de restaurer avant que le paste ait été lu par l'app cible.</rationale>
</recommendation>
<recommendation>
<topic>Intégration FluidAudio/Parakeet (STT on-device)</topic>
<recommendation>Ajouter la dépendance SPM `https://github.com/FluidInference/FluidAudio.git` (produit `FluidAudio`). Flux offline (idéal pour push-to-talk record-puis-transcrit) : `let models = try await AsrModels.downloadAndLoad(version: .v3)` (v3 = multilingue incl. 25 langues EU+JP ; v2 = anglais, meilleur recall), puis `let asr = AsrManager(config: .default); try await asr.loadModels(models)`, puis `let result = try await asr.transcribe(samples); result.text`. Entrée = `[Float]` 16 kHz mono. Pour un décodage incrémental, réutiliser un `TdtDecoderState` passé en `inout` entre appels (`TdtDecoderState.make(decoderLayers:)`). Optionnel : VAD via `VadManager(config:).segmentSpeechAudio([Float])`. Charger les modèles paresseusement (`ensureModelsLoaded()`) et dédupliquer les chargements concurrents via un Task partagé.</recommendation>
<rationale>C'est exactement la stack STT visée par MoDict, tourne sur l'Apple Neural Engine (~190x realtime sur M4 Pro), et l'API est stable. FluidAudio est sous licence permissive (Apache/MIT) donc liable même dans un projet à licence différente, contrairement au code GPL de VoiceInk.</rationale>
</recommendation>
<recommendation>
<topic>Format de capture audio</topic>
<recommendation>Cibler directement 16 kHz mono Float32 pour FluidAudio. Deux options : (a) simple et suffisant pour MoDict — `AVAudioEngine` + `inputNode.installTap(onBus:0, bufferSize:, format:)` puis `AVAudioConverter` vers un `AVAudioFormat` 16 kHz mono ; livrer des `[Float]` normalisés ±1.0. (b) approche VoiceInk (plus complexe) — AUHAL/AudioUnit direct pour capturer sans changer le périphérique système par défaut, ring buffer temps-réel (callback render sans allocation) puis conversion/mixage mono + resampling sur une file `.userInitiated`. Écrire aussi un WAV temporaire si besoin de rejouer/déboguer (VoiceInk saute l'en-tête de 44 octets à la relecture).</recommendation>
<rationale>Parakeet exige du 16 kHz mono. AVAudioEngine suffit largement pour une v1 de MoDict et est bien plus simple que l'AUHAL de VoiceInk ; garder AUHAL en tête seulement si on veut éviter tout impact sur le device par défaut ou une latence minimale.</rationale>
</recommendation>
<recommendation>
<topic>Machine à états et robustesse de bout en bout</topic>
<recommendation>Modéliser un enum `RecordingState { idle, starting, recording, transcribing, busy }` exposé en `@Published`. Suivre chaque enregistrement par un UUID (`activeRecordingStartID`) et chaque pipeline par un `activePipelineTranscriptionID` pour ignorer les callbacks obsolètes en cas de re-déclenchement rapide / double appui. Annulation (Échap) : un flag `shouldCancelRecording` + un set d'IDs annulés (`canceledPipelineTranscriptionIDs`) qu'une closure `shouldCancel` consulte dans la boucle de transcription. Cooldown ~0,5 s entre déclenchements. Bufferiser les chunks audio dans une gate thread-safe (`OSAllocatedUnfairLock`, capacité max bornée) tant que le service n'est pas prêt. Sur erreur : reset à `.idle`, masquer le panneau, supprimer le fichier temporaire.</rationale>
<rationale>Ces mécanismes (UUID anti-stale, flag d'annulation, cooldown) sont ce qui donne à VoiceInk une sensation "produit commercial" et évitent les bugs classiques du push-to-talk : double appui, relâchement pendant la transcription, spam de la touche.</rationale>
</recommendation>
<recommendation>
<topic>App accessory + permissions</topic>
<recommendation>App menu-bar-only : `NSApp.setActivationPolicy(.accessory)` (basculer `.regular` seulement quand on ouvre les réglages), `NSStatusItem` via `NSStatusBar.system.statusItem(withLength:)`, `applicationShouldTerminateAfterLastWindowClosed` → false. Demander deux permissions au premier lancement : Accessibilité (`AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`) — nécessaire À LA FOIS pour le CGEventTap du hotkey ET pour le paste CGEvent — et Microphone (`AVCaptureDevice.requestAccess(for: .audio)`). Sur macOS récent, le CGEventTap déclenche aussi la permission "Surveillance des entrées / Input Monitoring".</recommendation>
<rationale>MoDict a besoin des mêmes permissions ; les regrouper dans un onboarding évite l'écueil n°1 des apps de dictée (tap silencieusement désactivé faute de permission). setActivationPolicy(.accessory) donne le comportement menu-bar attendu.</rationale>
</recommendation>
<recommendation>
<topic>Licence GPL — ce qu'on apprend vs ce qu'on ne copie pas</topic>
<recommendation>Traiter VoiceInk comme une référence de PATTERNS uniquement. Sont réutilisables librement (APIs Apple non copyrightables) : la config NSPanel over-fullscreen, le schéma CGEventTap pour modifier-only, la séquence CGEvent Cmd+V + save/restore presse-papier, les appels FluidAudio, la capture 16 kHz, setActivationPolicy. NE PAS recopier : la structure de classes spécifique de VoiceInk, `NotchShape`, `WordAgreementEngine`, l'implémentation de `RealtimeAudioChunkGate`, leur abstraction de pipeline, ou tout bloc de code littéral. Réécrire chaque composant from scratch à partir de la compréhension des APIs.</recommendation>
<rationale>MoDict reste sain juridiquement s'il n'emprunte que les idées architecturales et les appels système standard, jamais l'expression concrète du code GPL-3.0.</rationale>
</recommendation>
</recommendations>
<code_notes>
DÉPÔT: github.com/Beingpax/VoiceInk (GPL-3.0, Swift/AppKit, macOS 14.4+, construit via .xcodeproj + SPM — pas SwiftPM pur). Dépendances SPM (repositoryURL exacts extraits de project.pbxproj):
- https://github.com/FluidInference/FluidAudio.git  (Parakeet ASR)
- https://github.com/apple/swift-atomics.git        (ManagedAtomic dans le recorder temps-réel)
- https://github.com/sparkle-project/Sparkle        (auto-update, min 2.6.4)
- https://github.com/sindresorhus/LaunchAtLogin-Modern
- https://github.com/marmelroy/Zip                  (décompression de modèles)
- https://github.com/gonzalezreal/swift-markdown-ui
- https://github.com/Beingpax/LLMkit.git            (post-traitement LLM, optionnel pour MoDict)
- https://github.com/Beingpax/SelectedTextKit.git   (lit le texte sélectionné pour contexte)
- https://github.com/Beingpax/mediaremote-adapter   (met en pause le média pendant l'enregistrement)
IMPORTANT: PAS de librairie KeyboardShortcuts — hotkey 100% maison via CGEventTap. whisper.cpp est vendu en C (LibWhisper.swift, pont C, whisper.xcframework), pas via SPM.

=== HOTKEY / PUSH-TO-TALK (ShortcutMonitor.swift + Shortcut.swift) ===
Création du tap:
  CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                    eventsOfInterest: eventMask /* keyDown|keyUp|flagsChanged */,
                    callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
Extraction des flags dans le callback:
  NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
Modèle Shortcut:
  struct Shortcut: Codable, Equatable {
      enum Kind: String, Codable { case key; case modifierOnly }
      let kind: Kind
      let keyCode: UInt16
      private let modifierFlagsRawValue: UInt
  }
  static var rightCommand: Self { .modifierOnly(keyCode: UInt16(kVK_RightCommand), modifierFlags: [.command]) }
  private static let genericModifierKeyCode = UInt16.max   // modifier-only sans keyCode précis
Détection down/up (dans .flagsChanged):
  func matchesModifierEvent(keyCode e, modifierFlags f) -> Bool {
      guard kind == .modifierOnly else { return false }
      let n = Self.normalizedModifierFlags(f, forKeyCode: e)
      if keyCode == genericModifierKeyCode { return n == modifierFlags }
      return keyCode == e && n == modifierFlags        // -> dispatchKeyDown
  }
  func shouldReleaseModifierEvent(keyCode e, modifierFlags f) -> Bool {
      guard kind == .modifierOnly else { return false }
      if keyCode == genericModifierKeyCode { return !n.isSuperset(of: modifierFlags) }
      return keyCode == e                              // -> dispatchKeyUp
  }
GAUCHE vs DROITE = distinction par keyCode dans l'évènement flagsChanged: kVK_RightCommand(0x36) vs kVK_Command(0x37); idem RightShift/Option/Control. `isInterruptedByAdditionalKeyDown` = true pour modifierOnly (toute autre touche interrompt). Cooldown: shortcutPressCooldown = 0.5s via lastShortcutPressTime. Modes (RecordingShortcutModeHandler): pushToTalk (keyDown=start, keyUp=stop), toggle (keyUp -> isHandsFreeRecording=true), hybrid (si maintenu >=0.5s -> PTT sinon toggle).

=== PANNEAU FLOTTANT ===
MiniRecorderPanel.swift  (class MiniRecorderPanel: NSPanel):
  init(... styleMask: [.nonactivatingPanel, .fullSizeContentView], backing: .buffered ...)
  level = .floating
  collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
  isFloatingPanel = true; hidesOnDeactivate = false
  override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { true }
  backgroundColor = .clear; isOpaque = false; hasShadow = false
  static func calculateWindowMetrics() -> NSRect  // centré horizontalement, 24pt padding haut, 540x430
NotchRecorderPanel.swift (class NotchRecorderPanel: KeyablePanel /* custom NSPanel */):
  styleMask: [.nonactivatingPanel, .fullSizeContentView, .hudWindow]
  self.level = .statusBar + 3            // au-dessus de la barre de statut & du fullscreen
  self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
  positionné via safeAreaInsets pour épouser la notch
MiniWindowManager.swift: lazy initializeWindow(); NSHostingController(rootView: AnyView(MiniRecorderView(stateProvider: engine))); panel.contentView = hostingController.view; show()=order front; hide()=orderOut(nil); destroyWindow().
RecorderUIManager.swift: showRecorderPanel()/hideRecorderPanel() délèguent à NotchWindowManager ou MiniWindowManager selon recorderPanelStyle; lie la visibilité à recordingState.

=== PASTE (CursorPaster.swift / PasteMethod.swift / ClipboardManager.swift) ===
Constantes: pasteShortcutEventDelay=0.01, prePasteDelay=0.10, minimumClipboardRestoreDelay=0.25
Séquence: garde AXIsProcessTrusted(); snapshot via NSPasteboard.pasteboardItems; ClipboardManager.setClipboard(text); sleep prePasteDelay;
  cmdDown = CGEvent(keyboardEventSource:src, virtualKey: 0x37, keyDown: true);  cmdDown.flags = .maskCommand
  vDown   = CGEvent(... virtualKey: 0x09, keyDown: true);  vDown.flags = .maskCommand
  vUp     = CGEvent(... virtualKey: 0x09, keyDown: false); vUp.flags   = .maskCommand
  cmdUp   = CGEvent(... virtualKey: 0x37, keyDown: false)
  chacun .post(tap: .cghidEventTap) espacé de pasteShortcutEventDelay
puis restauration du presse-papier après minimumClipboardRestoreDelay.
PasteMethod: enum { case standard("default"); case appleScript("appleScript") }; current(in:) lit UserDefaults "pasteMethod" (fallback legacy "useAppleScriptPaste").

=== FLUIDAUDIO / PARAKEET ===
FluidAudioTranscriptionService.swift (offline):
  import FluidAudio
  let asr = AsrManager(config: .default)
  try await asr.loadModels(models)                    // models: AsrModels
  let result = try await asr.transcribe(_ audio: [Float], decoderState: &tdt, language: Language?)  // result.text
  let tdt = TdtDecoderState.make(decoderLayers: asr.decoderLayerCount)   // réutilisé en inout
AsrModels: try await AsrModels.downloadAndLoad(version: .v3 /*.v2*/, progressHandler:); .modelsExist(at:version:)
Streaming: UnifiedAsrManager(encoderPrecision:).loadModels()/transcribe([Float])->String; StreamingNemotronMultilingualAsrManager.loadModels(from:)/downloadVariant(languageCode:chunkMs:progressHandler:)
VAD: VadManager(config: VadConfig); await .segmentSpeechAudio([Float])
Pré-traitement audio: lit WAV en sautant l'en-tête 44 octets; Int16 LE -> Float ±1.0; padding de 16000 échantillons de silence si total <= 240000 (fenêtre 1s..15s @16kHz).
Stockage modèles: ~/Library/Application Support/FluidAudio/Models/{parakeet-unified, nemotron-multilingual/{lang}/{chunk}} ; v2/v3 aux emplacements par défaut d'AsrModels.
API FluidAudio courante (README, v>=0.12.4): .package(url:"https://github.com/FluidInference/FluidAudio.git", from:"0.12.4"), produit "FluidAudio"; entrée [Float] 16kHz mono (ou AVAudioPCMBuffer/URL); tourne sur l'ANE.

=== AUDIO (CoreAudioRecorder.swift) ===
AUHAL/AudioUnit direct (pas AVAudioEngine). Cible 16kHz mono Int16. inputRingSlotCount=96, maxFramesPerRender=4096, ManagedAtomic pour indices, render callback sans allocation, conversion (mixage mono + resampling linéaire + Float32*32767->Int16) sur audioProcessingQueue(.userInitiated). ExtAudioFileWrite pour WAV. callback: var onAudioChunk: ((Data)->Void)?. Ne modifie pas le device système par défaut.

=== ENGINE / ÉTAT (VoiceInkEngine.swift, RecordingState.swift) ===
enum RecordingState: Equatable { idle, starting, recording, transcribing, enhancing, busy }
@Published recordingState; @Published shouldCancelRecording: Bool; @Published partialTranscript: String
Flux toggleRecord(): requestRecordPermission -> .starting -> recorder.startRecording(toOutputFile: WAV temp) + RecordingContextCaptureService.startCapture -> .recording ; chunks -> RealtimeAudioChunkGate (OSAllocatedUnfairLock, max 2048 chunks, compte les drops) ; stop -> .transcribing -> insert Transcription(status:.pending) dans modelContext (SwiftData) -> runPipeline(onStateChange:, shouldCancel:, onCancel:) -> paste -> cleanupResources() -> .idle.
Anti-stale: activeRecordingStartID + activePipelineTranscriptionID (UUID). Annulation: requestRecordingCancellation() met shouldCancelRecording=true; en transcribing/enhancing ajoute l'ID à canceledPipelineTranscriptionIDs. cleanupResources(): whisperModelManager.cleanupResources() + serviceRegistry.cleanup().

=== MENU BAR (MenuBarManager.swift) ===
setActivationPolicy(.accessory) (menu-bar-only) / .regular (fenêtre visible); toggleMenuBarOnly() -> isMenuBarOnly.toggle() -> updateAppActivationPolicy(). AppDelegate: applicationShouldTerminateAfterLastWindowClosed -> false.
</code_notes>
<pitfalls>
<pitfall>La librairie KeyboardShortcuts (Sindre Sorhus) NE PEUT PAS enregistrer un raccourci modifier-only comme "Commande droite seule" — c'est la raison même pour laquelle VoiceInk a un CGEventTap maison. Ne pas perdre de temps à essayer de la faire fonctionner pour le déclencheur principal de MoDict.</pitfall>
<pitfall>Les CGEventFlags "propres" (.maskCommand) ne distinguent PAS gauche/droite. La seule façon fiable de détecter "Commande droite" est de lire le keyCode de l'évènement .flagsChanged (0x36 = droite, 0x37 = gauche). Ne pas se fier uniquement à modifierFlags.</pitfall>
<pitfall>Un CGEventTap se fait désactiver silencieusement par le système s'il est trop lent, ou si les permissions manquent (Accessibilité + Input Monitoring sur macOS récent). Il faut réactiver le tap sur .tapDisabledByTimeout / .tapDisabledByUserInput et vérifier/redemander les permissions au lancement.</pitfall>
<pitfall>Si le panneau flottant peut devenir key/main SANS .nonactivatingPanel, il vole le focus de l'app cible et le Cmd+V synthétisé colle dans le vide (ou dans le panneau). .nonactivatingPanel est obligatoire pour préserver le frontmost.</pitfall>
<pitfall>Restaurer le presse-papier trop tôt après le Cmd+V synthétisé écrase le texte avant que l'app cible ne l'ait lu. VoiceInk attend >=0.25s (minimumClipboardRestoreDelay). Ne pas restaurer immédiatement.</pitfall>
<pitfall>Sans suivi par UUID des enregistrements/pipelines, un double appui rapide ou un relâchement pendant la transcription provoque des callbacks obsolètes qui collent un mauvais texte ou corrompent l'état. Le pattern activeRecordingStartID/activePipelineTranscriptionID est ce qui rend le PTT robuste.</pitfall>
<pitfall>Parakeet exige impérativement du 16 kHz mono Float ±1.0. Fournir un autre sample rate ou du stéréo donne des transcriptions vides ou du charabia. Prévoir un AVAudioConverter systématique. VoiceInk ajoute aussi un padding de silence pour les clips très courts (<1s) sinon le modèle peut échouer.</pitfall>
<pitfall>Le code de VoiceInk est GPL-3.0 : recopier des blocs littéraux contaminerait MoDict. Seuls les patterns architecturaux et les appels d'API système (non copyrightables) sont réutilisables — tout doit être réécrit.</pitfall>
<pitfall>VoiceInk se build encore avec un .xcodeproj (pas SwiftPM pur). MoDict visant un build SPM sans Xcode, attention : Assets.xcassets, les xcframeworks vendus (whisper), et certaines ressources de bundle demandent une config Package.swift explicite (resources, .copy, unsafeFlags pour lier les frameworks CoreML/Accelerate). FluidAudio en revanche est une dépendance SPM propre.</pitfall>
</pitfalls>
<sources>
<source>https://github.com/Beingpax/VoiceInk (dépôt principal, GPL-3.0)</source>
<source>https://raw.githubusercontent.com/Beingpax/VoiceInk/main/VoiceInk/Shortcuts/ShortcutMonitor.swift (CGEventTap, .cgSessionEventTap, flagsChanged)</source>
<source>https://raw.githubusercontent.com/Beingpax/VoiceInk/main/VoiceInk/Shortcuts/Shortcut.swift (modèle Shortcut, rightCommand, matchesModifierEvent/shouldReleaseModifierEvent, kVK_RightCommand 0x36)</source>
<source>https://raw.githubusercontent.com/Beingpax/VoiceInk/main/VoiceInk/Shortcuts/RecordingShortcutManager.swift (modes PTT/toggle/hybrid, cooldown 0.5s)</source>
<source>https://raw.githubusercontent.com/Beingpax/VoiceInk/main/VoiceInk/Views/Recorder/MiniRecorderPanel.swift (NSPanel: .nonactivatingPanel, .floating, .canJoinAllSpaces, .fullScreenAuxiliary)</source>
<source>https://raw.githubusercontent.com/Beingpax/VoiceInk/main/VoiceInk/Views/Recorder/NotchRecorderPanel.swift (level .statusBar+3, .stationary, .ignoresCycle)</source>
<source>https://raw.githubusercontent.com/Beingpax/VoiceInk/main/VoiceInk/Views/Recorder/MiniWindowManager.swift (NSHostingController hosting, show/hide/orderOut)</source>
<source>https://raw.githubusercontent.com/Beingpax/VoiceInk/main/VoiceInk/Transcription/Engine/RecorderUIManager.swift (coordination panneau/état)</source>
<source>https://raw.githubusercontent.com/Beingpax/VoiceInk/main/VoiceInk/Paste/CursorPaster.swift (CGEvent Cmd+V 0x37/0x09, save/restore presse-papier, délais)</source>
<source>https://raw.githubusercontent.com/Beingpax/VoiceInk/main/VoiceInk/Paste/PasteMethod.swift (standard vs appleScript)</source>
<source>https://raw.githubusercontent.com/Beingpax/VoiceInk/main/VoiceInk/Transcription/FluidAudio/FluidAudioTranscriptionService.swift (AsrManager, AsrModels, transcribe, TdtDecoderState, VadManager)</source>
<source>https://raw.githubusercontent.com/Beingpax/VoiceInk/main/VoiceInk/Transcription/FluidAudio/FluidAudioModelManager.swift (downloadAndLoad, DownloadUtils.downloadRepo, chemins de stockage)</source>
<source>https://raw.githubusercontent.com/Beingpax/VoiceInk/main/VoiceInk/CoreAudioRecorder.swift (AUHAL 16kHz mono Int16, onAudioChunk, ring buffer)</source>
<source>https://raw.githubusercontent.com/Beingpax/VoiceInk/main/VoiceInk/Transcription/Engine/VoiceInkEngine.swift (orchestrateur, RecordingState, UUID anti-stale, RealtimeAudioChunkGate, annulation)</source>
<source>https://raw.githubusercontent.com/Beingpax/VoiceInk/main/VoiceInk/Transcription/Engine/RecordingState.swift (enum idle/starting/recording/transcribing/enhancing/busy)</source>
<source>https://raw.githubusercontent.com/Beingpax/VoiceInk/main/VoiceInk/MenuBarManager.swift (setActivationPolicy .accessory/.regular)</source>
<source>https://raw.githubusercontent.com/Beingpax/VoiceInk/main/VoiceInk.xcodeproj/project.pbxproj (dépendances SPM: FluidAudio, swift-atomics, Sparkle, LaunchAtLogin-Modern, Zip, LLMkit, SelectedTextKit, mediaremote-adapter)</source>
<source>https://raw.githubusercontent.com/FluidInference/FluidAudio/main/README.md (API courante: AsrModels.downloadAndLoad(version:.v3), AsrManager(config:.default), transcribe([Float]), ANE, from:0.12.4)</source>
<source>https://github.com/FluidInference/FluidAudio (SDK Parakeet/CoreML, licence permissive)</source>
</sources>
</invoke>


## Recommendations

## Code notes


## Pitfalls

## Sources
