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

`001`–`008` bitti, `009`–`010` teslim bekliyor: iskelet, kenar paneli, iki sağlayıcı ve hook sunucusu
çalışıyor; kurulu hook'lar `127.0.0.1:48151`'e akıyor. Maskotun beş fazının her birinin kendi klibi var (`MascotClip`);
altında sıradaki ilk 3–4 oturumun halkası atımla oynuyor, fazlası "+N".
`005`'in kodu bitti: hover'da bar sola açılıp adı ve "durum · süre"yi
gösteriyor; bir satırın üstünde durunca listenin solunda detay kartı açılıyor
(tık yok) ve [Oturuma git] oturumun terminalini izinsiz öne getiriyor
(`SessionHost`). `006`'nın kodu bitti: açık listede bütün oturumlar, en çok
7,5 satır görünür, liste gövdenin içinde kayar (solmalar, kart satırı izler),
altında özet satırı; kapalı bar "+N" ile aynı kaldı. `007`'nin kodu bitti:
bar sağ ya da sol kenara yaslanıyor (sol sağın aynası), seçim maskotun sağ tık
menüsünde ve tepside, kalıcı (`bar.edge`); bar ana ekranda. Faz 2 kapandı. `008`'de
menü, dizini olan her kaynak (Claude, Codex) için hook'ları kurar, günceller
ya da kaldırır (`HookSettings`); elle denemede kök `EVLAT_HOME` ile geçici
dizindir. `009`'un kodu bitti: açık gövdede özetin altında kaynak başına
ikonsuz kullanım bloğu (`UsageBlock`, 5h/7d); Codex rollout kuyruğundan,
Claude menüden kurulan durum satırı sarmalayıcısının `POST /usage/claude`'undan
(`StatusLineRelay`). `010`'un kodu bitti: SSH ile bağlanılan sunuculardaki
oturumlar makine adıyla barda (makine başına loopback dinleyici + `ssh -R`
tüneli; duyulamayan satır sönük, maskotu sürmez); menüdeki "Uzak makineler…"
penceresi makine ekler, bağlantıyı söyler, sunucuya otomatik ya da elle
kurar, kaldırır — Evlat'ın etkinleşen tek penceresi, bar yine odak çalmaz.
Metinler katalogda (`L10n`, `en`/`tr`). Güncel durum ve açık
kalemler için `.tasks/README.md`, sıradaki setler için `ROADMAP.md` → Fazlar.

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
- **Boş `EVLAT_SESSIONS` ölçümü yalıtmaz; `EVLAT_PORT` da gerekir.** Asıl
  Evlat kapatılınca ölçülen süreç `48151`'i alır ve açık Claude oturumlarının
  hook'ları ona akar: "0 satır" ölçümünün stderr'inde `working` satırı çıktı;
  `EVLAT_PORT=48999` ile aynı paket %0,02 (`004/phase-3`).
- **Patlayan klipte 90 sn'lik sayı *klip içi maliyet × çevrim oranı*dır.** Klip
  içi maliyet beklemesiz varyantla (`EVLAT_MASCOT_PACING=continuous`) ayrı
  ölçülür; çarpım 90 sn'yi iki yönde de şaşırıyor (`003`'te %37 altında, ~2 kat
  üstünde), kapı yine 90 sn'dir. Döngüsüz klipte: *klip içi × `movingTime` /
  pencere*.
- **Anahtar `.nonactivatingPanel` varken `NSApp.isActive` `true` okur.**
  Balon (`ChatPanel`) klavyeyi alınca AppKit'in bayrağı `true` oldu; öndeki
  uygulama, menü çubuğunun sahibi ve `NSRunningApplication.current.isActive`
  değişmedi, panel gidince bayrak `false`'a döndü (`011/phase-2`, ayrı süreçte
  ölçüldü). "Evlat öne gelmedi" sınaması bu üçüne bakar, `NSApp.isActive`'e
  değil.
- **`HoverIntent.closeNow` bekleyen açılışı düşürmez.** Maskota tıklamaya
  gelen imleç barı açmayı zaten istemişti; balon açılırken `closeNow` kapalı
  barda hiçbir şey yapmadı ve 80 ms sonra liste balonun altında açıldı
  (`011/phase-2`, gözle). Kapalı barda bekleyen açılışı `pointerExited` düşürür.
- **Bara gelen ctrl-tık `mouseDown`'dan da geçer.** Maskota sol tık balonu
  açınca ctrl-tık (menü) da balonu açtı ve bir sınamada anahtar panel sızdırdı
  (`011/phase-2`); `BarHostingView.mouseDown` ctrl'lü tıkı `onClick`'e vermez.
- **Balonun satırı sürüklenen dosyayı metin diye alır; SwiftUI başka alan
  editörüne izin vermez.** Alan editörü imlecin altındaki en derin görünümdür
  ve metin türüne kayıtlıdır (dosya URL'si de metin sunar): bırakılan dosyanın
  yolu satıra yazıldı. Özel alan editörü (`fieldEditor(_:for:)`) süreci
  düşürdü — `TextField` `_SystemTextFieldFieldEditor` bekliyor. Çare içeriğin
  **üstünde** duran, dosyaya kayıtlı, `hitTest`'i `nil` bir katman
  (`ChatDropView`, `011/phase-4`, gözle).
- **Pencerenin şeffaf pikseli sürüklemeyi almaz.** Barın 485 pt'lik zarfında
  yalnız çizili 54 pt sürükleme olayı gördü (`011/phase-4`, ölçüldü): "bara
  yaklaşma" alanı çizili bardır.
- **`NSApp.deactivate()` eşzamanlı değil.** Klasör panelinden sonra
  `deactivate` + balonu hemen `makeKey`: ardından gelen istifa balonun
  klavyesini aldı, balon kapandı ve Evlat önde kaldı (`011/phase-4`, gözle).
  Önceki uygulama `activate` edilir, balon `didResignActive`'ten sonra döner.
- **`proc_pidpath` kendini güncellemiş bir uygulamanın eski sürecinde boş
  döner** (`ENOENT`) — Orca'nın pty yardımcısı böyleydi ve 13 oturum
  "bulunamadı" okudu (`005/phase-5`). Başlatıldığı yol argüman alanında
  (`KERN_PROCARGS2`) durur. Aynı ölçümde `claude`'un kendisi
  `~/.local/share/claude/ClaudeCode.app` içinden koşuyordu: bir yolun `.app`
  içinde olması onu terminal yapmaz.
- **Codex'in `rollout-*.jsonl`'ı belgelenmemiş bir iç formattır ve büyür.**
  `~/.codex/sessions/*/*/*/` altında, codex-cli 0.156.1'de görüldü; en yenisi
  62 MB'a varan bir kopyada tamamını okumak yerine son 256 KB okundu (9–10 ms,
  `009/phase-2`). `codex-usage` `.derived`'dır: biçim bozulursa susar, son iyi
  okuma kalır, daha eski bir dosyaya düşülmez (eski gözlem yeni gibi okunurdu).
