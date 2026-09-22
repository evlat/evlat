.PHONY: derle test hepsi paket calistir temizle

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

calistir: paket
	-pkill -f '$(EVLAT_PROC)' 2>/dev/null
	@i=0; while pgrep -f '$(EVLAT_PROC)' >/dev/null; do \
		i=$$((i+1)); \
		if [ $$i -gt 50 ]; then echo "Evlat did not quit; forcing"; pkill -9 -f '$(EVLAT_PROC)'; sleep 0.5; break; fi; \
		sleep 0.1; \
	done
	open build/Evlat.app || { sleep 1; open build/Evlat.app; }

temizle:
	rm -rf .build build
