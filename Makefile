# MoDict — build & packaging (Command Line Tools only, no Xcode, Apple Silicon).
#
# Common targets:
#   make            build + bundle + sign the native arm64 app (default)
#   make build      compile the release binary (arm64, fast)          -> .build/release/MoDict
#   make universal  compile a universal binary and bundle + sign it   -> Intel + Apple Silicon
#   make icon       render the app icon and produce AppIcon.icns
#   make bundle     assemble build/MoDict.app from the compiled binary
#   make sign       code-sign the bundle (stable identity, else ad-hoc + warning)
#   make sign-adhoc force ad-hoc dev/CI signing (never a release)
#   make diagnose-signature
#                   inspect signature, entitlements and Gatekeeper posture
#   make validate-release
#                   fail unless the current app is Developer ID signed
#   make developer-id
#                   build a universal Developer ID signed app (not notarized yet)
#   make notarize   submit the Developer ID build to notarytool and staple it
#   make dmg        package the signed app into a drag-to-install disk image
#   make run        build, sign, and launch the app directly (dev)
#   make clean      remove .build and build
#
# Recipes are indented with real TABs (make requires it).

APP_NAME  := MoDict
BUNDLE_ID := com.modict.app
PRODUCT   := MoDict
VERSION   := 0.1.2
BUILD     ?= 1

# Stable signing identity. Create it once with ./scripts/dev-cert.sh so macOS
# does not re-prompt for Microphone / Accessibility / Input Monitoring on every
# rebuild. Override on the command line, e.g. `make sign IDENTITY="Developer ID
# Application: …"`, or `IDENTITY=-` to force an ad-hoc signature (CI/dev only).
IDENTITY  ?= MoDict Dev

# Release/notarization knobs. Prefer a notarytool keychain profile:
#   xcrun notarytool store-credentials modict-notary --apple-id ... --team-id ...
# Then run:
#   make developer-id IDENTITY="Developer ID Application: Example (TEAMID)"
#   make notarize NOTARY_PROFILE=modict-notary
NOTARY_PROFILE ?=
NOTARY_TIMEOUT ?= 30m

# Extra flags passed to `swift build`. `make universal` re-invokes make with the
# cross-arch flags so bundle/sign are reused without a second arm64 build.
SWIFT_FLAGS ?=

BUILD_DIR     := build
APP           := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS      := $(APP)/Contents
ARM64_BIN     := .build/release/$(PRODUCT)
UNIVERSAL_BIN := .build/apple/Products/Release/$(PRODUCT)

# Which compiled binary the bundle copies. Defaults to the fast native build;
# `make universal` overrides it with the cross-arch product path.
BINARY ?= $(ARM64_BIN)

ICON_SRC := Support/generate-icon.swift
ICON_PNG := $(BUILD_DIR)/Icon-1024.png
ICONSET  := $(BUILD_DIR)/AppIcon.iconset
ICNS     := $(BUILD_DIR)/AppIcon.icns
RELEASE_ZIP := $(BUILD_DIR)/$(APP_NAME)-$(VERSION)-$(BUILD).zip
DMG         := $(BUILD_DIR)/$(APP_NAME)-$(VERSION).dmg
DMG_STAGING := $(BUILD_DIR)/dmg-staging

ENTITLEMENTS := Support/MoDict.entitlements
PLIST_IN     := Support/Info.plist.in
SIGNATURE_DIAGNOSTICS := scripts/signature-diagnostics.sh

# Guard rails. Ad-hoc signing must be requested explicitly (IDENTITY=-); a
# missing identity is always a hard error, because a silent ad-hoc fallback
# breaks TCC persistence (permissions re-requested on every rebuild).
# Release targets additionally set ALLOW_ADHOC=0 to forbid even explicit ad-hoc.
ALLOW_ADHOC ?= 1
REQUIRE_DEVELOPER_ID ?= 0

.PHONY: all build test universal icon bundle sign sign-adhoc diagnose-signature validate-release validate-notarized-release developer-id notarize dmg run clean
.DEFAULT_GOAL := all

all: sign

build:
	swift build -c release $(SWIFT_FLAGS)

