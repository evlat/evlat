# AGENTS.md

Bu depoda çalışan ajanlar için **harita**. Kural taşımaz, kuralın sahibine
götürür — aynı kural iki yerde dursa biri düzeltildiğinde öteki sessizce eskir.

## Proje ne

Evlat v2 — macOS için, ekranın kenarında duran bir durum şeridi. AI kodlama
oturumlarının ne yaptığını periferik olarak anlatır: barın başında bir maskot
toplu durumu gösterir, altında oturum başına bir gösterge durur.

Uygulama "AI oturumu" bilmez, **`Signal`** bilir. Oturum takibi bu soyutlamanın
ilk sağlayıcısıdır; usage, job ve dışarıdan gelen sinyaller aynı yoldan girer.

## Nereye bakmalı

| ne arıyorsan | sahibi |
|---|---|
| Mimari kararlar ve **neden** öyle | [`ROADMAP.md`](ROADMAP.md) |
| Doğrulama komutları, kalite kapısı, yayın etkisi, dil kuralı, `001`–`002` tuzakları | [`.claude/is-akisi/proje.md`](.claude/is-akisi/proje.md) |
| `003`'ten itibaren yakalanan tuzaklar | bu dosya → [Tuzaklar](#tuzaklar) |
| İş seti düzeni, phase sıralaması, durum tablosu, set aralığı | [`.claude/is-akisi/duzen.md`](.claude/is-akisi/duzen.md) |
| Hangi skill ne yapar, zincir nasıl işler | [`.claude/README.md`](.claude/README.md) |
| Yapılmış işler, alınan kararlar, açık kalemler | [`.tasks/`](.tasks/) · indeks: [`.tasks/README.md`](.tasks/README.md) |

**Koda dokunmadan önce `proje.md` → Tuzaklar ve aşağıdaki Tuzaklar okunur.** Oradaki her madde bir kez
bozuldu ve bir bedeli oldu; hiçbiri tahmin değil.

## Çelişki çıkarsa

Kod kazanır → sonra ilgili phase'in `## Uygulama Notları`'ı → sonra
`ROADMAP.md`. Biri yanlışsa **düzelt**, üstünden atlama: haritada yazan bir şeyin
koddaki karşılığı yoksa ikisinden biri yalan söylüyordur.

## Şu an nerede

`001`, `002` ve `003` bitti: iskelet, kenar paneli, iki sağlayıcı ve hook
sunucusu çalışıyor; kurulu hook'lar hiçbir kurulum yapılmadan
`127.0.0.1:48151`'e akıyor. Maskotun beş fazının her birinin kendi klibi var
(`MascotClip`), her kanalın tek yazıcısı klip ve bakış faz başına `gazeMix` ile
toplanıyor. Bar henüz oturum satırı çizmiyor — o artık `004`'ün işi (numara
kayması: `ROADMAP.md` → Fazlar). Güncel durum ve açık kalemler için
`.tasks/README.md`, sıradaki setler için `ROADMAP.md` → Fazlar.

## Tuzaklar

Kodun ve ölçümün öğrettikleri. Her madde bir kez gerçekten yakalandı; yeni
tuzak buraya eklenir (`.claude/` iş akışıdır, proje bilgisi taşımaz).

- **`asyncAfter` kapanışındaki `self` bir struct `View`'ın kopyasıdır.**
  `@State` canlı okunur, `let` alanı kapanışın kurulduğu anda donar.
  `ClipPlayer`'ın `let phase`'i yüzünden `waiting` bitmeden gelen `working`
  maskotu donduruyordu (`003` kapısı). Kapanıştan okunacak her şey `@State`'te.
- **`keyframeAnimator` tetiğin *değişmesinde* ateşler, ilk görünmede asla.**
  Dal değişimi (uyur → uyanık) sahibini sıfırdan kurarsa `failed` titremesi hiç
  oynamaz (`003/phase-1`). Geçici animasyonun sahibi dalların **üstünde** durur.
- **Faz değişimi maskotun ritmini sıfırlamaz.** Her değişimde beklemeyi baştan
  başlatan bir zamanlayıcı, faz hızlı sallanırken maskotu hiç kırptırmaz.
  `001`'de düştü, `003/phase-1`'de yeniden yazıldı. Döngülü klipte faz
  değişimi pozu taşır, takvime dokunmaz.
- **Uyuyan maskot da bakışı izler; boşta ölçümü fareye duyarlıdır.** Aynı
  uyuyan kod bir gün %0,04, ertesi gün %3,43 okudu; A/B fark bulmadı
  (%0,85 ↔ %0,90), fark pencere boyunca farenin kullanılmasıydı (`003/phase-2`).
  Boşta ölçümünde pencerenin başında ve sonunda fare/klavye hareketsizliği
  yazılır:
  `ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'`
- **Ölçülecek ikili mutlak yolla başlatılır.** Göreli yolla (`build/Evlat.app/…`)
  koşan süreç `pgrep -f 'evlat-v2/build/…'`'e ve `Makefile`'ın korumasına
  görünmez; `003/phase-4`'te ölçüm boş pid okudu.
- **Patlayan klipte 90 sn'lik sayı *klip içi maliyet × çevrim oranı*dır.** Klip
  içi maliyet beklemesiz varyantla (`EVLAT_MASCOT_PACING=continuous`) ayrı
  ölçülür; çarpım 90 sn'yi iki yönde de şaşırıyor (`003`'te %37 altında, ~2 kat
  üstünde), kapı yine 90 sn'dir. Döngüsüz klipte: *klip içi × `movingTime` /
  pencere*.
