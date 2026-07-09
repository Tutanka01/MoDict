# Research: audio-pipeline

## Summary
Le pipeline cible pour MoDict est: AVAudioEngine.inputNode → installTap (format natif du hardware, ~48kHz stéréo) → AVAudioConverter → 16kHz mono Float32 [Float] → FluidAudio AsrManager.transcribe. FluidAudio ne fournit PAS de capture micro: il attend des [Float] 16kHz mono déjà convertis (via son AudioConverter.resampleBuffer, Apache-2.0), donc c'est à MoDict d'implémenter la capture. J'ai lu le code source réel de 5 apps qui font exactement ce cas d'usage: parakey (rcourtman, push-to-talk Parakeet+FluidAudio ~100ms, le plus proche de MoDict), foxsay (skulkworks), macparakeet (moona3k, SPM sans Xcode, gestion device la plus robuste), WhisperKit AudioProcessor (référence gold-standard Argmax), et FluidAudio lui-même. Point critique #1: sur macOS il n'y a PAS d'AVAudioSession (API iOS uniquement) — la sélection de device se fait via CoreAudio (AudioUnitSetProperty kAudioOutputUnitProperty_CurrentDevice). Point critique #2: si on réutilise un seul AVAudioConverter sur chaque callback du tap, l'inputBlock doit retourner .noDataNow et JAMAIS .endOfStream (sinon le converter passe en état terminal et renvoie 0 samples sur tous les buffers suivants — le bug "première dictée OK, les suivantes vides"). Pour la latence, deux stratégies coexistent dans la nature: (a) cold-start de l'engine à l'appui touche (parakey — pas de point orange permanent, mais latence 1er buffer), pré-validée par un start/stop de warm-up au lancement; (b) garder le stream micro ouvert après la 1ère dictée pour des démarrages instantanés (superwhisper/Weesper — point orange permanent, coût batterie). Le niveau audio pour la waveform se calcule par RMS par buffer (vDSP_rmsqv) converti en dB puis mappé/lissé. Les sons de feedback discrets se jouent via NSSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff") pour début, Pop.aiff pour fin, Basso.aiff pour erreur. Pour une app SPM non-sandboxée en menu-bar (.app), l'Info.plist doit être un VRAI fichier dans Contents/Info.plist (NSMicrophoneUsageDescription obligatoire), et sur macOS Tahoe 26 l'entitlement com.apple.security.device.audio-input est requis avec signature Hardened Runtime sinon le prompt micro ne se déclenche jamais. La gestion du changement de device (AirPods branchés en cours) passe par l'observation de .AVAudioEngineConfigurationChange + reconstruction de l'engine.</summary>
<recommendations>
<recommendation>
<topic>Architecture du pipeline de capture</topic>
<recommendation>Créer une classe `MicrophoneCapture` NON @MainActor (marquée @unchecked Sendable), qui possède l'AVAudioEngine, un unique AVAudioConverter réutilisé, un NSLock et un accumulateur de samples. installTap avec `format: inputNode.outputFormat(forBus: 0)` (format natif) et bufferSize 4096. Dans le callback (qui tourne sur le thread audio temps-réel), convertir vers 16kHz mono Float32 puis accumuler sous lock. Ne PAS toucher d'état @MainActor dans le tap. Exposer les [Float] finaux à FluidAudio via `AsrManager.transcribe(samples)`.</recommendation>
<rationale>C'est le pattern commun à parakey, foxsay et WhisperKit. Le tap AVFoundation délivre les buffers sur un thread audio dédié, pas le main thread; en Swift 6 concurrency il faut isoler cet état via NSLock plutôt que via l'acteur. FluidAudio attend explicitement des [Float] 16kHz mono (docs AudioConversion.md).</rationale>
</recommendation>
<recommendation>
<topic>Conversion 16kHz mono — AVAudioConverter réutilisé + .noDataNow</topic>
<recommendation>Créer UN SEUL AVAudioConverter (from: format natif du tap, to: AVAudioFormat 16kHz/1ch/Float32/non-interleaved) au démarrage de l'engine, et le réutiliser sur chaque buffer. Dans l'AVAudioConverterInputBlock, retourner le buffer avec status `.haveData` la première fois puis `.noDataNow` (via un flag didProvide), JAMAIS `.endOfStream`. Dimensionner le buffer de sortie à `frameLength * (16000/inputSampleRate) + 1024`.</recommendation>
<rationale>parakey documente précisément ce bug: signaler .endOfStream met le converter en état terminal → il produit 0 sample sur tous les appels suivants ("first capture 0.10s, every press after 0.00s"). .noDataNow signifie "plus d'input pour CET appel mais le flux continue". Recréer un converter par buffer marche aussi (approche FluidAudio stateless) mais alloue plus.</rationale>
</recommendation>
<recommendation>
<topic>Latence / warm-up (pas d'AVAudioSession sur macOS)</topic>
<recommendation>Ne PAS garder l'engine tournant en permanence par défaut. Faire comme parakey: au lancement, un start/stop de warm-up (démarre l'engine puis l'arrête immédiatement) pour amorcer CoreAudio et valider la permission, puis démarrer l'engine à chaud à chaque appui sur Command droite. Optionnellement offrir un mode "démarrage instantané" qui garde le tap ouvert et jette les frames tant qu'un flag `_isRunning` est false (design de parakey avec `startEngine(recordingImmediately:)` + `beginRecording()`). Le vrai `start()` d'AVAudioEngine prend typiquement quelques dizaines de ms; c'est la transcription qui domine la latence perçue.</rationale>
<rationale>Garder le micro ouvert en continu allume le point orange macOS en permanence et bloque le micro pour d'autres apps (coût batterie/privacy) — c'est ce que fait superwhisper/Weesper pour la vitesse. parakey privilégie le cold-start pour éviter le point orange, atteignant ~100ms key-release→texte car Parakeet sur ANE est rapide. IMPORTANT: sur macOS AVAudioSession n'existe pas (API iOS) — ne jamais appeler setCategory/setActive.</rationale>
</recommendation>
<recommendation>
<topic>Waveform: RMS par buffer + mapping dB + lissage</topic>
<recommendation>Par buffer, calculer le RMS (vDSP_rmsqv ou somme des carrés clampés). Mapper en niveau visible: `db = 20*log10(rms)`; `gated = (db + 52)/20`; gate si <0.06; `level = pow(clamp(gated,0,1), 0.42)` (courbe perceptuelle de parakey). Stocker `latestLevel` sous lock avec un numéro de séquence; l'UI le lit à ~60Hz via un Timer/DisplayLink et applique un lissage EMA (`smoothed += (level - smoothed) * alpha`, alpha ~0.2-0.3 attack, plus lent en release) pour une waveform fluide.</rationale>
<rationale>Un simple peak (max abs, foxsay) fonctionne mais le RMS→dB donne un meter plus stable et représentatif de la voix. Le mapping dB de parakey est calibré pour que la parole normale ouvre visiblement le HUD sans saturer. Le lissage EMA évite le scintillement d'une waveform monochrome minimaliste type superwhisper.</rationale>
</recommendation>
<recommendation>
<topic>Changement de device audio (AirPods branchés en cours)</topic>
<recommendation>Observer `NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, ...)`. À la réception, si l'engine s'est arrêté et qu'on était en enregistrement, reconstruire l'engine (nouvel AVAudioEngine, recréer le converter car le format natif a changé, réinstaller le tap, restart). Optionnellement observer aussi `kAudioHardwarePropertyDefaultInputDevice` via AudioObjectAddPropertyListenerBlock pour rafraîchir la liste des devices. Toujours recréer un AVAudioEngine neuf plutôt que réutiliser l'ancien.</rationale>
<rationale>Core Audio poste .AVAudioEngineConfigurationChange quand la chaîne d'input est renégociée (changement de device par défaut, sample-rate, prise de contrôle exclusive). Les AirPods exposent un device d'entrée mono 16kHz (mode HFP/SCO) différent — le format change donc le converter doit être recréé. macparakeet implémente exactement ce self-healing restart (recoverFromConfigurationChange).</rationale>
</recommendation>
<recommendation>
<topic>Sélection explicite du micro via CoreAudio</topic>
<recommendation>Pour permettre à l'utilisateur de choisir un micro autre que le défaut: `AudioUnitSetProperty(inputNode.audioUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, size)` AVANT `engine.start()`. Énumérer les devices via `AudioObjectGetPropertyData` avec `kAudioHardwarePropertyDevices`, filtrer ceux ayant des canaux d'entrée (`kAudioDevicePropertyStreamConfiguration` scope Input), récupérer nom (`kAudioDevicePropertyDeviceNameCFString`) et UID (`kAudioDevicePropertyDeviceUID`, persistant entre reboots).</rationale>
<rationale>Sur macOS c'est la seule voie (pas de setPreferredInput d'AVAudioSession). Stocker l'UID (pas l'AudioDeviceID qui change) dans UserDefaults. Code identique dans foxsay, parakey, WhisperKit.</rationale>
</recommendation>
<recommendation>
<topic>Permission micro dans une app SPM non-sandboxée</topic>
<recommendation>Demander via `AVCaptureDevice.requestAccess(for: .audio)` (ou `AVAudioApplication.requestRecordPermission()` macOS 14+). L'Info.plist DOIT être un vrai fichier `Contents/Info.plist` du bundle .app avec `NSMicrophoneUsageDescription` (et `NSAppleEventsUsageDescription` si on colle via System Events, `LSUIElement=true` pour menu-bar). Ajouter `entitlements.plist` avec `com.apple.security.device.audio-input` (+ `com.apple.security.device.microphone` en fallback legacy). Signer: `codesign --force --deep --options runtime --entitlements entitlements.plist --timestamp App.app`.</rationale>
<rationale>Sur macOS Tahoe 26, un build Developer-ID + Hardened Runtime SANS l'entitlement audio-input n'obtient jamais d'entrée TCC et le prompt ne se déclenche jamais silencieusement (documenté dans entitlements.plist de parakey). Sans NSMicrophoneUsageDescription, l'app crashe à l'accès micro.</rationale>
</recommendation>
<recommendation>
<topic>Packaging SPM → .app sans Xcode</topic>
<recommendation>`swift build -c release`, puis assembler à la main: `Contents/MacOS/<bin>`, `Contents/Info.plist`, `Contents/Resources/`. Ne PAS déclarer de `resources:` dans le target SwiftPM (génère un `<Package>_<Target>.bundle` que `codesign --deep` refuse car sans Info.plist) — copier les assets dans Contents/Resources via un script de build. Dépendance FluidAudio épinglée par revision dans Package.swift, platforms `.macOS("14.0")`, swift-tools-version 6.0.</rationale>
<rationale>C'est exactement l'approche de parakey (ship-swift.sh) et macparakeet, tous deux SPM sans Xcode. Le bundle .app avec Info.plist réel est nécessaire pour que Launch Services et TCC identifient l'app; l'astuce `-sectcreate __TEXT __info_plist` (polpiella) est réservée aux outils CLI nus, pas aux .app menu-bar.</rationale>
</recommendation>
<recommendation>
<topic>Sons de feedback discrets</topic>
<recommendation>Précharger 3 NSSound au lancement: `NSSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true)` (début), `Pop.aiff` (fin), `Basso.aiff` (erreur). Jouer avec `sound.stop(); sound.play()` pour permettre un re-déclenchement rapide. Rendre optionnel (toggle UserDefaults). Pour un design plus premium, bundler ses propres AIFF courts (<150ms) dans Contents/Resources. Jouer le son de début LÉGÈREMENT avant d'ouvrir le tap, ou compter sur le fait que l'utilisateur parle après.</rationale>
<rationale>Pattern exact de parakey. byReference:true évite de charger tout le fichier en RAM. Attention: un son joué dans les HP peut fuiter dans le micro intégré et polluer la transcription — d'où le décalage temporel ou un son bref/discret. NSSound est le plus simple; AVAudioPlayer ou AudioServicesPlaySystemSound sont des alternatives.</rationale>
</recommendation>
<recommendation>
<topic>Robustesse: garde contre l'absence de micro</topic>
<recommendation>Avant d'accéder à `engine.inputNode`, vérifier qu'un device d'entrée existe via `AudioObjectGetPropertyData(kAudioHardwarePropertyDefaultInputDevice)` et `deviceID != kAudioDeviceUnknown`. Utiliser des generation counters (incrémentés à chaque begin/end) pour ne pas mélanger des frames "straggler" d'un tap en vol dans le clip suivant, car `removeTap` n'attend pas la fin d'un callback en cours.</rationale>
<rationale>foxsay documente que l'accès à inputNode sans device d'entrée provoque une exception Objective-C non rattrapable (crash). Le generation counter de parakey évite des artefacts entre deux dictées rapprochées.</rationale>
</recommendation>
</recommendations>
<code_notes>
CIBLE: macOS 14+, Swift 6, SPM sans Xcode. FluidAudio attend [Float] 16kHz mono. Pipeline complet ci-dessous (synthèse de parakey/foxsay/WhisperKit, tous sous licences permissives — vérifier avant copie).

