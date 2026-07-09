# Research: packaging

## Summary
On peut construire une app macOS SwiftUI complète (menu-bar, LSUIElement) 100% en SPM + Command Line Tools sans Xcode : SPM compile un `.executableTarget` avec un `@main App` SwiftUI, puis un Makefile assemble le bundle `.app` à la main (Contents/MacOS/<exe> + Contents/Info.plist + Contents/Resources/AppIcon.icns + Contents/PkgInfo). C'est un pattern éprouvé (joseph-long, eudoxia0/swiftui-without-xcode, objc.io) et il existe un outil dédié mûr, Swift Bundler (stackotter/moreSwift), qui automatise exactement ça (génération d'Info.plist, iconutil, codesign) via un `Bundler.toml`. Point CRITIQUE pour TCC : la signature ad-hoc (`codesign -s -`) donne un « designated requirement » basé sur le CDHash qui change à chaque rebuild → macOS redemande micro/Accessibilité à chaque build. La solution documentée par Quinn (Apple DTS) est de signer avec une identité STABLE ; pour un projet open-source local, cela veut dire créer un certificat auto-signé « Code Signing » dans Keychain Access une seule fois et signer avec (`codesign --sign "MoDict Self-Signed"`), ce qui fige le DR et fait persister les permissions à travers les rebuilds. L'icône se génère sans Xcode avec `sips` (redimensionne un PNG 1024) + `iconutil -c icns AppIcon.iconset`. `SMAppService.mainApp.register()` (macOS 13+) fonctionne pour un login-item d'app auto-signée/ad-hoc à condition que le bundle porte une signature valide et soit idéalement dans /Applications ; l'exigence stricte de même Team-ID ne concerne que les helpers/daemons embarqués, pas mainApp. Les runners GitHub Actions `macos-26` (arm64) et `macos-15` existent bien en 2026 ; `swift build -c release --arch arm64 --arch x86_64` produit un binaire universel dans `.build/apple/Products/Release/<product>`. Référence exemplaire directement comparable : VoiceInk (beingpax/VoiceInk, GPLv3), alternative open-source à Superwhisper/Wispr Flow. Attention macOS 26 : `NSEvent.addGlobalMonitorForEvents` crashe (Bus error) → utiliser `CGEventTap` pour la touche Commande droite.</summary>
<recommendations>
<recommendation>
<topic>Cible SPM exécutable SwiftUI + @main + LSUIElement</topic>
<recommendation>Utiliser un `.executableTarget` (pas `.executable` produit uniquement) avec `platforms: [.macOS(.v14)]` et `swift-tools-version: 6.0+`. Le point d'entrée est un `@main struct MoDictApp: App` avec une scène `MenuBarExtra(...)` et `.menuBarExtraStyle(.menu)`, plus une scène `Settings { }` pour la fenêtre de préférences. Retirer tout `WindowGroup` pour ne pas ouvrir de fenêtre principale. Mettre `LSUIElement = true` dans l'Info.plist du bundle (PAS dans Package.swift — SPM n'a pas de champ Info.plist pour app) pour supprimer l'icône du Dock et le menu applicatif. Ajouter `@NSApplicationDelegateAdaptor(AppDelegate.self)` pour gérer le CGEventTap (push-to-talk), le monitoring micro et l'insertion de texte.</recommendation>
<rationale>MenuBarExtra est la scène SwiftUI native (macOS 13+) pour app menu-bar; LSUIElement dans le bundle Info.plist est ce que lit LaunchServices au lancement (SPM ne peut pas injecter d'Info.plist d'app, il faut le bundle manuel). L'AppDelegateAdaptor est nécessaire car le monitoring clavier global et le CGEventTap sortent du cadre pur SwiftUI.</rationale>
</recommendation>
<recommendation>
<topic>Construction manuelle du bundle .app (Makefile)</topic>
<recommendation>Structure exacte : `MoDict.app/Contents/{Info.plist, PkgInfo, MacOS/MoDict, Resources/AppIcon.icns}`. Le Makefile : (1) `swift build -c release --arch arm64 --arch x86_64` ; (2) copie `.build/apple/Products/Release/MoDict` → `Contents/MacOS/MoDict` (nom = CFBundleExecutable) ; (3) génère `Contents/Info.plist` depuis un template `Info.plist.in` via `sed` (substitution version/bundle-id) ; (4) écrit `Contents/PkgInfo` avec `APPL????` ; (5) copie l'icône. Alternative « batteries incluses » : adopter Swift Bundler (`swift bundler create MoDict --template SwiftUI` puis `swift bundler bundle -c release --universal`) qui fait tout ça + Info.plist + iconutil + codesign à partir d'un `Bundler.toml`.</recommendation>
<rationale>Le pattern Makefile est validé par plusieurs sources réelles (joseph-long, eudoxia0). Le binaire universel de SPM sort dans `.build/apple/Products/Release/` (vérifié via lipo). PkgInfo est facultatif mais attendu par certaines versions de LaunchServices. Swift Bundler évite de réinventer la roue et gère déjà iconutil + codesign + Info.plist merge.</rationale>
</recommendation>
<recommendation>
<topic>Codesign stable pour ne PAS re-demander les permissions TCC</topic>
<recommendation>NE PAS se contenter de l'ad-hoc (`codesign --force --deep --sign - MoDict.app`) : son designated requirement dépend du CDHash qui change à chaque build → TCC (Micro, Accessibilité, Input Monitoring) est redemandé à chaque rebuild. Créer UNE FOIS un certificat auto-signé dans Keychain Access (Certificate Assistant → Create a Certificate → Identity Type: Self-Signed Root, Certificate Type: Code Signing, cocher « Let me override defaults », le marquer Always Trust pour Code Signing), puis signer chaque build avec cette identité stable : `codesign --force --deep --sign "MoDict Self-Signed" MoDict.app`. Vérifier la dispo de l'identité avec `security find-identity -v -p codesigning`. Pour la DISTRIBUTION binaire aux utilisateurs finaux, viser Developer ID Application + hardened runtime (`--options runtime`) + notarisation (`notarytool`) pour éviter Gatekeeper/quarantine.</recommendation>
<rationale>Confirmé par Quinn « The Eskimo » (Apple DTS, forum 730043) : TCC identifie l'app par son designated requirement, stable seulement avec une identité de signature stable. Un certificat auto-signé Code Signing produit un DR fixe (basé sur le certificat, pas le CDHash) reconnu par les sous-systèmes locaux comme TCC — c'est précisément l'usage prévu des certificats auto-signés d'après la doc Apple. L'app NE doit PAS être sandboxée (elle poste des CGEvents dans d'autres apps et lit le clavier global), ce qui exclut le Mac App Store et impose Developer ID + notarisation pour la distribution.</rationale>
</recommendation>
<recommendation>
<topic>Icône .icns sans Xcode</topic>
<recommendation>À partir d'un seul `Icon-1024.png`, générer le `.iconset` avec `sips -z <taille> <taille> Icon-1024.png --out AppIcon.iconset/icon_<n>x<n>.png` pour les 10 fichiers requis (16, 32, 128, 256, 512 en @1x et @2x, le @2x de 512 = le 1024 original), puis `iconutil -c icns AppIcon.iconset -o AppIcon.icns`. Copier `AppIcon.icns` dans `Contents/Resources/` et déclarer `CFBundleIconFile = AppIcon` (sans extension) dans l'Info.plist. `iconutil` ET `sips` sont fournis par les Command Line Tools, aucun Xcode requis.</recommendation>
<rationale>iconutil est l'outil Apple officiel de conversion iconset↔icns et n'exige que le nommage exact des PNG (pas de Contents.json). sips (aussi CLT) fait le redimensionnement, éliminant le besoin d'un éditeur d'image ou d'Asset Catalog Xcode.</rationale>
</recommendation>
<recommendation>
<topic>Login item / démarrage auto (SMAppService)</topic>
<recommendation>Utiliser `SMAppService.mainApp.register()` / `.unregister()` (macOS 13+) piloté par un Toggle « Launch at login », et lire `SMAppService.mainApp.status == .enabled` pour synchroniser l'UI (au `.onAppear` et sur retour de focus via `@Environment(\.appearsActive)`). Cela FONCTIONNE avec une app auto-signée/ad-hoc du moment que le bundle porte une signature valide ; l'exigence stricte « même Team ID » ne s'applique qu'aux helpers/agents/daemons embarqués, pas à `mainApp`. Une app NON signée fait échouer `register()`. Recommander de placer l'app dans `/Applications` (LaunchServices/BTM suit l'emplacement) et retirer la quarantaine des builds téléchargés : `xattr -dr com.apple.quarantine MoDict.app`.</recommendation>
<rationale>SMAppService est l'API moderne (remplace SMLoginItemSetEnabled). Pour mainApp, aucun plist launchd embarqué n'est requis — l'app s'enregistre elle-même. Les échecs « Operation not permitted » remontés dans les forums concernent les daemons/helpers embarqués en ad-hoc, un cas différent de mainApp. À tester sur cible réelle car le comportement exact dépend de la présence d'une signature valide et de l'emplacement.</rationale>
</recommendation>
<recommendation>
<topic>Structure de repo open-source + CI GitHub Actions</topic>
<recommendation>Layout : `Package.swift`, `Sources/MoDict/…`, `Resources/` (Icon-1024.png, modèle Parakeet ou script de download), `Makefile`, `Info.plist.in`, `MoDict.entitlements`, `README.md`, `LICENSE` (MIT recommandé pour adoption max, ou GPLv3 comme VoiceInk pour copyleft), `CONTRIBUTING.md`, `.github/workflows/build.yml`. CI : runner `macos-26` (arm64, existe en 2026, embarque Xcode/Swift 6.x + SDK macOS 26), étapes `swift --version`, `swift build -c release --arch arm64 --arch x86_64`, `make bundle`, signature ad-hoc pour l'artefact CI, `actions/upload-artifact@v4`. Référence exemplaire directement comparable à étudier : VoiceInk (github.com/beingpax/VoiceInk, ~4,3k stars, Swift, whisper.cpp local, insertion système-wide) et vocorize/app.</recommendation>
<rationale>macos-26 est un label de runner GitHub-hosted confirmé (doc runners GitHub). Un binaire universel garantit le fonctionnement Intel+Apple Silicon. VoiceInk est le clone open-source le plus proche du besoin (dictée locale, alternative Superwhisper/Wispr Flow) et sert de modèle d'organisation et de fonctionnalités (Power Mode par app, dictionnaire personnel).</rationale>
</recommendation>
</recommendations>
<code_notes>
=== Package.swift ===
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "MoDict",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MoDict",
            path: "Sources/MoDict"
            // resources: [.copy("parakeet.mlmodelc")] si modèle embarqué
        )
    ]
)