# Command Line Tools alone cannot execute tests (no xctest host): `swift test`
# then builds the suite but silently runs nothing. Detect that and say so
# instead of pretending the suite passed. CI (full Xcode) runs them for real.
test:
	@if xcrun --find xctest >/dev/null 2>&1; then \
		swift test; \
	else \
		swift build --build-tests && \
		echo "warning: tests COMPILED but were NOT RUN — Command Line Tools" && \
		echo "warning: have no xctest host. They run for real in CI (macos-26)" && \
		echo "warning: or locally with full Xcode installed."; \
	fi

universal:
	$(MAKE) sign SWIFT_FLAGS="--arch arm64 --arch x86_64" BINARY=$(UNIVERSAL_BIN)
	lipo -info "$(CONTENTS)/MacOS/$(APP_NAME)"

icon: $(ICNS)

$(ICON_PNG): $(ICON_SRC)
	mkdir -p "$(BUILD_DIR)"
	swift "$(ICON_SRC)" "$(ICON_PNG)"

$(ICNS): $(ICON_PNG)
	rm -rf "$(ICONSET)"
	mkdir -p "$(ICONSET)"
	sips -z 16 16    "$(ICON_PNG)" --out "$(ICONSET)/icon_16x16.png"
	sips -z 32 32    "$(ICON_PNG)" --out "$(ICONSET)/icon_16x16@2x.png"
	sips -z 32 32    "$(ICON_PNG)" --out "$(ICONSET)/icon_32x32.png"
	sips -z 64 64    "$(ICON_PNG)" --out "$(ICONSET)/icon_32x32@2x.png"
	sips -z 128 128  "$(ICON_PNG)" --out "$(ICONSET)/icon_128x128.png"
	sips -z 256 256  "$(ICON_PNG)" --out "$(ICONSET)/icon_128x128@2x.png"
	sips -z 256 256  "$(ICON_PNG)" --out "$(ICONSET)/icon_256x256.png"
	sips -z 512 512  "$(ICON_PNG)" --out "$(ICONSET)/icon_256x256@2x.png"
	sips -z 512 512  "$(ICON_PNG)" --out "$(ICONSET)/icon_512x512.png"
	cp               "$(ICON_PNG)"        "$(ICONSET)/icon_512x512@2x.png"
	iconutil -c icns "$(ICONSET)" -o "$(ICNS)"

bundle: build icon
	rm -rf "$(APP)"
	mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	cp "$(BINARY)" "$(CONTENTS)/MacOS/$(APP_NAME)"
	sed -e 's/@APP_NAME@/$(APP_NAME)/g' \
	    -e 's/@BUNDLE_ID@/$(BUNDLE_ID)/g' \
	    -e 's/@VERSION@/$(VERSION)/g' \
	    -e 's/@BUILD@/$(BUILD)/g' \
	    "$(PLIST_IN)" > "$(CONTENTS)/Info.plist"
	printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	cp "$(ICNS)" "$(CONTENTS)/Resources/AppIcon.icns"
	@echo "Bundled $(APP)"

sign: bundle
	@if [ "$(IDENTITY)" = "-" ]; then \
		if [ "$(ALLOW_ADHOC)" != "1" ]; then \
			echo "error: ad-hoc signing was requested but ALLOW_ADHOC=0."; \
			echo "error: pre-prod/release builds must use Developer ID Application and notarization."; \
			exit 2; \
		fi; \
		echo "Signing ad-hoc (DEV/CI ONLY; never use as pre-prod or release)."; \
		codesign --force --deep --options runtime --generate-entitlement-der --entitlements "$(ENTITLEMENTS)" --sign - "$(APP)"; \
	elif [ "$(REQUIRE_DEVELOPER_ID)" = "1" ] && ! printf '%s\n' "$(IDENTITY)" | grep -q '^Developer ID Application:'; then \
		echo "error: release signing requires IDENTITY=\"Developer ID Application: ...\"."; \
		echo "error: current identity: $(IDENTITY)"; \
		exit 2; \
	elif security find-identity -v -p codesigning 2>/dev/null | grep -qF "$(IDENTITY)"; then \
		echo "Signing with identity: $(IDENTITY)"; \
		TIMESTAMP_FLAG=""; \
		case "$(IDENTITY)" in Developer\ ID\ Application:*) TIMESTAMP_FLAG="--timestamp";; esac; \
		codesign --force --deep --options runtime --generate-entitlement-der --entitlements "$(ENTITLEMENTS)" $$TIMESTAMP_FLAG --sign "$(IDENTITY)" "$(APP)"; \
	else \
		echo "error: signing identity \"$(IDENTITY)\" not found (keychain locked, or the cert is missing)."; \
		echo "error: an ad-hoc build would break TCC: macOS re-requests Microphone, Accessibility"; \
		echo "error: and Input Monitoring on every rebuild, and the Settings toggles stop sticking."; \
		echo "error: run ./scripts/dev-cert.sh once to create a stable \"MoDict Dev\" identity,"; \
		echo "error: or pass IDENTITY=- explicitly for a throwaway ad-hoc build (CI only)."; \
		exit 2; \
	fi
	codesign --verify --strict --deep --verbose "$(APP)"
	@echo "Signed $(APP). Run 'make diagnose-signature' to inspect the release posture."

