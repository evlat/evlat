.PHONY: build test all bundle run install release publish clean

build:
	swift build

test:
	swift test

all: build test

bundle:
	./scripts/bundle-app.sh

# `bundle` is a prerequisite: after editing sources, `make run` used to open
# the previous bundle — silently running an older build is the most expensive
# kind of mistake in a measurement set. `make clean && make run` broke on
# this too.
#
# `pkill` signals and returns. If `open` runs before the old process dies,
# LaunchServices still believes the app is open and fails with -600 (measured in
# v1). Let the process go first; if it will not, say so and force it. -600 can
# also arrive shortly after the process is gone, so `open` is retried once.
#
# The process is targeted BY PATH. v1 and v2 can both be installed and both
# carry the bundle id `dev.kalaomer.evlat`, so `-x Evlat` matched two processes
# and this target would kill the v1 the user is running. The `[.]` keeps the
# pattern from matching the shell that carries it on its own command line, and
# `$(CURDIR)` keeps it matching THIS checkout — a hardcoded directory name would
# quietly match nothing in a clone or a worktree, and a no-op guard here means
# `open` racing a live process for the -600 this target exists to avoid.
EVLAT_PROC = $(CURDIR)/build/Evlat[.]app/Contents/MacOS/Evlat

# The installed copy. `install` puts the bundle here so the login item and the
# `~/.local/bin/evlat` link point at a path that `make bundle` and
# `make clean` never delete. Both targets stop BOTH copies first: two Evlats
# race for port 48151 and the second one's hooks go nowhere.
APP_DIR = /Applications
APP_PROC = $(APP_DIR)/Evlat[.]app/Contents/MacOS/Evlat

# Stops the copy whose path matches $(1), forcing it after five seconds.
define stop_evlat
	@pkill -f '$(1)' 2>/dev/null || true
	@i=0; while pgrep -f '$(1)' >/dev/null; do \
		i=$$((i+1)); \
		if [ $$i -gt 50 ]; then echo "Evlat did not quit; forcing"; pkill -9 -f '$(1)'; sleep 0.5; break; fi; \
		sleep 0.1; \
	done
endef

run: bundle
	$(call stop_evlat,$(APP_PROC))
	$(call stop_evlat,$(EVLAT_PROC))
	open build/Evlat.app || { sleep 1; open build/Evlat.app; }

# `ditto` keeps the ad-hoc seal intact; the old bundle is removed first so a
# file dropped from the new build does not linger inside the installed one.
install: bundle
	$(call stop_evlat,$(EVLAT_PROC))
	$(call stop_evlat,$(APP_PROC))
	rm -rf '$(APP_DIR)/Evlat.app'
	ditto build/Evlat.app '$(APP_DIR)/Evlat.app'
	codesign --verify '$(APP_DIR)/Evlat.app'
	open '$(APP_DIR)/Evlat.app' || { sleep 1; open '$(APP_DIR)/Evlat.app'; }
	@echo "Installed: $(APP_DIR)/Evlat.app"

