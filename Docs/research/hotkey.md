# Research: hotkey

## Summary
Pour détecter la touche Commande droite seule (keyCode 54 = 0x36 ; Cmd gauche = 55) en global push-to-talk/toggle, la seule approche robuste est un CGEventTap qui écoute les événements .flagsChanged — PAS NSEvent.addGlobalMonitorForEvents. NSEvent global monitor est passif (ne peut pas supprimer), ne se déclenche pas quand ta propre app est au premier plan, et exige la permission Accessibility. Le CGEventTap n'exige QUE la permission Input Monitoring (TCC service kTCCServiceListenEvent) pour écouter le clavier, vérifiable/demandable via CGPreflightListenEventAccess() / CGRequestListenEventAccess(). Sur un événement flagsChanged, le champ .keyboardEventKeycode contient bien le keyCode spécifique gauche/droite (54 vs 55), ce qui permet de distinguer la Cmd droite ; press vs release se déduit du bit device-dependent NX_DEVICERCMDKEYMASK (0x10) dans event.flags. VoiceInk (Swift) utilise exactement ce pattern dans VoiceInk/Shortcuts/ShortcutMonitor.swift + Shortcut.swift : un CGEventTap .cgSessionEventTap, une machine à états isDown/pressedAt, et — c'est clé — il NE supprime PAS les modificateurs seuls (il ne swallow que les raccourcis à touche pleine), donc Cmd+C reste fonctionnel. Le combo est géré par une fenêtre d'interruption de 1 s : si une touche non-modificatrice arrive pendant que Cmd droite est tenue, il annule le démarrage accidentel de l'enregistrement. La distinction tap-bref (toggle) vs maintien (push-to-talk) se fait par un seuil de durée (VoiceInk mode « hybrid » : 0.5 s) mesuré entre keyDown et keyUp. Le tap DOIT être ré-armé : gérer .tapDisabledByTimeout et .tapDisabledByUserInput dans le callback avec CGEvent.tapEnable(tap:enable:true), plus un watchdog qui vérifie CGEvent.tapIsEnabled() toutes les ~5 s. Point critique pour un build SPM signé ad-hoc (codesign -s -) : le cdhash change à CHAQUE rebuild, donc TCC révoque Input Monitoring/Accessibility à chaque compilation ; la parade dev est de signer avec un certificat auto-signé stable (créé dans Keychain Access, pattern yabai/skhd) qui rend le Designated Requirement constant, et en prod un Developer ID Application.

## Recommendations
### API à utiliser : CGEventTap flagsChanged, PAS NSEvent global monitor
**Reco:** Utiliser CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: masque avec .flagsChanged (+ .keyDown pour la détection de combo), callback:, userInfo:). Écouter .flagsChanged pour capter press ET release de la Cmd droite seule. Ne PAS utiliser NSEvent.addGlobalMonitorForEvents.

**Pourquoi:** NSEvent.addGlobalMonitorForEvents est passif (impossible de supprimer un événement), ne reçoit PAS les événements quand ta propre app/fenêtre est au premier plan (il faudrait doubler avec addLocalMonitorForEvents), et — raison historique confirmée par Quinn 'The Eskimo!' d'Apple DTS — exige la permission Accessibility. Le CGEventTap reçoit les événements globalement quel que soit l'app active, distingue gauche/droite, et n'exige que Input Monitoring. flagsChanged est le SEUL type qui rapporte l'appui/relâchement d'un modificateur seul (il n'y a pas de keyDown/keyUp pour un modificateur).

### Permission TCC exacte : Input Monitoring pour le tap, Accessibility pour l'insertion
**Reco:** Pour le hotkey (écoute clavier) : demander UNIQUEMENT Input Monitoring via CGPreflightListenEventAccess() (check) puis CGRequestListenEventAccess() (déclenche le prompt système 'Input Monitoring'). Garder .listenOnly pour NE PAS avoir besoin d'Accessibility juste pour le tap. Pour l'insertion du texte au curseur (le cœur de MoDict), tu auras de toute façon besoin d'Accessibility/PostEvent car synthétiser Cmd+V ou taper via CGEvent.post exige kTCCServicePostEvent (affiché sous Accessibility) — préflight via CGPreflightPostEventAccess() / CGRequestPostEventAccess().

