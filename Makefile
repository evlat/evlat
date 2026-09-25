.PHONY: derle test hepsi paket calistir kur temizle

derle:
	swift build

test:
	swift test

hepsi: derle test

paket:
	./scripts/bundle-app.sh

# `paket` is a prerequisite: after editing sources, `make calistir` used to open
# the previous bundle — silently running an older build is the most expensive
# kind of mistake in a measurement set. `make temizle && make calistir` broke on
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

# The installed copy. `kur` puts the bundle here so the login item and the
# `~/.local/bin/evlat` link point at a path that `make paket` and
# `make temizle` never delete. Both targets stop BOTH copies first: two Evlats
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

calistir: paket
	$(call stop_evlat,$(APP_PROC))
	$(call stop_evlat,$(EVLAT_PROC))
	open build/Evlat.app || { sleep 1; open build/Evlat.app; }

# `ditto` keeps the ad-hoc seal intact; the old bundle is removed first so a
# file dropped from the new build does not linger inside the installed one.
kur: paket
	$(call stop_evlat,$(EVLAT_PROC))
	$(call stop_evlat,$(APP_PROC))
	rm -rf '$(APP_DIR)/Evlat.app'
	ditto build/Evlat.app '$(APP_DIR)/Evlat.app'
	codesign --verify '$(APP_DIR)/Evlat.app'
	open '$(APP_DIR)/Evlat.app' || { sleep 1; open '$(APP_DIR)/Evlat.app'; }
	@echo "Installed: $(APP_DIR)/Evlat.app"

temizle:
	rm -rf .build build
