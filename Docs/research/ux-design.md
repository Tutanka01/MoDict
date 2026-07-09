# Research: ux-design

## Summary
Une UX de dictée macOS exceptionnelle repose sur trois piliers : un indicateur d'enregistrement flottant qui apparaît instantanément (feedback perçu), un onboarding qui enchaîne permissions + téléchargement modèle + essai réel sans friction, et une insertion de texte qui ne vole jamais le focus. Sur le marché : Wispr Flow est la référence UX — une "Flow Bar" en capsule ancrée en bas-centre qui s'étend pour montrer Annuler (X) / waveform pulsante / Valider (checkmark) ; onboarding le plus fluide (compte → install → accessibilité → dictée d'essai guidée, productif en 5 min) mais 100% cloud, latence 1-2s, et un "trust gap" après paiement. superwhisper utilise une "mini-mode pill" flottante avec waveform et vit dans la menu bar ; son onboarding = Accessibilité + Micro + choix device + download modèle (Nano/Fast), mais réglages denses et transcriptions à nettoyer. Côté open source Swift/SwiftUI : VoiceInk (whisper.cpp, KeyboardShortcuts, Sparkle, RecorderUIManager/MenuBarManager, UI jugée "basique"), FluidVoice (SPM, support notch, overlay pill→large, onboarding language-first + essai réel, Parakeet/Nemotron/Apple Speech), OpenDictation (intégration notch/Dynamic Island, zero-setup, Neural Engine), Handy (Tauri/Rust, overlay désactivable, Silero VAD, MIT, 23k★), Whispering (MIT, shortcut recorder visuel). Les frictions récurrentes : latence, transcriptions à corriger, indicateur bloqué en bas-centre non repositionnable (d'où l'utilitaire tiers PillFloat), indicateur qui reste affiché après l'arrêt, apps qui monopolisent l'entrée/sortie audio (chime coupé), absence de feedback sonore de fin, déclenchements accidentels du hotkey, réglages trop denses. Pour MoDict : une capsule monochrome en .ultraThinMaterial ancrée bas-centre (repositionnable + option notch), waveform de barres pilotée par le RMS micro, états spring idle/recording/transcribing/inserted/error, NSPanel .nonactivatingPanel qui ne prend jamais le focus, onboarding en 5 écrans, MenuBarExtra + réglages en onglets style Réglages Système, et des micro-détails premium (haptics trackpad, sons subtils optionnels, debounce anti-déclenchement, VAD anti-texte-vide, gestion d'erreur inline jamais modale).</summary>
<recommendations>
<recommendation>
<topic>Forme et matériau de l'indicateur d'enregistrement</topic>
<recommendation>Adopter une capsule (pill) flottante horizontale : hauteur 36-44pt, largeur ~140pt en état recording, corner radius = hauteur/2 (capsule pleine). Fond en .ultraThinMaterial (vibrancy), fine bordure blanche à opacité ~0.06-0.10, ombre douce (radius 20, y 8, opacité 0.15). Position par défaut : bas-centre de l'écran actif, ~24-32pt au-dessus du bord inférieur (position que Wispr Flow a rendue familière). Rendre la position configurable (bas-centre / notch / près du curseur) car l'ancrage forcé en bas-centre de Wispr est LA frustration n°1 (existence de l'utilitaire tiers PillFloat pour la déplacer). Prévoir une variante "notch" (comme FluidVoice/OpenDictation) qui se loge dans l'encoche des MacBook récents.</recommendation>
<rationale>Wispr Flow (référence UX du secteur) et superwhisper convergent tous deux vers une pill flottante avec waveform ; le .ultraThinMaterial + SF Symbols donne le look Apple natif recherché ; rendre la position configurable corrige directement la friction la plus citée.</rationale>
</recommendation>
<recommendation>
<topic>Waveform et animation des barres</topic>
<recommendation>Waveform = 5 à 9 barres verticales monochromes (couleur .primary/label), largeur 3pt, espacement 2-3pt, coins arrondis 1.5pt, hauteur min ~4pt / max ~24pt. Piloter la hauteur par le niveau RMS du micro (pas de FFT nécessaire pour un simple niveau) via un tap AVAudioEngine, avec un léger lissage temporel (interpolation vers la nouvelle valeur). Animer chaque changement avec .interpolatingSpring(stiffness: 170, damping: 15) ou .easeOut(duration: 0.08) pour un rendu "physique" sans lag. Au repos/silence : barres à une hauteur de base minimale animées d'une respiration très lente. Apparition/disparition de la capsule : scale 0.92→1 + opacity via .spring(response: 0.35, dampingFraction: 0.72).</recommendation>
<rationale>Les articles SwiftUI de référence (createwithswift, hackingwithswift) montrent que l'animation de hauteur de barres pilotée par le niveau audio est la technique standard ; le spring donne le ressenti premium ; le monochrome respecte la contrainte de design.</rationale>
</recommendation>
<recommendation>
<topic>Machine à états visuelle de l'indicateur</topic>
<recommendation>Cinq états avec transitions spring : (1) idle = capsule cachée (aucun chrome à l'écran) ; (2) recording = capsule apparaît à l'appui sur Commande droite, waveform live + point/anneau d'enregistrement pulsant discret ; (3) transcribing = la waveform se contracte en 3 points animés (typing dots) ou un shimmer indéterminé pendant l'inférence Parakeet (viser <500ms donc état bref) ; (4) inserted = les barres/points fusionnent en un SF Symbol "checkmark" qui apparaît brièvement (~350ms) puis la capsule se retire en fondu+scale ; (5) error = teinte rouge subtile + SF Symbol "exclamationmark.triangle" ou "mic.slash", légère secousse (offset ±4pt x2), texte inline court tap-to-fix ("Micro indisponible", "Autoriser l'accessibilité"). Montrer la waveform DÈS le key-down (avant même que l'audio n'arrive) pour maximiser la réactivité perçue.</rationale>
<rationale>Wispr Flow expose exactement Cancel/waveform/Done et a dû corriger un bug d'indicateur restant affiché après l'arrêt ; afficher immédiatement masque la latence (plainte récurrente) ; une erreur inline et non-modale évite d'interrompre le flux de frappe.</rationale>
</recommendation>
<recommendation>
<topic>Fenêtre technique : NSPanel qui ne vole jamais le focus</topic>
<recommendation>Héberger la capsule dans une sous-classe de NSPanel avec styleMask [.nonactivatingPanel, .borderless/.fullSizeContentView], isFloatingPanel=true, level=.floating (ou .statusBar pour passer au-dessus), collectionBehavior=[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary], hidesOnDeactivate=false, ignoresMouseEvents=true quand la capsule est purement indicative (click-through), et surtout canBecomeKey=false / canBecomeMain=false pour NE JAMAIS prendre le focus clavier — le curseur doit rester dans le champ cible. Contenu SwiftUI via NSHostingView, fond transparent. App en LSUIElement=true (agent, pas de Dock).</rationale>
<rationale>Le point critique d'une app d'insertion au curseur : voler le focus casserait l'insertion ; .nonactivatingPanel + canBecomeKey=false est la recette AppKit confirmée par plusieurs sources SwiftUI (Cindori, Fazm).</rationale>
</recommendation>
<recommendation>
<topic>Flow d'onboarding idéal (5 écrans)</topic>
<recommendation>(1) Bienvenue : une phrase ("Maintenez Commande droite, parlez, relâchez — le texte s'insère partout") + micro-animation de la touche. (2) Micro : bouton qui appelle AVCaptureDevice.requestAccess(for:.audio), avec explication de la raison ; état visuel autorisé/refusé + lien vers Réglages si refusé. (3) Accessibilité : expliquer "nécessaire pour taper le texte dans vos apps", bouton qui appelle AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt:true]) et deep-link vers x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility, puis POLLER AXIsProcessTrusted() pour avancer automatiquement dès l'octroi. (4) Modèle Parakeet : barre de progression avec taille affichée, téléchargement résumable, bouton en arrière-plan. (5) Essai réel : champ de texte intégré "Maintenez Commande droite et dites bonjour" → transcription affichée inline → checkmark/confetti de succès + toggle "Lancer au démarrage". Barre de progression de l'onboarding en haut, écrans passables au clavier.</recommendation>
<rationale>superwhisper (Accessibilité+Micro+device+modèle) et Wispr Flow (essai de dictée guidé, "productif en 5 min") définissent le standard ; l'auto-détection de l'octroi de permission et l'essai réel dans l'onboarding sont les détails qui font la différence entre "fluide" et "indie".</rationale>
</recommendation>
<recommendation>
<topic>Menu bar</topic>
<recommendation>Utiliser MenuBarExtra (SwiftUI, macOS 13+) avec une icône SF Symbol d'état : "mic" au repos, "waveform" ou icône remplie/animée pendant l'enregistrement. Menu/popover minimaliste : ligne de statut (Prêt / Enregistrement / Modèle en cours de téléchargement), toggle Activer/Désactiver la dictée, liste des 5 dernières transcriptions (clic = re-copier dans le presse-papiers, état vide "Vos transcriptions apparaîtront ici" avec glyphe micro), rappel du raccourci, Réglages…, Quitter. Style menuBarExtraStyle(.window) pour un popover soigné plutôt que le menu système brut.</rationale>
<rationale>MacWhisper et superwhisper vivent dans la menu bar comme point d'ancrage discret ; MenuBarExtra .window permet un rendu premium avec materials ; l'historique cliquable répond au besoin de récupérer une transcription.</rationale>
</recommendation>
<recommendation>
<topic>Structure des réglages (onglets style Réglages Système)</topic>
<recommendation>Fenêtre Settings SwiftUI avec TabView en onglets : (1) Général — raccourci (défaut Commande droite ; mode push-to-talk vs toggle), lancer au démarrage, icône menu bar, sons on/off, haptics on/off. (2) Modèle — choix/gestion des modèles Parakeet, langue, statut de téléchargement. (3) Dictionnaire — mots custom et remplacements de texte. (4) Formatage — ponctuation auto, capitalisation, suppression des hésitations. (5) Apparence — position de l'indicateur (bas-centre/notch/curseur), taille, mode clair/sombre. (6) Avancé — périphérique d'entrée audio, re-vérification des permissions, seuil VAD, durée minimale de maintien. (7) À propos — version, mises à jour (Sparkle), liens open source. Garder chaque onglet court : la densité des réglages superwhisper est une plainte fréquente.</rationale>
<rationale>Reflète VoiceInk (dictionnaire, power mode) et MacWhisper (sidebar réglages) tout en corrigeant la "steep learning curve" de superwhisper via une hiérarchie plate et des valeurs par défaut fortes.</rationale>
</recommendation>
<recommendation>
<topic>Micro-détails premium (sons, haptics, animations)</topic>
<recommendation>Haptics trackpad via NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime:.now) à l'appui et .levelChange à l'insertion réussie (toggleable). Sons subtils optionnels (NSSound, court ton montant au start / descendant au stop) — désactivés par défaut ou très discrets, car des utilisateurs se plaignent à la fois d'apps qui monopolisent l'audio ET de l'absence de son de fin ; ne jamais couper l'audio système. Animations spring partout (capsule, checkmark). États vides soignés (historique, dictionnaire). Gestion d'erreur TOUJOURS inline dans la capsule (jamais de modale) avec action de réparation en un tap. Undo/re-copie de la dernière insertion.</rationale>
<rationale>Ce sont précisément les détails que les reviews attribuent au ressenti "premium" de Wispr Flow face aux apps indie, et qui adressent les plaintes audio remontées sur les forums Apple.</rationale>
</recommendation>
<recommendation>
<topic>Réduction de friction spécifique (anti-plaintes)</topic>
<recommendation>Anti-déclenchement accidentel : exiger une durée de maintien minimale de Commande droite (~180-250ms) OU un minimum d'audio détecté avant d'afficher/enregistrer, sinon ignorer silencieusement. VAD Silero (comme Handy) pour couper les silences et NE JAMAIS insérer de texte vide ("Didn't catch that" en fondu si rien). Retirer l'indicateur immédiatement au relâchement (bug corrigé tardivement par Wispr). Masquer la latence : afficher la waveform au key-down, streamer l'inférence, insérer dès que prêt (Parakeet on-device permet un ressenti quasi temps réel <500ms, avantage majeur sur les 1-2s cloud de Wispr). Insertion via presse-papiers + Cmd+V simulé (CGEvent) avec restauration du presse-papiers précédent, ou AXUIElement, pour un collage universel et rapide.</rationale>
<rationale>Chaque item cible une frustration documentée (déclenchement accidentel, texte vide, indicateur persistant, latence, insertion non universelle) ; l'on-device rapide est l'argument différenciant de MoDict.</rationale>
</recommendation>
</recommendations>
<code_notes>PERMISSIONS: Micro → AVCaptureDevice.requestAccess(for: .audio) { granted in }, statut via AVCaptureDevice.authorizationStatus(for:.audio). Accessibilité → AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) ; polling AXIsProcessTrusted() ; deep-link Réglages : NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!).