**Pourquoi:** Quinn (Apple DTS) : 'You don't need the Accessibility privilege to use CGEventTap. There's a separate Input Monitoring privilege… CGPreflightListenEventAccess and CGRequestListenEventAccess'. Les deux apparaissent sous Réglages > Confidentialité mais sont des services TCC distincts (kTCCServiceListenEvent vs kTCCServicePostEvent/Accessibility). Un tap .listenOnly déclenche le prompt Input Monitoring ; un tap .defaultTap qui supprime/modifie des événements peut en plus réclamer Accessibility. Comme la Cmd droite seule ne produit rien à supprimer, .listenOnly + Input Monitoring suffit pour la détection, et Accessibility n'est requis que pour la partie insertion — que MoDict a déjà.

### Ne PAS supprimer le modificateur seul → Cmd+C reste fonctionnel
**Reco:** Ne jamais retourner nil (swallow) pour l'événement flagsChanged de la Cmd droite. Retourner toujours Unmanaged.passUnretained(event) pour les modificateurs. C'est exactement ce que fait VoiceInk : dans ShortcutMonitor.handleEvent, la branche isModifierOnly appelle handleModifierOnlyShortcut puis `continue` SANS mettre shouldSuppress = true ; seuls les raccourcis kind == .key sont supprimés.

**Pourquoi:** Si tu supprimes le keystroke de la Cmd droite, tu casses tous les combos que l'utilisateur tape avec la Cmd droite (Cmd+C, Cmd+V, Cmd+Tab…). Laisser passer le modificateur permet à l'OS de composer les combos normalement ; MoDict démarre juste son enregistrement sur l'appui, puis l'annule si un combo est détecté. C'est aussi pourquoi .listenOnly est acceptable : on n'a de toute façon rien à supprimer.

### Tap bref (toggle) vs maintien (push-to-talk) : seuil de durée
**Reco:** Mesurer la durée entre keyDown (flagsChanged press) et keyUp (flagsChanged release) avec ProcessInfo.processInfo.systemUptime. Reproduire le mode 'hybrid' de VoiceInk : au press, démarrer l'enregistrement ; au release, si durée >= seuil (VoiceInk : hybridPressThreshold = 0.5 s) ET encore en enregistrement → arrêter (c'était un maintien = push-to-talk) ; sinon (tap bref) → passer en mode 'mains-libres' (l'enregistrement continue, un 2e appui l'arrête = toggle). Ajouter un cooldown anti-rebond (VoiceInk : shortcutPressCooldown = 0.5 s) pour ignorer les doubles déclenchements.

**Pourquoi:** C'est le pattern exact de VoiceInk/Shortcuts/RecordingShortcutManager.swift (RecordingShortcutModeHandler.handleKeyUp). Le seuil unique 0.5 s couvre les deux UX avec une seule touche : un tap rapide bascule en dictée continue, un maintien fait du talkie-walkie. Le systemUptime est monotone (immunisé aux changements d'horloge), contrairement à Date().

### Éviter le déclenchement en combo (Cmd+C, etc.) : fenêtre d'interruption
**Reco:** Écouter aussi .keyDown dans le même tap. Si, pendant que la Cmd droite est tenue (isDown == true), une touche NON-modificatrice arrive dans une fenêtre courte (VoiceInk : shortcutInterruptionWindow = 1.0 s) après le press, annuler l'enregistrement démarré au lieu de continuer. Vérifier que le keyCode entrant n'est pas lui-même un modificateur (Shortcut.isModifierKeyCode). Optionnellement, ne démarrer réellement l'UI/l'audio qu'après un court délai de grâce (~150-200 ms) pour éviter tout flash visuel sur un vrai combo.

**Pourquoi:** Sans ça, chaque Cmd+C (avec la Cmd droite) démarrerait une dictée d'une fraction de seconde. VoiceInk résout via handleShortcutInterruptions + dispatchShortcutInterrupted → cancelRecording, gardé uniquement si canCurrentShortcutPressCancelAccidentalStart (recorder non visible & état idle). La condition 'normalizedFlags == modifierFlags' (exactement [.command], rien d'autre) évite aussi de matcher quand d'autres modificateurs sont déjà tenus.

### Ré-armement obligatoire du tap (kCGEventTapDisabledByTimeout)
**Reco:** Dans le callback, traiter en premier `if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { CGEvent.tapEnable(tap: tap, enable: true); return }` et remettre à zéro l'état isDown des raccourcis en cours (sinon un press 'collé'). Ajouter un watchdog Timer (~toutes les 5 s) : `if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }` et, si ça échoue, réinstaller le tap complètement.