--- 1. MicrophoneCapture.swift (capture + conversion) ---
```swift
import AVFoundation
import CoreAudio
import Accelerate

let TARGET_SAMPLE_RATE: Double = 16_000

final class MicrophoneCapture: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var isRecording = false
    private var generation: UInt64 = 0
    private var latestLevel: Float = 0
    private var configObserver: NSObjectProtocol?

    // Callback UI (thread audio -> à re-dispatcher sur main côté appelant)
    var onLevel: (@Sendable (Float) -> Void)?

    // Garde: accéder à inputNode sans device d'entrée => exception ObjC non rattrapable
    private func hasInputDevice() -> Bool {
        var id = AudioDeviceID()
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                            &addr, 0, nil, &size, &id)
        return st == noErr && id != kAudioDeviceUnknown
    }

    func startRecording(preferredDeviceUID: String? = nil) throws {
        guard hasInputDevice() else { throw CaptureError.noInputDevice }

        let input = engine.inputNode
        if let uid = preferredDeviceUID, let devID = Self.deviceID(forUID: uid) {
            Self.setInputDevice(devID, on: input)   // via CoreAudio, PAS AVAudioSession
        }

        // Format NATIF du hardware (ex: 48kHz stéréo). NE PAS forcer 16kHz dans installTap.
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.invalidFormat
        }
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: TARGET_SAMPLE_RATE,
                                   channels: 1, interleaved: false)!
        // UN SEUL converter réutilisé (défaut = rapide; NE PAS mettre Mastering en live)
        converter = AVAudioConverter(from: inputFormat, to: target)

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        generation &+= 1
        isRecording = true
        latestLevel = 0
        lock.unlock()

        // bufferSize = HINT (le hardware peut ignorer). 4096 ~ bon compromis.
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buf, _ in
            self?.handleTap(buf, target: target)   // thread audio temps-réel
        }
        try engine.start()
        installConfigObserver()
    }

    func stopRecording() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        removeConfigObserver()
        lock.lock()
        isRecording = false
        generation &+= 1
        let out = samples
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        engine.stop(); engine.reset()
        engine = AVAudioEngine()   // instance neuve => coreaudiod libère l'agrégat
        return out
    }

    private func handleTap(_ buffer: AVAudioPCMBuffer, target: AVAudioFormat) {
        lock.lock()
        let running = isRecording
        let gen = generation
        let conv = converter
        lock.unlock()
        guard running, let conv else { return }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }

        // CRUCIAL: .noDataNow (jamais .endOfStream) car converter réutilisé à chaque buffer
        var provided = false
        var err: NSError?
        let status = conv.convert(to: out, error: &err) { _, s in
            if provided { s.pointee = .noDataNow; return nil }
            provided = true; s.pointee = .haveData; return buffer
        }
        guard status != .error, let ch = out.floatChannelData?[0] else { return }

        let n = Int(out.frameLength)
        var arr = [Float](repeating: 0, count: n)
        // RMS pour la waveform (vDSP)
        var rms: Float = 0
        vDSP_rmsqv(ch, 1, &rms, vDSP_Length(n))
        memcpy(&arr, ch, n * MemoryLayout<Float>.size)
        let level = Self.visibleLevel(rms: rms)

        lock.lock()
        if isRecording && generation == gen {   // generation => pas de frames "straggler"
            samples.append(contentsOf: arr)
            latestLevel = level
        }
        lock.unlock()
        onLevel?(level)
    }

    // Mapping RMS -> niveau visible [0,1] (courbe perceptuelle, calibrée voix, façon parakey)
    static func visibleLevel(rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        let gated = (db + 52) / 20
        guard gated > 0.06 else { return 0 }
        return max(0, min(1, pow(max(0, min(1, gated)), 0.42)))
    }

    private func installConfigObserver() {
        removeConfigObserver()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.isRecording else { return }
            // AirPods branchés / device changé => reconstruire (format natif a changé)
            let clip = self.stopRecording()
            _ = clip // à traiter côté appelant si besoin
            try? self.startRecording()
        }
    }
    private func removeConfigObserver() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
    }
    enum CaptureError: Error { case noInputDevice, invalidFormat }
}
```

