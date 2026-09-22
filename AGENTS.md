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
| Doğrulama komutları, kalite kapısı, yayın etkisi, **tuzaklar**, dil kuralı | [`.claude/is-akisi/proje.md`](.claude/is-akisi/proje.md) |
| İş seti düzeni, phase sıralaması, durum tablosu, set aralığı | [`.claude/is-akisi/duzen.md`](.claude/is-akisi/duzen.md) |
| Hangi skill ne yapar, zincir nasıl işler | [`.claude/README.md`](.claude/README.md) |
| Yapılmış işler, alınan kararlar, açık kalemler | [`.tasks/`](.tasks/) · indeks: [`.tasks/README.md`](.tasks/README.md) |

**Koda dokunmadan önce `proje.md` → Tuzaklar okunur.** Oradaki her madde bir kez
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
