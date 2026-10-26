# amanu — build the application.
#
# Signing is not cosmetic here. macOS attributes the microphone and Screen &
# System Audio Recording grants to the code signature, and SwiftPM only ad-hoc
# signs, which means the identity *is* the hash — every rebuild would look like
# a brand-new program and macOS would ask for permission again, leaving a trail
# of dead amanu entries in System Settings. A real identity gives the bundle a
# stable designated requirement, and the grants survive rebuilds.
#
#   make            build + sign Amanu.app
#   make run-app    and launch it through LaunchServices
#   make icon       redraw Resources/Amanu.icns from the feather
#   make identities list available signing identities
#   make verify     show the built app's signature
#   make release    build, notarize and publish a release
#   make release-dry  everything except publishing
#
# Override the signing identity if you need to:
#   make SIGN_ID="Developer ID Application: ..."

# Universal: one binary with an arm64 and an x86_64 slice, so the same release
# runs on Apple Silicon and Intel Macs. Two
# --arch flags select a multi-arch directory. Ask SwiftPM for its path:
# Xcode 27's Swift Build engine uses .build/out instead of .build/apple.
#
# ARCHS=arm64 builds for this Mac alone, and is the one build Command Line
# Tools can do: two --arch flags need xcbuild, which only ships with Xcode.
ARCHS     ?= arm64 x86_64
ARCH_FLAGS = $(ARCHS:%=--arch %)
BUILT = $(shell swift build -c release $(ARCH_FLAGS) --show-bin-path)/amanu

# The application bundle. Assembled by hand rather than by an Xcode project:
# the package already builds and tests with SwiftPM, and an .app is a
# directory with a plist in it — a second build system to maintain buys
# nothing here.
APP        = .build/Amanu.app
APP_NAME   = Amanu
VERSION   ?= $(shell cat VERSION)
MINIMUM_MACOS ?= 14.2
# A build number that only ever goes up, and says which commit it was.
BUILD     ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
ICON       = Resources/Amanu.icns
ADAPTIVE_ICON = Resources/Amanu.icon
BUILT_ICON = .build/app-icon
DIST       = dist
DMG        = $(DIST)/amanu-v$(VERSION)-macos-universal.dmg

# Sparkle arrives as a binary framework in SwiftPM's artifact cache. There is
# no Xcode "Embed Frameworks" phase here, so `make app` copies it in and signs
# it by hand. Lazily expanded on purpose: the artifact only exists after
# `swift build` has resolved it, which happens inside the recipe below.
#
# The slice named for both architectures is the universal one. Matched exactly
# rather than by prefix: a single-architecture Sparkle would link and sign
# fine here and only fail to launch on the Macs this build exists for.
SPARKLE_FW = $(shell find .build/artifacts/sparkle -type d -name Sparkle.framework \
	-path '*macos-arm64_x86_64*' 2>/dev/null | head -1)
#
# The package's own binary targets sit under a directory SwiftPM names after
# the checkout's folder, not after the package: `amanu` in the main checkout,
# something else in a worktree. Hence the wildcard, and `extract` left out.
WHISPER_FW = $(shell find .build/artifacts/*/WhisperFramework -type d \
	-name whisper.framework -path '*macos-arm64_x86_64*' \
	-not -path '.build/artifacts/extract/*' 2>/dev/null | head -1)
TRANSCRIBE_FW = $(shell find .build/artifacts/*/TranscribeCppFramework -type d \
	-name CTranscribe.framework -path '*macos-arm64_x86_64*' \
	-not -path '.build/artifacts/extract/*' 2>/dev/null | head -1)
LOCALVQE_ROOT = .build/localvqe
LOCALVQE_LIB = $(LOCALVQE_ROOT)/lib/liblocalvqe.dylib
LOCALVQE_MODEL = $(LOCALVQE_ROOT)/model/localvqe-v1.4-aec-200K-f32.gguf

ENTITLEMENTS ?= Packaging/Amanu.entitlements

# Prefer Developer ID (distributable, long-lived) over Apple Development
# (fine for a machine-local tool). Falls back to ad-hoc so a clean checkout on
# a machine with no certificates still builds.
SIGN_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null \
	| grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
	| grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')