--- 2. Sélection device via CoreAudio (extraits) ---
```swift
extension MicrophoneCapture {
    static func setInputDevice(_ id: AudioDeviceID, on node: AVAudioInputNode) {
        guard let unit = node.audioUnit else { return }
        var dev = id
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &dev,
                             UInt32(MemoryLayout<AudioDeviceID>.size))
    }
    static func deviceID(forUID uid: String) -> AudioDeviceID? { /* énumération kAudioHardwarePropertyDevices + match kAudioDevicePropertyDeviceUID */ nil }
}
```

--- 3. Permission (macOS, pas d'AVAudioSession) ---
```swift
import AVFoundation
func requestMic() async -> Bool {
    if #available(macOS 14, *) { return await AVAudioApplication.requestRecordPermission() }
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return true
    case .notDetermined:
        return await withCheckedContinuation { c in
            AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) } }
    default: return false
    }
}
```

--- 4. Sons de feedback (NSSound, façon parakey) ---
```swift
import AppKit
enum Feedback {
    static let start = NSSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true)
    static let done  = NSSound(contentsOfFile: "/System/Library/Sounds/Pop.aiff",  byReference: true)
    static let error = NSSound(contentsOfFile: "/System/Library/Sounds/Basso.aiff", byReference: true)
    static func playStart() { start?.stop(); start?.play() }
    static func playDone()  { done?.stop();  done?.play() }
}
```

--- 5. Intégration FluidAudio ---
```swift
// samples = capture.stopRecording()  // [Float] déjà 16kHz mono
let result = try await asrManager.transcribe(samples)   // FluidAudio AsrManager
// (Alternative si buffer brut: AudioConverter().resampleBuffer(pcmBuffer) -> [Float])
```

--- 6. Package.swift ---
```swift
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "MoDict",
  platforms: [.macOS("14.0")],
  products: [.executable(name: "MoDict", targets: ["MoDict"])],
  dependencies: [
    .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.6.0")
  ],
  targets: [
    .executableTarget(name: "MoDict",
      dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
      // PAS de resources: ici -> évite le <Package>_<Target>.bundle refusé par codesign --deep
    )
  ])
```

--- 7. Info.plist (VRAI fichier -> Contents/Info.plist) ---
Clés critiques: LSUIElement=true (menu-bar), LSMinimumSystemVersion=14.0, NSHighResolutionCapable=true,
NSMicrophoneUsageDescription="MoDict enregistre l'audio pendant que vous maintenez la touche de dictée, puis le transcrit localement.",
NSAppleEventsUsageDescription (si collage via System Events), CFBundleIdentifier, CFBundleExecutable.

--- 8. entitlements.plist ---
com.apple.security.device.audio-input = true   (REQUIS macOS Tahoe 26 Hardened Runtime, sinon prompt jamais déclenché)
com.apple.security.device.microphone = true    (fallback legacy)

--- 9. Build + bundle + signature (sans Xcode) ---
```
swift build -c release
mkdir -p MoDict.app/Contents/MacOS MoDict.app/Contents/Resources
cp .build/release/MoDict MoDict.app/Contents/MacOS/MoDict
cp Info.plist            MoDict.app/Contents/Info.plist
codesign --force --deep --options runtime \
  --entitlements entitlements.plist --timestamp \
  --sign "Developer ID Application: ..." MoDict.app
```

REF FluidAudio AudioConverter (Apache-2.0): resampleBuffer(_:) fast-path si déjà 16kHz mono; sinon convertBuffer via AVAudioConverter, OSAllocatedUnfairLock pour l'inputBlock en Swift 6, extractFloatArray via vDSP_mmov, configure() met AVSampleRateConverterAlgorithm_Mastering + AVAudioQuality.max (OK offline, à ÉVITER en live).
</code_notes>
<pitfalls>
<item>Sur macOS, AVAudioSession N'EXISTE PAS (API iOS/watchOS uniquement). Appeler setCategory/setActive ne compile pas / est indisponible. La config de session et la sélection de device se font via CoreAudio (AudioObject*/AudioUnitSetProperty). WhisperKit isole tout ce code avec #if !os(macOS).</item>
<item>Réutiliser un seul AVAudioConverter sur chaque callback du tap ET retourner .endOfStream dans l'inputBlock met le converter en état terminal: il renvoie 0 sample sur TOUS les buffers suivants (bug "1ère dictée = 0.10s, toutes les suivantes = 0.00s"). Retourner .noDataNow après avoir fourni le buffer une fois.</item>
<item>Accéder à AVAudioEngine.inputNode quand aucun device d'entrée n'est présent lève une exception Objective-C NON rattrapable en Swift (crash). Vérifier kAudioHardwarePropertyDefaultInputDevice != kAudioDeviceUnknown d'abord (foxsay hasDefaultInputDevice).</item>
<item>installTap avec un `format` dont le sampleRate/channels ne correspond pas au format natif du inputNode lève "required condition is false: format.sampleRate == hwFormat.sampleRate". Utiliser inputNode.outputFormat(forBus:0) (ou format: nil) et convertir APRÈS dans le tap.</item>
<item>Le callback du tap tourne sur un thread audio temps-réel, PAS le main thread ni l'acteur. Toucher directement de l'état @MainActor est une data race (et interdit par Swift 6). Protéger l'état partagé par NSLock; marquer la classe @unchecked Sendable / le processor nonisolated.</item>
<item>Garder l'AVAudioEngine tournant en permanence maintient le point orange micro macOS allumé et retient le micro vis-à-vis d'autres apps (coût batterie + perception privacy). C'est le compromis vitesse de superwhisper/Weesper. Le cold-start à l'appui touche (parakey) évite le point orange permanent mais ajoute la latence du 1er buffer.</item>
<item>AirPods branchés en cours de session: bascule vers le device d'entrée mono ~16kHz mode HFP/SCO (et l'output passe en qualité "appel" mono). Le format natif change donc le converter DOIT être recréé; l'engine poste .AVAudioEngineConfigurationChange et peut s'arrêter — il faut l'observer et reconstruire un AVAudioEngine neuf.</item>
<item>Pour une app .app menu-bar, l'Info.plist doit être un VRAI fichier dans Contents/Info.plist (lu par Launch Services + TCC). L'astuce linker -sectcreate __TEXT __info_plist (polpiella) ne vaut que pour des outils CLI nus, pas pour un bundle .app. Sans NSMicrophoneUsageDescription l'app crashe à l'accès micro.</item>
<item>macOS Tahoe 26 + build Developer-ID + Hardened Runtime SANS l'entitlement com.apple.security.device.audio-input: l'app n'obtient jamais d'entrée dans Réglages → Confidentialité → Microphone et le prompt ne se déclenche JAMAIS silencieusement. Signer avec --options runtime --entitlements.</item>
<item>Déclarer des `resources:` dans le target SwiftPM génère un `<Package>_<Target>.bundle` que `codesign --deep` refuse (pas d'Info.plist). Copier les assets manuellement dans Contents/Resources via un script.</item>
<item>Le son de feedback joué dans les haut-parleurs (surtout micro intégré) peut fuiter dans l'enregistrement. Mitiger: son très court/discret, le jouer légèrement avant d'ouvrir le tap, ou activer VPIO (setVoiceProcessingEnabled) pour l'annulation d'écho (mais VPIO change le format et duck l'audio des autres apps — désactiver ducking + AGC comme macparakeet).</item>
<item>AVSampleRateConverterAlgorithm_Mastering + AVAudioQuality.max (utilisé par FluidAudio pour les fichiers) est coûteux en CPU si appliqué à chaque buffer du tap (~50 Hz). Pour la conversion live, laisser l'algorithme par défaut d'AVAudioConverter.</item>
<item>bufferSize d'installTap n'est qu'une indication; la taille réelle des buffers est décidée par le hardware. Ne pas supposer un nombre de frames exact. removeTap n'attend pas la fin d'un callback en vol — utiliser un generation counter pour ne pas mélanger des frames d'une dictée à la suivante.</item>
</pitfalls>
<sources>
<item>https://github.com/FluidInference/FluidAudio/blob/main/Sources/FluidAudio/Shared/AudioConverter.swift</item>
<item>https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Guides/AudioConversion.md</item>
<item>https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/GettingStarted.md</item>
<item>https://github.com/argmaxinc/WhisperKit/blob/main/Sources/WhisperKit/Core/Audio/AudioProcessor.swift</item>
<item>https://github.com/rcourtman/parakey/blob/main/swift/Sources/Parakey/main.swift</item>
<item>https://github.com/rcourtman/parakey/blob/main/swift/Info.plist</item>
<item>https://github.com/rcourtman/parakey/blob/main/entitlements.plist</item>
<item>https://github.com/rcourtman/parakey/blob/main/ship-swift.sh</item>
<item>https://github.com/rcourtman/parakey/blob/main/swift/Package.swift</item>
<item>https://github.com/skulkworks/foxsay/blob/main/FoxSayPackage/Sources/FoxSayFeature/Core/AudioEngine.swift</item>
<item>https://github.com/moona3k/macparakeet/blob/main/Sources/MacParakeetCore/Audio/MicrophoneEnginePlatform.swift</item>
<item>https://github.com/OverseedAI/overwhisper</item>
<item>https://github.com/watzon/pindrop</item>
<item>https://supermegaultragroovy.com/2021/01/28/more-on-avaudioengine-airpods/</item>
<item>https://weesperneonflow.ai/en/help/privacy/pv-002-microphone-indicator-macos/</item>
<item>https://developer.apple.com/documentation/appkit/nssound</item>
<item>https://developer.apple.com/documentation/avfaudio/avaudioconverter</item>
<item>https://www.polpiella.dev/info-plist-swift-cli/</item>
<item>https://theswiftdev.com/how-to-build-macos-apps-using-only-the-swift-package-manager/</item>
<item>https://samasaur1.github.io/blog/graphical-macos-apps-with-spm</item>
<item>https://github.com/ggml-org/whisper.cpp/issues/2008</item>
</sources>
</invoke>


## Recommendations

## Code notes


## Pitfalls

## Sources
