# MoDict — build & packaging (Command Line Tools only, no Xcode, Apple Silicon).
#
# Common targets:
#   make            build + bundle + sign the native arm64 app (default)
#   make build      compile the release binary (arm64, fast)          -> .build/release/MoDict
#   make universal  compile a universal binary and bundle + sign it   -> Intel + Apple Silicon
#   make icon       render the app icon and produce AppIcon.icns
#   make bundle     assemble build/MoDict.app from the compiled binary
#   make sign       code-sign the bundle (stable identity, else ad-hoc + warning)
#   make run        build, sign, and launch the app directly (dev)
#   make clean      remove .build and build
#
# Recipes are indented with real TABs (make requires it).

APP_NAME  := MoDict
BUNDLE_ID := com.modict.app
PRODUCT   := MoDict
VERSION   := 0.1.0
BUILD     ?= 1

# Stable signing identity. Create it once with ./scripts/dev-cert.sh so macOS
# does not re-prompt for Microphone / Accessibility / Input Monitoring on every
# rebuild. Override on the command line, e.g. `make sign IDENTITY="Developer ID
# Application: …"`, or `IDENTITY=-` to force an ad-hoc signature (CI).
IDENTITY  ?= MoDict Dev

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

ENTITLEMENTS := Support/MoDict.entitlements
PLIST_IN     := Support/Info.plist.in

.PHONY: all build universal icon bundle sign run clean
.DEFAULT_GOAL := all

all: sign

build:
	swift build -c release $(SWIFT_FLAGS)

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
		echo "Signing ad-hoc."; \
		codesign --force --deep --options runtime --entitlements "$(ENTITLEMENTS)" --sign - "$(APP)"; \
	elif security find-identity -v -p codesigning 2>/dev/null | grep -qF "$(IDENTITY)"; then \
		echo "Signing with identity: $(IDENTITY)"; \
		codesign --force --deep --options runtime --entitlements "$(ENTITLEMENTS)" --sign "$(IDENTITY)" "$(APP)"; \
	else \
		echo "warning: signing identity \"$(IDENTITY)\" not found; falling back to ad-hoc."; \
		echo "warning: an ad-hoc signature changes on every rebuild, so macOS re-requests"; \
		echo "warning: Microphone, Accessibility and Input Monitoring each time you build."; \
		echo "warning: run ./scripts/dev-cert.sh once to create a stable \"MoDict Dev\" identity."; \
		codesign --force --deep --options runtime --entitlements "$(ENTITLEMENTS)" --sign - "$(APP)"; \
	fi
	codesign --verify --verbose "$(APP)"

# Launch the binary directly rather than via `open`. Going through LaunchServices
# races TCC on freshly signed builds and can strip the permission grant; a direct
# exec keeps the stable signing identity's authorizations intact.
run: sign
	@echo "Launching $(APP_NAME) (Ctrl-C to quit)"
	"$(CONTENTS)/MacOS/$(APP_NAME)"

clean:
	rm -rf .build "$(BUILD_DIR)"
