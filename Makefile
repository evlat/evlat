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
calistir: paket
	-pkill -x Evlat 2>/dev/null
	@i=0; while pgrep -x Evlat >/dev/null; do \
		i=$$((i+1)); \
		if [ $$i -gt 50 ]; then echo "Evlat did not quit; forcing"; pkill -9 -x Evlat; sleep 0.5; break; fi; \
		sleep 0.1; \
	done
	open build/Evlat.app || { sleep 1; open build/Evlat.app; }

temizle:
	rm -rf .build build