endif
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := -
endif

.PHONY: all build localvqe verify-localvqe app icon run-app local install-local identities verify clean release release-dry

all: app

localvqe:
	@AMANU_MINIMUM_MACOS=$(MINIMUM_MACOS) scripts/build-localvqe.sh

verify-localvqe: localvqe
	@scripts/verify-localvqe.py

build: localvqe
	swift build -c release $(ARCH_FLAGS)

# Drawn from the same feather the menu bar uses, so the Dock, the window and
# the status item are one program rather than three.
icon:
	@swift scripts/make-icon.swift $(ICON)

$(ICON):
	@swift scripts/make-icon.swift $(ICON)

app: build $(ICON)
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources/Models $(APP)/Contents/Frameworks
	@scripts/build-app-icon.sh $(ADAPTIVE_ICON) $(ICON) $(BUILT_ICON) $(MINIMUM_MACOS)
	@cp $(BUILT) $(APP)/Contents/MacOS/$(APP_NAME)
	@cp $(LOCALVQE_LIB) $(APP)/Contents/Frameworks/liblocalvqe.dylib
	@cp $(LOCALVQE_MODEL) $(APP)/Contents/Resources/Models/
	@cp $(LOCALVQE_ROOT)/verification.json $(APP)/Contents/Resources/LocalVQE-verification.json
	@sed -e 's/__SHORT_VERSION__/$(VERSION)/' -e 's/__BUILD_VERSION__/$(BUILD)/' \
		Packaging/Amanu-Info.plist > $(APP)/Contents/Info.plist
	@# UPDATES=off is for a build of your own: Sparkle would otherwise install
	@# the next release over it, since the release carries a valid signature.
	@if [ "$(UPDATES)" = off ]; then \
		plutil -remove SUFeedURL $(APP)/Contents/Info.plist \
		&& plutil -remove SUPublicEDKey $(APP)/Contents/Info.plist \
		&& plutil -replace SUEnableAutomaticChecks -bool NO $(APP)/Contents/Info.plist ; \
	fi
	@printf 'APPL????' > $(APP)/Contents/PkgInfo
	@cp $(BUILT_ICON)/Amanu.icns $(APP)/Contents/Resources/Amanu.icns
	@# Assets.car needs actool, which ships with Xcode and not with Command
	@# Line Tools; without it every macOS shows the classic icon.
	@[ ! -f $(BUILT_ICON)/Assets.car ] || cp $(BUILT_ICON)/Assets.car $(APP)/Contents/Resources/Assets.car
	@mkdir -p $(APP)/Contents/Resources/Licenses
	@cp LICENSE $(APP)/Contents/Resources/LICENSE
	@cp THIRD-PARTY-NOTICES.md $(APP)/Contents/Resources/
	@cp $(LOCALVQE_ROOT)/licenses/LocalVQE-LICENSE $(APP)/Contents/Resources/Licenses/
	@cp $(LOCALVQE_ROOT)/licenses/ggml-LICENSE $(APP)/Contents/Resources/Licenses/
	@cp .build/checkouts/FluidAudio/LICENSE \
		$(APP)/Contents/Resources/Licenses/FluidAudio-LICENSE
	@cp .build/checkouts/FluidAudio/ThirdPartyLicenses/fastcluster-LICENSE.md \
		$(APP)/Contents/Resources/Licenses/FluidAudio-fastcluster-LICENSE.md
	@cp .build/checkouts/FluidAudio/ThirdPartyLicenses/vbx-LICENSE.md \
		$(APP)/Contents/Resources/Licenses/FluidAudio-vbx-LICENSE.md
	@cp .build/checkouts/swift-argument-parser/LICENSE.txt \
		$(APP)/Contents/Resources/Licenses/swift-argument-parser-LICENSE.txt
	@cp .build/checkouts/Sparkle/LICENSE \
		$(APP)/Contents/Resources/Licenses/Sparkle-LICENSE
	@cp .build/checkouts/Sparkle/Vendor/ed25519-sparkle/license.txt \
		$(APP)/Contents/Resources/Licenses/Sparkle-ed25519-LICENSE.txt
	@cp Resources/Licenses/whisper.cpp-LICENSE \
		$(APP)/Contents/Resources/Licenses/whisper.cpp-LICENSE
	@cp Resources/Licenses/transcribe.cpp-LICENSE \
		$(APP)/Contents/Resources/Licenses/transcribe.cpp-LICENSE
	@cp Resources/Licenses/transcribe.cpp-ggml-LICENSE \
		$(APP)/Contents/Resources/Licenses/transcribe.cpp-ggml-LICENSE
	@cp Resources/Licenses/transcribe.cpp-miniz-LICENSE \
		$(APP)/Contents/Resources/Licenses/transcribe.cpp-miniz-LICENSE
	@test -s $(APP)/Contents/Resources/LICENSE \
		&& test -s $(APP)/Contents/Resources/Amanu.icns \
		&& { [ ! -f $(BUILT_ICON)/Assets.car ] || test -s $(APP)/Contents/Resources/Assets.car ; } \
		&& test -s $(APP)/Contents/Resources/THIRD-PARTY-NOTICES.md \
		&& test -s $(APP)/Contents/Resources/Models/localvqe-v1.4-aec-200K-f32.gguf \
		&& test -s $(APP)/Contents/Resources/LocalVQE-verification.json \
		&& test "$$(find $(APP)/Contents/Resources/Licenses -type f | wc -l | tr -d ' ')" = 12
	@test -n "$(SPARKLE_FW)" || (echo "Sparkle.framework not found — run swift build first"; exit 1)
	@test -n "$(WHISPER_FW)" || (echo "whisper.framework not found — run swift build first"; exit 1)
	@test -n "$(TRANSCRIBE_FW)" || (echo "CTranscribe.framework not found — run swift build first"; exit 1)
	@cp -R "$(SPARKLE_FW)" $(APP)/Contents/Frameworks/
	@cp -R "$(WHISPER_FW)" $(APP)/Contents/Frameworks/
	@cp -R "$(TRANSCRIBE_FW)" $(APP)/Contents/Frameworks/
	@# transcribe.cpp 0.2.0 ships the macOS framework with duplicated top-level
	@# files and a duplicated Versions/Current directory. codesign correctly
	@# rejects that as an ambiguous bundle, so restore the canonical framework
	@# symlink layout in the copy we distribute.
	@rm -rf \
		$(APP)/Contents/Frameworks/CTranscribe.framework/Versions/Current \
		$(APP)/Contents/Frameworks/CTranscribe.framework/CTranscribe \
		$(APP)/Contents/Frameworks/CTranscribe.framework/Headers \
		$(APP)/Contents/Frameworks/CTranscribe.framework/Modules \
		$(APP)/Contents/Frameworks/CTranscribe.framework/Resources
	@ln -s A $(APP)/Contents/Frameworks/CTranscribe.framework/Versions/Current
	@ln -s Versions/Current/CTranscribe $(APP)/Contents/Frameworks/CTranscribe.framework/CTranscribe
	@ln -s Versions/Current/Headers $(APP)/Contents/Frameworks/CTranscribe.framework/Headers
	@ln -s Versions/Current/Modules $(APP)/Contents/Frameworks/CTranscribe.framework/Modules
	@ln -s Versions/Current/Resources $(APP)/Contents/Frameworks/CTranscribe.framework/Resources
	@test -L $(APP)/Contents/Frameworks/CTranscribe.framework/Versions/Current
	@# Sparkle's XPC services exist so a sandboxed app can still download and
	@# install; amanu is not sandboxed, so they are two more binaries to sign,
	@# notarize and ship for nothing.
	@rm -rf $(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices
	@[ -x $(HOME)/.local/bin/unlock-signing-keychain ] \
		&& $(HOME)/.local/bin/unlock-signing-keychain >/dev/null 2>&1 || true
	@echo "signing app as: $(SIGN_ID)"
	@# Innermost first. codesign seals what it finds, so anything signed after
	@# the app that contains it invalidates the app's own seal — and the failure
	@# shows up as a Gatekeeper rejection on someone else's Mac, not here.
	@for nested in \
		$(APP)/Contents/Frameworks/liblocalvqe.dylib \
		$(APP)/Contents/Frameworks/whisper.framework \
		$(APP)/Contents/Frameworks/CTranscribe.framework \
		$(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate \
		$(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app \
		$(APP)/Contents/Frameworks/Sparkle.framework ; do \
		codesign --force --sign "$(SIGN_ID)" --options runtime --timestamp "$$nested" \
			2>/dev/null \
		|| codesign --force --sign "$(SIGN_ID)" --options runtime --timestamp=none "$$nested" ; \
	done
	@codesign --force --sign "$(SIGN_ID)" \
		--identifier me.samat.amanu \
		--options runtime \
		--entitlements $(ENTITLEMENTS) \
		--timestamp $(APP) 2>/dev/null \
	|| codesign --force --sign "$(SIGN_ID)" \
		--identifier me.samat.amanu \
		--options runtime \
		--entitlements $(ENTITLEMENTS) \
		--timestamp=none $(APP)
	@codesign --verify --strict --verbose=2 $(APP)
	@# A missing slice is invisible until someone on the wrong Mac opens the
	@# disk image, so fail here instead.
	@for bin in $(APP)/Contents/MacOS/$(APP_NAME) \
		$(APP)/Contents/Frameworks/liblocalvqe.dylib \
		$(APP)/Contents/Frameworks/whisper.framework/Versions/A/whisper \
		$(APP)/Contents/Frameworks/CTranscribe.framework/Versions/A/CTranscribe ; do \
		for arch in $(ARCHS) ; do \
			lipo -archs "$$bin" | grep -qw $$arch \
			|| { echo "$$bin has no $$arch slice: $$(lipo -archs "$$bin")"; exit 1; } ; \
		done ; \
	done
	@python3 scripts/verify-macos-compatibility.py $(APP) $(MINIMUM_MACOS)
	@echo "built → $(APP) ($(VERSION) build $(BUILD)) · $$(lipo -archs $(APP)/Contents/MacOS/$(APP_NAME))"

# Launch the way a person would: through LaunchServices, so the app is its own
# responsible process. Running the executable from a terminal instead is the
# one thing that reliably breaks system-audio capture (.issues/rca-002).
run-app: app
	@open $(APP)

# A build for this Mac alone, made with Command Line Tools: arm64 only, no
# update feed, and signed with a self-signed certificate so the microphone and
# system-audio grants survive the next rebuild. README.md says how to make the
# certificate.
LOCAL_SIGN_ID ?= Amanu Local Signing

# A self-signed certificate has no Team ID, and under the hardened runtime
# library validation then refuses the bundle's own frameworks — dyld stops at
# CTranscribe before main. The local build alone turns library validation off.
LOCAL_ENTITLEMENTS = .build/Amanu-local.entitlements

local:
	@mkdir -p .build
	@cp Packaging/Amanu.entitlements $(LOCAL_ENTITLEMENTS)
	@/usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" $(LOCAL_ENTITLEMENTS)
	@$(MAKE) app ARCHS=arm64 UPDATES=off SIGN_ID="$(LOCAL_SIGN_ID)" ENTITLEMENTS=$(LOCAL_ENTITLEMENTS)

# Quitting goes through amanu's own quit gate, which asks first mid-recording;
# the copy waits until the old process is really gone (see CLAUDE.md).
install-local: local
	@osascript -e 'quit app "Amanu"' 2>/dev/null || true
	@for i in $$(seq 30); do pgrep -xq Amanu || break; sleep 1; done
	@! pgrep -xq Amanu || (echo "Amanu is still running — is it recording?"; exit 1)
	@rm -rf /Applications/Amanu.app
	@cp -R $(APP) /Applications/
	@open /Applications/Amanu.app
	@echo "installed → /Applications/Amanu.app"

identities:
	@security find-identity -v -p codesigning

verify:
	@codesign -dvvv $(APP) 2>&1 | grep -E 'Identifier|Authority|TeamIdentifier|Signature|flags'
	@lipo -info $(APP)/Contents/MacOS/$(APP_NAME)

# The whole release, fail-closed: tests, bundle, signature, disk image,
# notarization, a draft GitHub release, the signed appcast, and only then
# anything public. scripts/release.sh says what it needs.
release:
	@scripts/release.sh

release-dry:
	@scripts/release.sh --dry-run

clean:
	swift package clean