=== Sources/MoDict/MoDictApp.swift (@main SwiftUI menu-bar) ===
import SwiftUI
@main
struct MoDictApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        MenuBarExtra("MoDict", systemImage: "mic.fill") {
            SettingsLink { Text("Réglages…") }
            Divider()
            Button("Quitter") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)   // .window pour un panneau custom
        Settings { SettingsView() }
    }
}
// AppDelegate: y placer le CGEventTap (touche Cmd droite, flagsChanged),
// AVAudioApplication.requestRecordPermission, AXIsProcessTrustedWithOptions,
// et l'insertion de texte (pasteboard + CGEvent Cmd+V, ou CGEventKeyboardSetUnicodeString).

=== Info.plist.in (template ; sed remplace @VARS@) ===
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>                 <string>@APP_NAME@</string>
  <key>CFBundleDisplayName</key>          <string>@APP_NAME@</string>
  <key>CFBundleExecutable</key>           <string>@APP_NAME@</string>
  <key>CFBundleIdentifier</key>           <string>@BUNDLE_ID@</string>
  <key>CFBundlePackageType</key>          <string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key>   <string>@VERSION@</string>
  <key>CFBundleVersion</key>              <string>@BUILD@</string>
  <key>CFBundleIconFile</key>             <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>       <string>14.0</string>
  <key>LSUIElement</key>                  <true/>
  <key>NSPrincipalClass</key>             <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>      <true/>
  <key>NSMicrophoneUsageDescription</key>
    <string>MoDict transcrit votre voix en texte, en local, sur votre Mac.</string>