sign-adhoc:
	$(MAKE) sign IDENTITY=- ALLOW_ADHOC=1

diagnose-signature:
	"$(SIGNATURE_DIAGNOSTICS)" "$(APP)"

validate-release:
	"$(SIGNATURE_DIAGNOSTICS)" --release "$(APP)"

validate-notarized-release: validate-release
	xcrun stapler validate "$(APP)"
	spctl --assess --type execute --verbose=4 "$(APP)"
	@echo "Notarization ticket and Gatekeeper assessment are valid."

developer-id:
	@if [ "$(IDENTITY)" = "MoDict Dev" ]; then \
		echo "error: set a real Developer ID identity, for example:"; \
		echo "error:   make developer-id IDENTITY=\"Developer ID Application: Example (TEAMID)\""; \
		exit 2; \
	fi
	@if [ "$(IDENTITY)" = "Developer ID Application:" ]; then \
		echo "error: pass the full Developer ID identity, not only the prefix."; \
		exit 2; \
	fi
	$(MAKE) sign SWIFT_FLAGS="--arch arm64 --arch x86_64" BINARY=$(UNIVERSAL_BIN) ALLOW_ADHOC=0 REQUIRE_DEVELOPER_ID=1
	$(MAKE) validate-release
	@echo "Developer ID signature is valid, but the app is not distributable until notarized."
	@echo "Next: make notarize NOTARY_PROFILE=<notarytool-keychain-profile>"

notarize: validate-release
	@if [ -z "$(NOTARY_PROFILE)" ]; then \
		echo "error: set NOTARY_PROFILE=<notarytool keychain profile>."; \
		echo "error: create one with:"; \
		echo "error:   xcrun notarytool store-credentials modict-notary --apple-id <apple-id> --team-id <team-id>"; \
		exit 2; \
	fi
	rm -f "$(RELEASE_ZIP)"
	ditto -c -k --keepParent "$(APP)" "$(RELEASE_ZIP)"
	xcrun notarytool submit "$(RELEASE_ZIP)" --keychain-profile "$(NOTARY_PROFILE)" --wait --timeout "$(NOTARY_TIMEOUT)"
	xcrun stapler staple "$(APP)"
	$(MAKE) validate-notarized-release
	@echo "Notarized release artifact: $(APP)"

# Package the already-built-and-signed app into a compressed disk image with a
# /Applications symlink, so installing is "drag the icon onto the folder".
# Does not rebuild: run after `make`, `make universal` or `make developer-id`
# so the DMG contains exactly the app you validated. Release DMGs must come
# from a Developer ID + notarized app; an ad-hoc one forces every user to
# clear quarantine by hand (documented in the README as the interim path).
dmg:
	@test -d "$(APP)" || { echo "error: $(APP) not found — run 'make' first."; exit 2; }
	rm -rf "$(DMG_STAGING)" "$(DMG)"
	mkdir -p "$(DMG_STAGING)"
	cp -R "$(APP)" "$(DMG_STAGING)/"
	ln -s /Applications "$(DMG_STAGING)/Applications"
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$(DMG_STAGING)" -ov -format UDZO "$(DMG)"
	rm -rf "$(DMG_STAGING)"
	@echo "Disk image: $(DMG)"

# Launch the binary directly rather than via `open`. Going through LaunchServices
# races TCC on freshly signed builds and can strip the permission grant; a direct
# exec keeps the stable signing identity's authorizations intact.
run: sign
	@echo "Launching $(APP_NAME) (Ctrl-C to quit)"
	"$(CONTENTS)/MacOS/$(APP_NAME)"

clean:
	rm -rf .build "$(BUILD_DIR)"
