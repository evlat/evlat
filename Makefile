.PHONY: derle test hepsi paket calistir temizle

derle:
	swift build

test:
	swift test

hepsi: derle test

paket:
	./scripts/bundle-app.sh

# `paket` ön koşul: kaynak değiştikten sonra `make calistir` eski paketi
# açıyordu — sessizce bir önceki sürümü çalıştırmak, ölçüm setinde en pahalı
# hata türü. `make temizle && make calistir` de bundan kırılıyordu.
#
# `pkill` sinyali gönderip döner. Eski süreç ölmeden `open` koşarsa
# LaunchServices uygulamayı hâlâ açık sanıp -600 ile düşüyor (v1'de ölçüldü).
# Önce süreç gitsin; gitmezse bunu söyleyip zorla kapat. -600 süreç gittikten
# az sonra da gelebildiği için `open` bir kez daha denenir.
calistir: paket
	-pkill -x Evlat 2>/dev/null
	@i=0; while pgrep -x Evlat >/dev/null; do \
		i=$$((i+1)); \
		if [ $$i -gt 50 ]; then echo "Evlat kapanmadı, zorla kapatılıyor"; pkill -9 -x Evlat; sleep 0.5; break; fi; \
		sleep 0.1; \
	done
	open build/Evlat.app || { sleep 1; open build/Evlat.app; }

temizle:
	rm -rf .build build