</dict>
</plist>

=== MoDict.entitlements (utile seulement avec hardened runtime/notarisation ; PAS de sandbox) ===
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key> <true/>
  <!-- Accessibilité & Input Monitoring ne sont PAS des entitlements :
       ce sont des autorisations TCC accordées à l'exécution. Pas d'App Sandbox
       (bloquerait CGEvent vers d'autres apps + monitoring clavier global). -->
</dict>
</plist>

=== Makefile (bundling exact, sans Xcode) ===
APP_NAME  := MoDict
BUNDLE_ID := com.modict.app
PRODUCT   := MoDict
VERSION   := 0.1.0
BUILD     := 1
IDENTITY  ?= MoDict Self-Signed        # "-" = ad-hoc (déconseillé pour TCC)
UNIVERSAL := .build/apple/Products/Release/$(PRODUCT)
APP       := build/$(APP_NAME).app
CONTENTS  := $(APP)/Contents

.PHONY: all build bundle icon sign sign-adhoc run clean
all: sign

build:
	swift build -c release --arch arm64 --arch x86_64

icon: AppIcon.icns
AppIcon.icns: Icon-1024.png
	rm -rf AppIcon.iconset && mkdir AppIcon.iconset
	sips -z 16 16    Icon-1024.png --out AppIcon.iconset/icon_16x16.png
	sips -z 32 32    Icon-1024.png --out AppIcon.iconset/icon_16x16@2x.png
	sips -z 32 32    Icon-1024.png --out AppIcon.iconset/icon_32x32.png
	sips -z 64 64    Icon-1024.png --out AppIcon.iconset/icon_32x32@2x.png
	sips -z 128 128  Icon-1024.png --out AppIcon.iconset/icon_128x128.png
	sips -z 256 256  Icon-1024.png --out AppIcon.iconset/icon_128x128@2x.png
	sips -z 256 256  Icon-1024.png --out AppIcon.iconset/icon_256x256.png
	sips -z 512 512  Icon-1024.png --out AppIcon.iconset/icon_256x256@2x.png
	sips -z 512 512  Icon-1024.png --out AppIcon.iconset/icon_512x512.png
	cp               Icon-1024.png    AppIcon.iconset/icon_512x512@2x.png
	iconutil -c icns AppIcon.iconset -o AppIcon.icns

bundle: build icon
	rm -rf "$(APP)"
	mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	cp "$(UNIVERSAL)" "$(CONTENTS)/MacOS/$(APP_NAME)"
	sed -e "s/@APP_NAME@/$(APP_NAME)/g" -e "s/@BUNDLE_ID@/$(BUNDLE_ID)/g" \
	    -e "s/@VERSION@/$(VERSION)/g"   -e "s/@BUILD@/$(BUILD)/g" \
	    Info.plist.in > "$(CONTENTS)/Info.plist"
	printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	cp AppIcon.icns "$(CONTENTS)/Resources/AppIcon.icns"

# Signature STABLE (recommandée) -> TCC persiste entre rebuilds
sign: bundle
	codesign --force --deep --sign "$(IDENTITY)" "$(APP)"
	codesign --verify --verbose "$(APP)"

# Ad-hoc (DR instable -> re-prompt TCC à chaque build) ; ok pour CI artefacts
sign-adhoc: bundle
	codesign --force --deep --sign - "$(APP)"

run: sign
	open "$(APP)"
clean:
	rm -rf .build build AppIcon.iconset AppIcon.icns
# NB: les recettes doivent être indentées par des TABULATIONS, pas des espaces.

=== Créer le certificat auto-signé (UNE fois) ===
# GUI: Keychain Access > Certificate Assistant > Create a Certificate
#   Name: "MoDict Self-Signed" | Identity Type: Self-Signed Root
#   Certificate Type: Code Signing | cocher "Let me override defaults"
#   puis le marquer "Always Trust" pour Code Signing.
security find-identity -v -p codesigning   # doit lister "MoDict Self-Signed"

=== Commandes codesign réelles (issues de swift-bundler/DarwinCodeSigner.swift) ===
# ad-hoc:   /usr/bin/codesign --force -s - <path>
# identité: /usr/bin/codesign --force --deep --sign <identityId> \
#             [--entitlements <file> --generate-entitlement-der] <path>
# lister:   security find-identity -p codesigning -v

=== Launch-at-login (ServiceManagement) ===
import ServiceManagement
func setLaunchAtLogin(_ on: Bool) {
    do { on ? try SMAppService.mainApp.register()
            : try SMAppService.mainApp.unregister() }
    catch { NSLog("SMAppService: \(error)") }
}
var launchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }
// Requiert macOS 13+, bundle SIGNÉ (ad-hoc/self-signed ok pour mainApp),
// idéalement dans /Applications.