**Pourquoi:** Le système désactive un tap si le callback dépasse un timeout interne (kCGEventTapDisabledByTimeout) ou sur certains inputs. Sans ré-armement, le hotkey 'meurt' silencieusement. VoiceInk gère les deux cas dans son callback et remet isDown/pressedAt à nil (resetPressedShortcutsAfterTapInterruption). L'article de Daniel Raffel montre en plus qu'un tap non-nil peut être 'inert' : toujours vérifier CGEvent.tapIsEnabled au runtime, pas seulement que tapCreate a renvoyé non-nil.

### Signature ad-hoc SPM → reset TCC à chaque rebuild : utiliser un certificat auto-signé stable
**Reco:** NE PAS signer en pur ad-hoc (`codesign -s -`) pendant le dev. Créer une fois un certificat de signature de code auto-signé dans Keychain Access (Certificate Assistant → Create a Certificate → type 'Code Signing'), puis signer chaque build avec `codesign --force --deep --sign "MoDict Dev" MoDict.app`. Garder le MÊME nom de certificat ET un chemin de bundle stable. En production/distribution : signer avec un 'Developer ID Application' (Apple Developer Program) + `--options runtime`. Fournir dans l'app un bouton qui ouvre `x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent` et détecter le passage de CGPreflightListenEventAccess() de false→true.

**Pourquoi:** TCC identifie une app ad-hoc/non signée uniquement par son cdhash, qui change à chaque compilation → Input Monitoring, Accessibility, Micro sont révoqués à CHAQUE rebuild (confirmé multi-sources). Un certificat auto-signé persistant fige le Designated Requirement (identifier + certificat), donc les autorisations survivent aux rebuilds — c'est précisément la procédure recommandée par yabai/skhd pour 'retain accessibility privileges when rebuilt'. Le Developer ID donne un TeamIdentifier stable reconnu par TCC pour la distribution (l'auto-signé n'est reconnu que localement, pas pour notarisation).

### Lancer le binaire directement, pas via `open`, pendant le dev
**Reco:** Après un re-sign, lancer l'exécutable directement (ex. `MoDict.app/Contents/MacOS/MoDict`) plutôt que via Finder/`open`, pour réduire la ré-évaluation TCC qui rend le tap 'inert'. Toujours coupler avec la vérification runtime CGEvent.tapIsEnabled.

**Pourquoi:** Daniel Raffel documente une 'silent disable race' : après re-signature, un lancement via Launch Services (open/Finder/Dock) déclenche plus volontiers une ré-évaluation de l'identité de code qui laisse le tap installé mais sans callbacks. Le lancement direct du binaire évite ce chemin.


## Code notes
CONSTANTES: Cmd droite = keyCode 54 (0x36, kVK_RightCommand) ; Cmd gauche = 55 (0x37, kVK_Command). Bit device-dependent pour distinguer press/release sur flagsChanged: NX_DEVICERCMDKEYMASK = 0x10 (gauche = NX_DEVICELCMDKEYMASK = 0x08). Sur un flagsChanged, event.getIntegerValueField(.keyboardEventKeycode) DONNE bien le keyCode gauche/droite spécifique.

--- Implémentation MoDict autonome (Swift 6, macOS 14+), inspirée de VoiceInk ShortcutMonitor.swift ---

import AppKit
import CoreGraphics

final class RightCommandHotkey {
    enum Mode { case pushToTalk, toggle, hybrid }
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?          // combo détecté → annuler
    var mode: Mode = .hybrid

    private static let rightCmdKeyCode: Int64 = 54
    private static let rightCmdFlagMask: UInt64 = 0x10          // NX_DEVICERCMDKEYMASK
    private static let holdThreshold: TimeInterval = 0.5        // maintien >= 0.5s = PTT
    private static let interruptWindow: TimeInterval = 1.0
    private static let cooldown: TimeInterval = 0.5

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdog: Timer?
    private var isDown = false
    private var pressedAt: TimeInterval = 0
    private var handsFree = false
    private var lastTrigger: TimeInterval = 0
    private var accidentalStart = false

    // 1) Permission Input Monitoring (PAS Accessibility pour le tap)
    func ensurePermission() -> Bool {
        if CGPreflightListenEventAccess() { return true }
        CGRequestListenEventAccess()   // déclenche le prompt système "Input Monitoring"
        return false
    }

    func start() {
        guard ensurePermission() else { return }
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)      // keyDown pour détecter les combos

