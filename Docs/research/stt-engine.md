# Research: stt-engine

## Summary
Pour MoDict (dictée push-to-talk macOS 14+, Apple Silicon, SwiftPM sans Xcode, français requis), le moteur STT recommandé est FluidAudio (Apache-2.0), qui exécute NVIDIA Parakeet-TDT 0.6B en CoreML sur l'ANE avec ~66 Mo de mémoire de travail et un RTFx batch d'environ 190x sur M4 Pro (une phrase de 10 s se transcrit en ~50-90 ms). Il faut le modèle v3 (multilingue, 25 langues) pour le français : WER français 5,15% et anglais 4,85% sur Fleurs (source NVIDIA), ponctuation/majuscules automatiques ; le v2 est plus précis en anglais mais anglais-seulement, donc à exclure si le français compte. L'API réelle en v0.15.5 (dernière release, 2026-07-07) est un actor AsrManager + un struct AsrModels : AsrModels.downloadAndLoad(version:.v3, progressHandler:) télécharge depuis HuggingFace (FluidInference/parakeet-tdt-0.6b-v3-coreml) avec progression exposée (DownloadProgress.fractionCompleted + phase), puis asr.loadModels(models) et asr.transcribe(samples, decoderState:&state, language:). ATTENTION: le README et la doc GettingStarted montrent une API simplifiée transcribe(samples, source:) / configure(models:) qui N'EXISTE PAS dans le code compilé — il faut obligatoirement gérer un TdtDecoderState inout. Le download réel est ~482 Mo (encodeur int8) ou ~335 Mo (int4), pas les ~3 Go du dépôt HF qui contient toutes les variantes ; downloadAndLoad ne récupère que les fichiers de la version choisie. FluidAudio offre aussi un mode streaming (SlidingWindowAsrManager, partiels temps réel) mais pour du push-to-talk le batch sur la phrase enregistrée est le plus simple et le plus précis. parakeet-mlx (Python/MLX) est disqualifiant (runtime Python, GPU, ~2 Go RAM, non intégrable en app Swift native). WhisperKit (Argmax, MIT) est une alternative Swift/CoreML crédible (99 langues, streaming) mais Whisper est plus lourd/lent sur ANE et hallucine plus sur les courtes énonciations que Parakeet. La nouvelle API Apple SpeechAnalyzer/SpeechTranscriber (macOS 26, WWDC25) mérite d'être un 2e moteur optionnel : native, français supporté (fr_FR/fr_CA/fr_BE/fr_CH), assets gérés par le système, ~2,2x plus rapide que MacWhisper Large v3 Turbo — mais macOS 26 uniquement, donc @available obligatoire, ne peut pas être le moteur unique d'une cible macOS 14+. Architecture recommandée: un protocole Swift TranscriptionEngine (actor) avec deux conformances, FluidAudioEngine (défaut, plancher macOS 14) et AppleSpeechEngine (macOS 26+).

## Recommendations
### Moteur STT par défaut
**Reco:** Adopter FluidAudio + Parakeet-TDT 0.6B v3 (CoreML/ANE) comme moteur principal, épinglé en SPM sur .exact("0.15.5") ou .upToNextMinor(from:"0.15.5"). Charger le modèle .v3 (multilingue) pour couvrir le français.

**Pourquoi:** Meilleur compromis latence/mémoire/qualité pour un daemon push-to-talk en arrière-plan: ~190x RTFx batch, ~66 Mo de mémoire de travail (vs ~2 Go en MLX/GPU), 100% ANE (faible conso, pas de dispatch GPU), WER FR 5,15%, ponctuation auto. SDK Apache-2.0, SwiftPM pur sans Xcode. Fonctionne dès macOS 14, couvrant toute la cible.

### Mode d'inférence pour push-to-talk
**Reco:** Utiliser le mode BATCH: enregistrer l'énoncé pendant l'appui sur Cmd droite, puis à la relâche appeler transcribe(samples, decoderState:&state) une seule fois. Créer un TdtDecoderState neuf par énoncé. Réserver le streaming (SlidingWindowAsrManager) à une éventuelle option 'aperçu en direct'.