=== Bundler.toml (alternative Swift Bundler ; format_version = 2) ===
[apps.MoDict]
identifier = "com.modict.app"
product    = "MoDict"
version    = "0.1.0"
category   = "public.app-category.productivity"
icon       = "Icon-1024.png"     # PNG 1024 accepté, converti en icns automatiquement
[apps.MoDict.plist]
LSUIElement = true
NSMicrophoneUsageDescription = "MoDict transcrit votre voix en local."
# CLI: swift bundler bundle -c release --universal   (sortie: .build/bundler)

=== .github/workflows/build.yml ===
name: build
on: [push, pull_request]
jobs:
  build:
    runs-on: macos-26          # aussi dispo: macos-15 (arm64), macos-26-intel
    steps:
      - uses: actions/checkout@v4
      - run: swift --version
      - name: Build universel
        run: swift build -c release --arch arm64 --arch x86_64
      - name: Bundle .app
        run: make sign-adhoc   # CI: pas de cert stable -> ad-hoc
      - name: Vérifier le binaire
        run: lipo -info build/MoDict.app/Contents/MacOS/MoDict
      - uses: actions/upload-artifact@v4
        with: { name: MoDict.app, path: build/MoDict.app }

=== Vérif universalité ===
lipo -info build/MoDict.app/Contents/MacOS/MoDict   # -> x86_64 arm64
</code_notes>
<pitfalls>
<pitfall>Signature ad-hoc (`codesign -s -`) = designated requirement basé sur le CDHash, qui change à CHAQUE rebuild → macOS redemande Micro/Accessibilité/Input Monitoring à chaque build. Corriger avec un certificat auto-signé « Code Signing » stable (Keychain Access), pas de l'ad-hoc, pour le dev quotidien.</pitfall>
<pitfall>macOS 26 (cible du projet) : `NSEvent.addGlobalMonitorForEvents` crashe avec un Bus error dans GlobalObserverHandler. Pour la détection push-to-talk de la touche Commande droite (flagsChanged), utiliser un `CGEventTap`. Attention : le callback CGEventTap tourne sur le thread du CFRunLoop, pas MainActor → repasser par `DispatchQueue.main.async` avant de toucher l'état SwiftUI/@MainActor.</pitfall>
<pitfall>SPM ne peut PAS injecter d'Info.plist pour une app (il refuse un fichier top-level nommé Info.plist dans un target ; l'option `-sectcreate __TEXT __info_plist` vaut pour un CLI, pas un bundle .app). L'Info.plist DOIT être placé manuellement dans `Contents/Info.plist` par le Makefile — c'est celui-là que lit LaunchServices.</pitfall>
<pitfall>Ne PAS activer l'App Sandbox : une app de dictée qui poste des CGEvents/insère du texte dans d'autres apps et lit le clavier globalement est incompatible avec le sandbox → cela exclut aussi le Mac App Store. Distribuer via Developer ID + notarisation (ou builds source + self-sign par l'utilisateur).</pitfall>
<pitfall>`CFBundleExecutable` dans l'Info.plist doit correspondre EXACTEMENT au nom du fichier binaire copié dans `Contents/MacOS/`. Un mismatch fait échouer le lancement silencieusement.</pitfall>
<pitfall>Insertion de texte au curseur et monitoring clavier requièrent l'autorisation Accessibilité (et souvent Input Monitoring) — ce sont des autorisations TCC accordées à l'exécution (via `AXIsProcessTrustedWithOptions`), PAS des entitlements. L'utilisateur doit ajouter l'app manuellement dans Réglages Système > Confidentialité. Sans identité de signature stable, cette autorisation aussi saute à chaque rebuild.</pitfall>
<pitfall>Builds téléchargés depuis GitHub Releases : l'attribut de quarantaine (`com.apple.quarantine`) bloque le lancement d'une app non-notarisée. Documenter `xattr -dr com.apple.quarantine MoDict.app`, ou notariser proprement.</pitfall>
<pitfall>`SMAppService.mainApp.register()` échoue pour un bundle NON signé, et le login-item peut devenir invalide si l'app change d'emplacement (LaunchServices/BTM suit le chemin). Placer l'app dans /Applications et lui donner une signature stable. Les erreurs « Operation not permitted » vues dans les forums concernent surtout les helpers/daemons embarqués (exigence même-Team-ID), cas distinct de mainApp — à tester sur machine réelle.</pitfall>
<pitfall>`--deep` sur codesign est déconseillé par Apple pour des bundles complexes (signer de l'intérieur vers l'extérieur) ; pour un bundle mono-binaire c'est acceptable, mais si vous embarquez des frameworks/helpers, signez-les individuellement d'abord puis l'app.</pitfall>
<pitfall>Dans le Makefile, les recettes doivent être indentées par des TABULATIONS réelles (pas des espaces), sinon `make` échoue avec « missing separator ».</pitfall>
</pitfalls>
<sources>
<source>https://joseph-long.com/writing/app-bundles-with-a-makefile/</source>
<source>https://github.com/eudoxia0/swiftui-without-xcode (Makefile: swiftc -parse-as-library + Contents/MacOS + Info.plist)</source>
<source>https://theswiftdev.com/how-to-build-macos-apps-using-only-the-swift-package-manager/</source>
<source>https://www.objc.io/blog/2020/05/19/swiftui-without-an-xcodeproj/</source>
<source>https://github.com/stackotter/swift-bundler (alias moreSwift/swift-bundler) — Bundler.toml, darwin-app-bundler, DarwinCodeSigner.swift</source>
<source>https://swiftbundler.dev/documentation/swift-bundler/configuration</source>
<source>https://developer.apple.com/forums/thread/730043 (Quinn/Apple DTS : identité de signature stable pour TCC)</source>
<source>https://support.apple.com/guide/keychain-access/create-self-signed-certificates-kyca8916/mac</source>
<source>https://eclecticlight.co/2019/01/16/code-signing-for-the-concerned-2-creating-a-personal-certificate/</source>
<source>https://gist.github.com/jamieweavis/b4c394607641e1280d447deed5fc85fc (iconutil / iconset)</source>
<source>https://developer.apple.com/documentation/servicemanagement/smappservice</source>
<source>https://nilcoalescing.com/blog/LaunchAtLoginSetting/ (SMAppService.mainApp register/unregister/status)</source>
<source>https://sarunw.com/posts/swiftui-menu-bar-app/ (MenuBarExtra + LSUIElement)</source>
<source>https://docs.github.com/en/actions/reference/runners/github-hosted-runners (macos-26 / macos-15 disponibles)</source>
<source>https://github.com/beingpax/VoiceInk (repo exemplaire comparable, GPLv3) et https://github.com/vocorize/app</source>
<source>https://developer.apple.com/documentation/BundleResources/Information-Property-List/NSMicrophoneUsageDescription</source>
<source>https://developer.apple.com/forums/thread/726826 et /799910 (exigences de signature SMAppService pour helpers/daemons)</source>
<source>https://www.liamnichols.eu/2020/08/01/building-swift-packages-as-a-universal-binary.html (.build/apple/Products/Release/, lipo)</source>
</sources>
</invoke>


## Recommendations

## Code notes


## Pitfalls

## Sources