        let cb: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<RightCommandHotkey>.fromOpaque(refcon!).takeUnretainedValue()
            // Ré-armement OBLIGATOIRE
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
                me.resetPressed()
                return Unmanaged.passUnretained(event)
            }
            me.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)   // NE JAMAIS retourner nil (modificateur)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,            // .listenOnly => Input Monitoring seul ; pas de suppression
            eventsOfInterest: mask,
            callback: cb,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Watchdog anti "silent disable"
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, let t = self.tap else { return }
            if !CGEvent.tapIsEnabled(tap: t) { CGEvent.tapEnable(tap: t, enable: true) }
        }
    }

    func stop() {
        watchdog?.invalidate(); watchdog = nil
        if let s = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        if let t = tap { CFMachPortInvalidate(t) }
        tap = nil; runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .flagsChanged, keyCode == Self.rightCmdKeyCode {
            let pressed = (event.flags.rawValue & Self.rightCmdFlagMask) != 0
            if pressed { handlePress(now) } else { handleRelease(now) }
            return
        }
        // Combo: touche normale pendant maintien de Cmd droite -> annuler le démarrage accidentel
        if type == .keyDown, isDown, accidentalStart,
           now - pressedAt <= Self.interruptWindow {
            accidentalStart = false
            isDown = false
            DispatchQueue.main.async { self.onCancel?() }
        }
    }

    private func handlePress(_ now: TimeInterval) {
        guard !isDown else { return }
        if now - lastTrigger < Self.cooldown { return }   // anti double déclenchement
        isDown = true; pressedAt = now; lastTrigger = now
        switch mode {
        case .toggle, .hybrid:
            if handsFree { handsFree = false; DispatchQueue.main.async { self.onStop?() }; return }
            accidentalStart = true
            DispatchQueue.main.async { self.onStart?() }
        case .pushToTalk:
            accidentalStart = true
            DispatchQueue.main.async { self.onStart?() }
        }
    }

    private func handleRelease(_ now: TimeInterval) {
        guard isDown else { return }
        isDown = false
        let held = now - pressedAt
        accidentalStart = false
        switch mode {
        case .pushToTalk:
            DispatchQueue.main.async { self.onStop?() }
        case .toggle:
            handsFree = true                 // reste en dictée; prochain appui = stop
        case .hybrid:
            if held >= Self.holdThreshold {  // maintien = PTT -> stop au release
                DispatchQueue.main.async { self.onStop?() }
            } else {                          // tap bref = toggle mains-libres
                handsFree = true
            }
        }
    }

    private func resetPressed() {
        if isDown { isDown = false; accidentalStart = false
            DispatchQueue.main.async { self.onStop?() } }
    }
}