# Releasing is two steps, both run on this machine:
#
#   make release VERSION=0.2.0   build, sign, notarize, staple, write the
#                                appcast → build/release/0.2.0/; nothing leaves
#                                the machine except the notarization upload
#   make publish VERSION=0.2.0   tag the built commit, push the tag, create the
#                                GitHub release with the zip and the appcast
#
# The split is the point: the zip is tried on this machine before anything is
# public. `release` requires a clean tree and records the commit it built;
# `publish` tags THAT commit, not whatever HEAD is by then, so the tag always
# names the code inside the zip.
#
# Needs a "Developer ID Application" identity in the keychain, a notarytool
# profile (`xcrun notarytool store-credentials evlat …`) and Sparkle's EdDSA
# key in the keychain (`generate_keys`), whose public half is SPARKLE_KEY. The
# zip sent to Apple is not stapled; the one left behind is rebuilt from the
# stapled app, and only that one is signed for Sparkle.
#
# Installed copies update from FEED_URL: GitHub serves the newest release's
# appcast.xml there, so publishing a release is publishing the update.
RELEASE_IDENTITY ?= $(shell security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
NOTARY_PROFILE ?= evlat
SPARKLE_KEY =
REPO = evlat/evlat
FEED_URL = https://github.com/$(REPO)/releases/latest/download/appcast.xml
RELEASE_DIR = build/release/$(VERSION)
RELEASE_ZIP = $(RELEASE_DIR)/Evlat-$(VERSION).zip
RELEASE_COMMIT = $(RELEASE_DIR)/commit
RELEASE_URL = https://github.com/$(REPO)/releases/download/v$(VERSION)/Evlat-$(VERSION).zip

# Fails unless VERSION is x.y.z and v$(VERSION) is unused, locally and on origin.
define check_version
	@echo '$(VERSION)' | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' || { echo "Usage: make $@ VERSION=x.y.z"; exit 1; }
	@! git rev-parse -q --verify 'refs/tags/v$(VERSION)' >/dev/null || { echo "Tag v$(VERSION) already exists"; exit 1; }
	@! git ls-remote --exit-code --tags origin 'refs/tags/v$(VERSION)' >/dev/null || { echo "Tag v$(VERSION) already exists on origin"; exit 1; }
endef

release:
	$(call check_version)
	@test -z "$$(git status --porcelain)" || { echo "The working tree is not clean; commit first"; exit 1; }
	@test -n '$(RELEASE_IDENTITY)' || { echo "No Developer ID Application identity in the keychain"; exit 1; }
	@test -n '$(SPARKLE_KEY)' || { echo "SPARKLE_KEY is empty; run generate_keys and write its public key into the Makefile"; exit 1; }
	EVLAT_SIGN_IDENTITY='$(RELEASE_IDENTITY)' EVLAT_VERSION='$(VERSION)' \
		EVLAT_BUILD="$$(git rev-list --count HEAD)" \
		EVLAT_FEED_URL='$(FEED_URL)' EVLAT_ED_KEY='$(SPARKLE_KEY)' ./scripts/bundle-app.sh
	codesign --verify --deep --strict --verbose=2 build/Evlat.app
	rm -rf '$(RELEASE_DIR)' && mkdir -p '$(RELEASE_DIR)'
	ditto -c -k --keepParent build/Evlat.app '$(RELEASE_DIR)/notarize.zip'
	xcrun notarytool submit '$(RELEASE_DIR)/notarize.zip' --keychain-profile '$(NOTARY_PROFILE)' --wait
	rm -f '$(RELEASE_DIR)/notarize.zip'
	xcrun stapler staple build/Evlat.app
	spctl -a -vv -t exec build/Evlat.app
	ditto -c -k --keepParent build/Evlat.app '$(RELEASE_ZIP)'
	./scripts/make-appcast.sh build/Evlat.app '$(RELEASE_ZIP)' '$(RELEASE_URL)' '$(RELEASE_DIR)/appcast.xml'
	git rev-parse HEAD > '$(RELEASE_COMMIT)'
	@echo "Released: $(RELEASE_DIR) ($$(cat '$(RELEASE_COMMIT)'))"
	@echo "Try build/Evlat.app, then: make publish VERSION=$(VERSION)"

# The built commit must already be on origin/main: a tag pushed alone would
# publish a commit no branch holds.
publish:
	$(call check_version)
	@test -f '$(RELEASE_ZIP)' -a -f '$(RELEASE_DIR)/appcast.xml' -a -f '$(RELEASE_COMMIT)' || { echo "No $(RELEASE_DIR); run make release VERSION=$(VERSION) first"; exit 1; }
	git fetch -q origin main
	@git merge-base --is-ancestor "$$(cat '$(RELEASE_COMMIT)')" origin/main || { echo "The built commit is not on origin/main; push main first"; exit 1; }
	git tag -a 'v$(VERSION)' -m 'Evlat $(VERSION)' "$$(cat '$(RELEASE_COMMIT)')"
	git push origin 'v$(VERSION)'
	gh release create 'v$(VERSION)' '$(RELEASE_ZIP)' '$(RELEASE_DIR)/appcast.xml' \
		--repo '$(REPO)' --verify-tag --latest --title 'Evlat $(VERSION)' --generate-notes
	@echo "Published: v$(VERSION)"

clean:
	rm -rf .build build