HOTKEY COMMANDE DROITE (gotcha): la flag .command ne distingue pas gauche/droite. Il faut un moniteur NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) (+ local) OU un CGEventTap, et tester event.keyCode == 54 (Commande droite ; 55 = gauche). Down = keyCode 54 avec modifierFlags contenant .command ; up = même keyCode sans .command. Pour un tap fiable au premier plan sur d'autres apps, CGEventTap au niveau session peut être nécessaire (nécessite l'accessibilité). La lib sindresorhus/KeyboardShortcuts (utilisée par VoiceInk) gère les raccourcis classiques mais PAS un modificateur seul comme push-to-talk → prévoir du code custom pour Commande droite.

FENÊTRE FLOTTANTE: class RecorderPanel: NSPanel { override var canBecomeKey: Bool { false }; override var canBecomeMain: Bool { false } } ; init(styleMask:[.nonactivatingPanel, .fullSizeContentView]) ; isFloatingPanel=true ; level = .statusBar ; collectionBehavior=[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary] ; hasShadow=true ; backgroundColor = .clear ; isOpaque=false ; ignoresMouseEvents=true (si indicatif) ; contentView = NSHostingView(rootView: RecorderView()). App: LSUIElement=true dans Info.plist (agent menu bar, pas de Dock).