NOTE 1 (verbatim VoiceInk): le tap réel de VoiceInk = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: Self.eventMask, callback: callback, userInfo: ...). Il utilise .defaultTap parce qu'il supporte AUSSI des raccourcis à touche pleine qu'il supprime (return nil). Pour un simple modificateur, .listenOnly suffit et évite tout risque de blocage du flux d'événements.
NOTE 2 (verbatim VoiceInk Shortcut.swift): static var rightCommand: Self { .modifierOnly(keyCode: UInt16(kVK_RightCommand), modifierFlags: [.command]) }. Conversion des flags: NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)). Le match exact exige normalizedFlags == [.command] (rien d'autre) pour ignorer les cas multi-modificateurs.
NOTE 3 (Handy, Rust/Tauri): pas de CGEventTap direct — il délègue à sa propre crate `handy-keys` (HotkeyManager::new_with_blocking(), HotkeyState::Pressed/Released). push_to_talk est un booléen de settings : coordinator.send_input(binding_id, hotkey_string, is_pressed, settings.push_to_talk) ; en toggle => action sur press seulement ; en PTT => start au press / stop au release (src-tauri/src/shortcut/handler.rs).
NOTE 4: alternative sans keyCode pour lire les modificateurs gauche/droite via bits device-dependent: NX_DEVICELSHIFT=0x02 RSHIFT=0x04 LCTL=0x01 RCTL=0x2000 LALT=0x20 RALT=0x40 LCMD=0x08 RCMD=0x10. Fn = maskSecondaryFn.
NOTE 5: masque d'événements idiomatique = CGEventMask(1) << CGEventType.flagsChanged.rawValue (bit-shift), comme dans VoiceInk (reduce sur [keyDown, keyUp, flagsChanged]).

## Pitfalls
- Utiliser NSEvent.addGlobalMonitorForEvents au lieu d'un CGEventTap : ne reçoit rien quand ta propre app est au premier plan (il faut un local monitor en plus), ne peut jamais supprimer un événement, et exige Accessibility au lieu du plus léger Input Monitoring. Mauvais choix pour un push-to-talk.
- Croire que tapCreate non-nil == tap fonctionnel. Un tap peut être installé mais 'inert' (aucun callback), surtout après re-signature. Toujours vérifier CGEvent.tapIsEnabled() au runtime + watchdog, et gérer .tapDisabledByTimeout/.tapDisabledByUserInput sinon le hotkey meurt silencieusement.
- Supprimer (return nil) l'événement flagsChanged de la Cmd droite : casse tous les combos Cmd+X tapés avec la Cmd droite. Ne jamais swallow un modificateur seul ; laisser passer et gérer l'annulation par la fenêtre d'interruption.
- Signer en pur ad-hoc (codesign -s -) : le cdhash change à chaque rebuild, donc TCC révoque Input Monitoring + Accessibility + Micro à CHAQUE compilation, obligeant à re-cocher les cases sans arrêt. Utiliser un certificat auto-signé stable (Keychain) en dev, Developer ID en prod.
- Confondre Input Monitoring et Accessibility : les deux s'affichent sous Confidentialité mais sont des services TCC distincts (kTCCServiceListenEvent vs kTCCServicePostEvent/Accessibility). Le tap d'écoute = Input Monitoring ; l'INSERTION du texte via CGEvent.post (Cmd+V synthétique) = PostEvent/Accessibility. MoDict a besoin des DEUX, pour des raisons différentes — préflighter chacune séparément (CGPreflightListenEventAccess vs CGPreflightPostEventAccess).
- Déterminer press/release d'un modificateur en testant seulement .maskCommand device-indépendant : si les deux Cmd (gauche+droite) sont tenues et qu'on relâche la droite, .maskCommand reste actif (gauche encore down) → faux 'toujours pressé'. Tester le bit device-dependent spécifique (0x10 pour Cmd droite) pour être exact.
- Démarrer l'audio/UI instantanément au press sans grâce ni fenêtre d'interruption : chaque Cmd+C déclenche un micro-enregistrement visible. Prévoir un délai de grâce court et/ou l'annulation par détection de touche non-modificatrice dans la 1 s.
- Un callback lent (transcription, I/O) exécuté directement dans le CGEventTapCallBack : dépasse le timeout du tap → désactivation. Toujours DispatchQueue.main.async le travail lourd hors du callback (comme VoiceInk qui ne fait que muter un état et dispatch).
- Bloc oublié : après un .tapDisabledByTimeout, l'état isDown peut rester 'collé' à true (le release n'a jamais été vu) → enregistrement fantôme. Réinitialiser isDown/pressedAt lors du ré-armement (resetPressedShortcutsAfterTapInterruption dans VoiceInk).

## Sources
- https://raw.githubusercontent.com/Beingpax/VoiceInk/main/VoiceInk/Shortcuts/ShortcutMonitor.swift
- https://raw.githubusercontent.com/Beingpax/VoiceInk/main/VoiceInk/Shortcuts/Shortcut.swift
- https://raw.githubusercontent.com/Beingpax/VoiceInk/main/VoiceInk/Shortcuts/RecordingShortcutManager.swift
- https://github.com/Beingpax/VoiceInk
- https://raw.githubusercontent.com/cjpais/Handy/main/src-tauri/src/shortcut/handler.rs
- https://raw.githubusercontent.com/cjpais/Handy/main/src-tauri/src/shortcut/handy_keys.rs
- https://github.com/cjpais/Handy
- https://developer.apple.com/documentation/coregraphics/cgpreflightlisteneventaccess()
- https://developer.apple.com/documentation/coregraphics/cgrequestlisteneventaccess()
- https://developer.apple.com/documentation/coregraphics/cgrequestposteventaccess()
- https://developer.apple.com/forums/thread/707680
- https://developer.apple.com/forums/thread/789896
- https://github.com/nikitabobko/AeroSpace/issues/1012
- https://danielraffel.me/til/2026/02/19/cgevent-taps-and-code-signing-the-silent-disable-race/
- https://github.com/philptr/EventTapCore
- https://hacktricks.wiki/en/macos-hardening/macos-security-and-privilege-escalation/macos-security-protections/macos-input-monitoring-screen-capture-accessibility.html
- https://github.com/asmvik/yabai/wiki/Installing-yabai-(from-HEAD)
- https://github.com/NousResearch/hermes-agent/issues/49110
- https://github.com/lwouis/alt-tab-macos/blob/master/src/logic/events/KeyboardEvents.swift