**Pourquoi:** Pour une énonciation courte (<15 s), le batch est plus simple, plus précis (pas d'artefacts de fenêtres glissantes) et déjà quasi instantané (10 s -> ~50-90 ms). Le streaming ajoute de la complexité (partiels volatile/confirmed, EOU) sans bénéfice pour une insertion au curseur à la relâche de touche.

### Protocole TranscriptionEngine multi-moteurs
**Reco:** Définir un protocole TranscriptionEngine: Actor avec prepare(progress:), transcribe(samples:locale:) -> TranscriptionResult, isAvailable, supportedLocales, unload(). Fournir FluidAudioEngine (défaut) et, gated @available(macOS 26,*), AppleSpeechEngine. Optionnellement un sous-protocole StreamingTranscriptionEngine pour les partiels.

**Pourquoi:** Découple l'UI/insertion du moteur, permet de basculer FluidAudio <-> Apple SpeechAnalyzer selon la version d'OS et la préférence utilisateur, et laisse la porte ouverte à WhisperKit sans refactor. isAvailable encapsule les contraintes (Apple Silicon pour FluidAudio, macOS 26 pour Apple).

### Apple SpeechAnalyzer comme 2e moteur optionnel
**Reco:** Implémenter AppleSpeechEngine (SpeechTranscriber + SpeechAnalyzer) derrière @available(macOS 26,*) comme moteur alternatif sélectionnable, pas comme moteur unique. S'appuyer sur AssetInventory.assetInstallationRequest pour les modèles gérés par l'OS.

**Pourquoi:** Sur macOS 26 c'est natif, sans modèle à télécharger/embarquer (assets système), français supporté, ~2,2x plus rapide que MacWhisper Large v3 Turbo. Mais macOS 26-only l'empêche d'être le plancher d'une cible macOS 14+. Excellent pour réduire le poids de l'app et offrir un choix. Repo de référence: FluidInference/swift-scribe.

### Écarter parakeet-mlx et positionner WhisperKit
**Reco:** Ne PAS utiliser parakeet-mlx (Python/MLX). Garder WhisperKit (Argmax, MIT) seulement comme fallback documenté si un jour on veut 99 langues ou un support Whisper/Intel.

**Pourquoi:** parakeet-mlx impose un runtime Python et l'inférence GPU/MLX (~2 Go RAM), impossible à empaqueter proprement dans une app Swift signée. WhisperKit est Swift/CoreML valable mais Whisper est plus lourd sur ANE et hallucine davantage sur les courtes énonciations de dictée que Parakeet-TDT; il n'apporte rien de décisif ici.

### Téléchargement du modèle et UX premier lancement
**Reco:** Brancher progressHandler de downloadAndLoad sur une UI de progression (barre 0-100% + phase). Stocker/valider via AsrModels.modelsExist / isModelValid. Envisager encoderPrecision:.int4 (~335 Mo) si le poids compte, sinon .int8 par défaut (~482 Mo).

**Pourquoi:** Le download initial (plusieurs centaines de Mo depuis HuggingFace) est le seul point de friction UX; la progression est nativement exposée (DownloadProgress.fractionCompleted + DownloadPhase.downloading/compiling). int4 divise ~par deux le poids avec un impact WER modéré, utile pour une app grand public au niveau superwhisper/Wispr Flow.


## Code notes
API FLUIDAUDIO — vérifiée sur le tag release v0.15.5 (dernière, publiée 2026-07-07). SPM: swift-tools 6.0, platforms .macOS(.v14)/.iOS(.v17), Apple Silicon requis (SystemInfo.isAppleSilicon -> ASRError.unsupportedPlatform sur Intel). License SDK: Apache-2.0. Poids Parakeet: CC-BY-4.0 (NVIDIA, attribution requise).

Package.swift:
  .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5")
  // puis .product(name: "FluidAudio", package: "FluidAudio")

Types clés (AsrModels.swift, AsrTypes.swift, ModelNames.swift):
  public enum AsrModelVersion: Sendable { case v2; case v3; case tdtCtc110m; case tdtJa }
  public enum ParakeetEncoderPrecision: String, Sendable, CaseIterable { case int8; case int4 }
  public typealias ProgressHandler = @Sendable (DownloadProgress) -> Void
  public struct DownloadProgress: Sendable { public let fractionCompleted: Double; public let phase: DownloadPhase }
  public enum DownloadPhase: Sendable { case listing; case downloading(completedFiles: Int, totalFiles: Int); case compiling(modelName: String) }
  public struct ASRResult: Codable, Sendable { public let text: String; public let confidence: Float; public let duration: TimeInterval; public let processingTime: TimeInterval; public let tokenTimings: [TokenTiming]?; public var rtfx: Float { Float(duration)/Float(processingTime) } }
  public enum AudioSource: Sendable { case microphone; case system }
  public struct TdtDecoderState: Sendable { public init(decoderLayers: Int = 2) throws; public static func make(decoderLayers: Int = 2) -> TdtDecoderState }

Chargement (signature exacte):
  public static func AsrModels.downloadAndLoad(
      to directory: URL? = nil,
      configuration: MLModelConfiguration? = nil,
      version: AsrModelVersion = .v3,
      encoderPrecision: ParakeetEncoderPrecision = .int8,
      encoderComputeUnits: MLComputeUnits? = nil,
      progressHandler: ProgressHandler? = nil
  ) async throws -> AsrModels
  // aussi: AsrModels.download(...), .load(from:...), .loadFromCache(...), .modelsExist(at:version:), .isModelValid(version:)

AsrManager (actor) — API réelle:
  public actor AsrManager {
    public init(config: ASRConfig = .default, models: AsrModels? = nil)
    public func loadModels(_ models: AsrModels) async throws
    public var isAvailable: Bool { get }
    public var decoderLayerCount: Int { get }   // 2 pour v2/v3
    public var transcriptionProgressStream: AsyncThrowingStream<Double, Error> { get async }  // audio >~15s
    public func transcribe(_ audioSamples: [Float], decoderState: inout TdtDecoderState, language: Language? = nil) async throws -> ASRResult
    public func transcribe(_ url: URL, decoderState: inout TdtDecoderState, language: Language? = nil) async throws -> ASRResult
    public func transcribe(_ audioBuffer: AVAudioPCMBuffer, decoderState: inout TdtDecoderState, language: Language? = nil) async throws -> ASRResult
    public func reset(); public func cleanup()
  }

Exemple BATCH push-to-talk (recommandé):
  let models = try await AsrModels.downloadAndLoad(version: .v3) { p in
      Task { @MainActor in self.progress = p.fractionCompleted }   // 0...1
  }
  let asr = AsrManager(config: .default)
  try await asr.loadModels(models)
  // à la relâche de Cmd droite, samples = [Float] 16kHz mono capté via AVAudioEngine + AudioConverter:
  var state = try TdtDecoderState()                    // NEUF par énoncé (decoderLayers:2 = v3)
  let result = try await asr.transcribe(samples, decoderState: &state, language: nil)
  insertAtCursor(result.text)                          // result.confidence, result.rtfx dispo
  // Note: transcribe(_ buffer: AVAudioPCMBuffer,...) resample en interne -> on peut passer directement le buffer micro 44.1/48kHz.

Exemple STREAMING (option aperçu live) — SlidingWindowAsrManager.swift:
  public actor SlidingWindowAsrManager {
    public init(config: SlidingWindowAsrConfig = .default)
    public func loadModels(_ models: AsrModels) async throws
    public func startStreaming(source: AudioSource = .microphone) async throws
    public func streamAudio(_ buffer: AVAudioPCMBuffer)
    public var transcriptionUpdates: AsyncStream<SlidingWindowTranscriptionUpdate> { get }
    public private(set) var volatileTranscript: String
    public private(set) var confirmedTranscript: String
    public func finish() async throws -> String
    public func cancel() async
  }
  // Il existe aussi protocol StreamingAsrManager: Actor (appendAudio/processBufferedAudio/finish/getPartialTranscript/setPartialTranscriptCallback)
  // et des modèles EOU realtime (parakeet-realtime-eou-120m, chunks 160/320/1280 ms) pour auto-détection de fin d'énoncé.

TAILLE DOWNLOAD (v3, fichiers réellement requis via requiredModelsV3, mesuré via l'API HF):
  Encoder.mlmodelc int8 ~445 Mo + Decoder ~23,6 Mo + JointDecisionv3 ~12,6 Mo + Preprocessor ~0,5 Mo + parakeet_v3_vocab.json ~0,15 Mo = ~482 Mo.
  Avec encoderPrecision:.int4 -> EncoderInt4.mlmodelc ~298 Mo, total ~335 Mo.
  Le dépôt HF complet fait ~3 Go (toutes variantes mlmodelc+mlpackage, MelEncoder, streaming) mais downloadAndLoad ne récupère QUE les fichiers de la version/précision choisie.
  Compute units par défaut: préprocesseur .cpuOnly, encodeur/décodeur/joint .cpuAndNeuralEngine (option encoderComputeUnits:.cpuAndGPU = ~+8% RTFx mais moins efficient en énergie).

Config avancée (ASRConfig): pour audio long multilingue v3, passer melChunkContext:false (issue #594); sans effet sur des énoncés courts <15 s.

API APPLE SpeechAnalyzer/SpeechTranscriber (macOS 26 / iOS 26, framework Speech):
  @available(macOS 26, *)
  let transcriber = SpeechTranscriber(locale: Locale(identifier: "fr_FR"), preset: .offlineTranscription)
  let analyzer = SpeechAnalyzer(modules: [transcriber])
  if let dl = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
      try await dl.downloadAndInstall()            // modèles gérés par l'OS, rien à embarquer
  }
  let installed = await Set(SpeechTranscriber.installedLocales)   // fr_FR, fr_CA, fr_BE, fr_CH supportés
  // entrée: AsyncStream<AnalyzerInput> via analyzer.start(inputSequence:)
  for try await r in transcriber.results { if r.isFinal { text += String(r.text.characters) } }  // r.text = AttributedString

ARCHITECTURE PROTOCOLE proposée:
  public struct TranscriptionResult: Sendable { public let text: String; public let confidence: Float; public let words: [WordTiming]? }
  public protocol TranscriptionEngine: Actor {
    var id: String { get }
    var displayName: String { get }
    var isAvailable: Bool { get }                 // Apple Silicon / version OS
    var supportedLocales: [Locale] { get }
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
    func transcribe(samples: [Float], locale: Locale?) async throws -> TranscriptionResult
    func unload() async
  }
  public protocol StreamingTranscriptionEngine: TranscriptionEngine {
    func startStream(locale: Locale?) async throws
    func appendAudio(_ buffer: AVAudioPCMBuffer) async
    var partials: AsyncStream<String> { get }
    func finishStream() async throws -> TranscriptionResult
  }
  // Conformances: FluidAudioEngine (wrappe AsrManager+AsrModels, mappe Locale->Language, crée un TdtDecoderState par appel),
  //               AppleSpeechEngine @available(macOS 26,*) (wrappe SpeechAnalyzer+SpeechTranscriber; isAvailable=false sous macOS 26).
  // Un EngineRegistry choisit le moteur selon disponibilité + préférence utilisateur.

## Pitfalls
- PIÈGE MAJEUR: le README et Documentation/ASR/GettingStarted.md montrent asrManager.configure(models:) et transcribe(samples, source:.system) / transcribe(url, source:) — ces signatures N'EXISTENT PAS dans le code compilé (ni sur main ni sur v0.15.5). L'API réelle est loadModels(_:) et transcribe(_ samples:, decoderState: inout TdtDecoderState, language:). Ne pas copier les snippets de la doc; se baser sur le code source.
- Il faut gérer explicitement un TdtDecoderState (inout). En batch, en créer un neuf par énoncé (try TdtDecoderState(), decoderLayers:2 par défaut = OK pour v3). Ne pas partager/réutiliser un même state entre transcriptions concurrentes.
- SDK pré-1.0 (0.x): l'API casse entre versions mineures (le paramètre source: a par ex. disparu). Épingler une version exacte, relire les signatures à chaque montée de version, ne pas utiliser from: sans vérifier.
- Apple Silicon obligatoire pour Parakeet/FluidAudio (isModelValid lève ASRError.unsupportedPlatform sur Intel). OK vu la cible, mais exposer isAvailable pour dégrader proprement.
- Format audio strict: 16 kHz mono Float32. Passer du 44.1/48 kHz, du stéréo ou un format compressé sans conversion produit un transcript VIDE sans erreur. Utiliser l'AudioConverter de FluidAudio ou passer un AVAudioPCMBuffer (converti en interne).
- Ne charger que la version nécessaire: le dépôt HF parakeet-tdt-0.6b-v3-coreml pèse ~3 Go (toutes variantes) mais downloadAndLoad(version:encoderPrecision:) ne télécharge que ~335-482 Mo. Ne pas cloner/tirer tout le repo.
- Choix v2 vs v3: v2 a un meilleur WER anglais mais est anglais-seulement; pour le français il FAUT v3 (multilingue). Ne pas livrer v2 si le français est requis.
- SpeechAnalyzer/SpeechTranscriber = macOS 26+ uniquement. Impossible d'en faire le moteur unique d'une cible macOS 14+. Toujours @available-gater et garder FluidAudio comme plancher. Compiler ce code nécessite le SDK macOS 26 (OK ici).
- Licence des poids: Parakeet est CC-BY-4.0 (NVIDIA) — attribution obligatoire dans l'app/à propos, distinct de l'Apache-2.0 du SDK FluidAudio. À gérer pour une distribution 'produit commercial'.
- Le download initial (plusieurs centaines de Mo) est le seul gros point de friction UX; gérer offline/échec réseau, reprise, et afficher la progression (fractionCompleted + phase compiling, qui peut prendre plusieurs secondes à la 1re compilation ANE).
- parakeet-mlx (senstella) et le port FluidInference/swift-parakeet-mlx utilisent MLX/GPU (~2 Go RAM) et non l'ANE; ne pas les confondre avec FluidAudio (CoreML/ANE, ~66 Mo). Pour un daemon d'arrière-plan, choisir FluidAudio.

## Sources
- https://github.com/FluidInference/FluidAudio (README, SDK Apache-2.0)
- https://raw.githubusercontent.com/FluidInference/FluidAudio/v0.15.5/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/AsrManager.swift (signatures transcribe réelles)
- https://raw.githubusercontent.com/FluidInference/FluidAudio/v0.15.5/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/AsrModels.swift (downloadAndLoad, AsrModelVersion, progressHandler)
- https://raw.githubusercontent.com/FluidInference/FluidAudio/v0.15.5/Sources/FluidAudio/ASR/Parakeet/AsrTypes.swift (ASRConfig, ASRResult, ASRError)
- https://raw.githubusercontent.com/FluidInference/FluidAudio/v0.15.5/Sources/FluidAudio/ModelNames.swift (ParakeetEncoderPrecision int8/int4, fichiers requis v3)
- https://raw.githubusercontent.com/FluidInference/FluidAudio/v0.15.5/Sources/FluidAudio/Shared/Download/DownloadTypes.swift (ProgressHandler, DownloadProgress.fractionCompleted, DownloadPhase)
- https://raw.githubusercontent.com/FluidInference/FluidAudio/v0.15.5/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/SlidingWindowAsrManager.swift (streaming: startStreaming, streamAudio, transcriptionUpdates, finish)
- https://raw.githubusercontent.com/FluidInference/FluidAudio/v0.15.5/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/Decoder/TdtDecoderState.swift (init decoderLayers)
- https://raw.githubusercontent.com/FluidInference/FluidAudio/v0.15.5/Package.swift (swift-tools 6.0, macOS .v14, iOS .v17)
- https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 (25 langues, WER FR 5,15% / EN 4,85% Fleurs, FastConformer-TDT 600M, CC-BY-4.0)
- https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml (modèle CoreML, repo id de download, tailles de fichiers via API HF)
- https://developer.apple.com/documentation/speech/speechtranscriber + /speechanalyzer (API macOS 26)
- https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide (code SpeechTranscriber/SpeechAnalyzer/AssetInventory, locales fr)
- https://www.macstories.net/stories/hands-on-how-apples-new-speech-apis-outpace-whisper-for-lightning-fast-transcription/ (SpeechAnalyzer ~2,2x plus rapide que MacWhisper Large v3 Turbo)
- https://github.com/FluidInference/swift-scribe (app de référence SpeechAnalyzer + FluidAudio, macOS 26)
- https://github.com/senstella/parakeet-mlx + https://github.com/FluidInference/swift-parakeet-mlx (MLX/GPU, ~2 Go RAM, disqualifiant pour app Swift native)
- https://github.com/argmaxinc/WhisperKit + https://huggingface.co/argmaxinc/whisperkit-coreml (alternative Swift/CoreML, MIT, 99 langues)
- https://macparakeet.com/blog/whisper-to-parakeet-neural-engine/ (comparatif ANE Whisper vs Parakeet, empreinte mémoire ~66 Mo)