WAVEFORM: let engine = AVAudioEngine(); engine.inputNode.installTap(onBus:0, bufferSize:1024, format: inputNode.outputFormat(forBus:0)) { buffer, _ in /* channelData floatChannelData?[0], calcul RMS = sqrt(mean(x^2)), convert en dB avec 20*log10, clamp, publier sur @Published level }. Côté SwiftUI: ForEach(bars) { RoundedRectangle(cornerRadius:1.5).frame(width:3, height: barHeight).animation(.interpolatingSpring(stiffness:170, damping:15), value: level) }. Alternative FFT (vDSP_DFT_Execute/vDSP_zvabs, Accelerate) seulement si barres par fréquence souhaitées.

INSERTION TEXTE: sauvegarder NSPasteboard.general.string, écrire la transcription, simuler Cmd+V : CGEvent(keyboardEventSource:src, virtualKey:9 /*V*/, keyDown:true) avec .flags=.maskCommand puis keyDown:false, post(.cghidEventTap) ; restaurer le presse-papiers après un court délai. Alternative: AXUIElement kAXSelectedTextAttribute / kAXValueAttribute pour insertion directe (plus fragile selon les apps).

MENU BAR: MenuBarExtra("MoDict", systemImage: isRecording ? "waveform" : "mic") { ... }.menuBarExtraStyle(.window). Icône animée pendant l'enregistrement via un TimelineView ou symbolEffect (.variableColor.iterative) sur macOS 14+.

HAPTICS: NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) au start, .levelChange à l'insertion. SONS: NSSound(named:) ou fichier .aiff court joué sans monopoliser l'entrée. MATERIALS: .background(.ultraThinMaterial, in: Capsule()) ; SF Symbols pour tous les états (mic, waveform, checkmark, exclamationmark.triangle, mic.slash). ANIMATIONS d'apparition: .transition(.scale(0.92).combined(with:.opacity)) + withAnimation(.spring(response:0.35, dampingFraction:0.72)).

STT ENGINE (Parakeet on-device): évaluer le package Swift fluidinference/FluidAudio (Parakeet-TDT via CoreML sur Apple Silicon) comme piste pour l'inférence — à vérifier ; VoiceInk utilise whisper.cpp, FluidVoice/OpenDictation exploitent le Neural Engine (CoreML/ANE). VAD Silero pour trim silence (approche de Handy). Cible: latence perçue <500ms post-relâchement.</code_notes>
<pitfalls>
<pitfall>Voler le focus clavier : si la fenêtre indicateur devient key/main, l'insertion au curseur échoue. Impératif : NSPanel .nonactivatingPanel + canBecomeKey/canBecomeMain = false.</pitfall>
<pitfall>Commande droite non distinguable via les modifier flags seuls — nécessite le keyCode 54 (droite) vs 55 (gauche) et un moniteur .flagsChanged ou CGEventTap ; la plupart des libs de raccourcis ne gèrent pas un modificateur seul en push-to-talk.</pitfall>
<pitfall>Déclenchements accidentels du hotkey (plainte fréquente) : sans durée de maintien minimale ni seuil audio, chaque frôlement de Commande droite ouvre l'indicateur et risque d'insérer du texte parasite.</pitfall>
<pitfall>Insérer du texte vide quand aucun mot n'est prononcé — utiliser un VAD et ne rien coller si le résultat est vide (afficher un feedback discret).</pitfall>
<pitfall>Monopoliser l'entrée/sortie audio : des utilisateurs se plaignent que la dictée coupe les chimes/appels ; ne pas prendre le contrôle exclusif du device audio et rendre les sons optionnels.</pitfall>
<pitfall>Indicateur qui reste affiché après l'arrêt (bug qu'a connu Wispr Flow) : garantir un retrait immédiat et déterministe au relâchement, même en cas d'erreur d'inférence.</pitfall>
<pitfall>Position d'indicateur figée : forcer le bas-centre sans option de repositionnement a généré un utilitaire tiers (PillFloat) pour Wispr ; rendre la position configurable dès le départ.</pitfall>
<pitfall>Réglages trop denses (reproche à superwhisper/VoiceInk) : privilégier des valeurs par défaut fortes et une hiérarchie plate ; ne pas noyer l'utilisateur.</pitfall>
<pitfall>Erreurs de permission gérées en modale bloquante au milieu de la dictée : casse le flux ; toujours du feedback inline non-bloquant avec action de réparation.</pitfall>
<pitfall>Ne pas restaurer le presse-papiers après un collage simulé (Cmd+V) écrase le contenu de l'utilisateur — sauvegarder et restaurer.</pitfall>
<pitfall>Traffic light / Dock visibles : oublier LSUIElement=true et masquer le chrome de fenêtre trahit l'aspect "utilitaire système" attendu.</pitfall>
</pitfalls>
<sources>
<source>https://superwhisper.com/docs/get-started/introduction</source>
<source>https://superwhisper.com/changelog</source>
<source>https://www.nemovideo.com/alternative/superwhisper</source>
<source>https://docs.wisprflow.ai/articles/6409258247-starting-your-first-dictation</source>
<source>https://docs.wisprflow.ai/articles/5002934560-why-is-the-wispr-bar-is-not-appearing-or-disappearing</source>
<source>https://docs.wisprflow.ai/articles/3152211871-setup-guide</source>
<source>https://github.com/OrangeAKA/pillfloat</source>
<source>https://spokenly.app/blog/wispr-flow-review</source>
<source>https://spokenly.app/blog/superwhisper-review</source>
<source>https://www.getvoibe.com/resources/wispr-flow-vs-superwhisper/</source>
<source>https://github.com/Beingpax/VoiceInk</source>
<source>https://raw.githubusercontent.com/Beingpax/VoiceInk/main/README.md</source>
<source>https://api.github.com/repos/Beingpax/VoiceInk/git/trees/main?recursive=1</source>
<source>https://github.com/cjpais/Handy</source>
<source>https://raw.githubusercontent.com/cjpais/Handy/main/README.md</source>
<source>https://github.com/altic-dev/FluidVoice</source>
<source>https://github.com/kdcokenny/OpenDictation</source>
<source>https://whispering.bradenwong.com/</source>
<source>https://9to5mac.com/2024/12/06/macwhisper-11-brings-a-friendly-redesign-to-the-best-ai-powered-transcription-app/</source>
<source>https://www.createwithswift.com/creating-a-live-audio-waveform-in-swiftui/</source>
<source>https://cindori.com/developer/floating-panel</source>
<source>https://fazm.ai/blog/swiftui-floating-panel</source>
<source>https://afadingthought.substack.com/p/best-ai-dictation-tools-for-mac</source>
<source>https://discussions.apple.com/thread/252438661</source>
</sources>
</invoke>


## Recommendations

## Code notes


## Pitfalls

## Sources
