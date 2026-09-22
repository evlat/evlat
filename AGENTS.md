# AGENTS.md

Bu depoda çalışan ajanlar için giriş noktası. **Kısa tutuldu**: her kuralın tek
bir sahibi var ve burası ona işaret eder, içeriğini kopyalamaz.

| ne | nerede |
|---|---|
| Mimari kararlar, neden öyle | [`ROADMAP.md`](ROADMAP.md) |
| Doğrulama komutları, kalite kapısı, tuzaklar | [`.claude/is-akisi/proje.md`](.claude/is-akisi/proje.md) |
| İş seti düzeni, phase sıralaması, durum tablosu | [`.claude/is-akisi/duzen.md`](.claude/is-akisi/duzen.md) |
| Yapılmış işler ve kararların kaydı | [`.tasks/`](.tasks/) |

Bir çelişki görürsen: kod kazanır, sonra phase'in `## Uygulama Notları`'ı, sonra
`ROADMAP.md`. Biri yanlışsa düzelt, üstünden atlama.

---

## Proje ne

Evlat v2 — macOS için, ekranın kenarında duran bir durum şeridi. AI kodlama
oturumlarının ne yaptığını periferik olarak anlatır: barın başında bir maskot
toplu durumu gösterir, altında oturum başına bir gösterge durur.

Uygulama "AI oturumu" bilmez, **`Signal`** bilir. Oturum takibi bu soyutlamanın
ilk sağlayıcısıdır; usage, job ve dışarıdan gelen sinyaller aynı yoldan girer.

**Bugünkü durum:** `001` bitti — iskelet, kenar paneli, oturum sağlayıcısı ve
maskot çalışıyor. `waiting` durumu henüz görünmüyor; o ayrım hook'lardan geliyor
ve hook sunucusu `002`'de.

---

## Komutlar

```sh
make hepsi        # swift build + swift test — her phase'in kapısı
make derle        # hızlı iç döngü
make paket        # build/Evlat.app üretir
make calistir     # paketler ve çalıştırır (paket'e bağlı)
make temizle

swift run Evlat --list      # teşhis: oturumları yazdır, pencere açma
swift test --filter BarShapeTests
```

Pencereye, bara ya da maskota dokunduysan `make hepsi` yetmez:
`make paket && make calistir` ve **gözle bak**. Ne baktığını phase'in
`## Uygulama Notları`'na bir satır yaz — yazının yokluğu "bakılmadı" demektir.

---

## Yapı

```
Sources/EvlatCore/    ← yalnız Foundation + Dispatch. Platform bilmez.
Sources/EvlatApp/     ← AppKit + SwiftUI. Darwin'e dokunan tek katman.
Sources/Evlat/        ← yalnız main.swift; ince kabuk.
Tests/EvlatCoreTests/
Tests/EvlatAppTests/
```

Katman yönü **derleyiciyle** kapalı: `EvlatCore` hiçbir şeye bağlı değil, yani
`import EvlatApp` mümkün değil. `ImportPurityTests` bunun üstüne yalnız bir
tripwire ekler.

**Akış:**

```
~/.claude/sessions/*.json ─┐
                           ├─▶ SessionsProvider ─▶ Signal ─▶ Registry.snapshot()
       Platform (enjekte) ─┘                                        │
                                                                    ▼
                                                              MascotModel
                                                                    │
                                                        BarPanel ◀──┘
```

---

## Bozulmaz kurallar

Bunlar tercih değil; her biri bir kez bozuldu ve bir bedeli oldu.

**1. `EvlatCore` platforma dokunmaz.** `AppKit`, `SwiftUI`, `Network`, `Combine`
yok — ve `sysctl`, `kill`, `open` de yok. macOS'ta `Foundation` Darwin'i yeniden
ihraç ettiği için "yalnız Foundation import et" kuralı taşınabilirliği
**ölçmez**; v1'in `SessionHost.swift`'i tam olarak böyle yazılmış ve Linux'ta
derlenmiyor. Platform yeteneği `Platform` üstünden **kapanışla enjekte edilir**.

**2. Kodun dili İngilizce, defterin dili Türkçe.**

| nerede | dil | not |
|---|---|---|
| `Sources/` · `Tests/` · `Package.swift` · `Makefile` · `scripts/` | **İngilizce** | Yorumlar, tip ve değişken adları, sınama adları, `XCTAssert` mesajları, fixture dizgeleri **ve CLI bayrakları** (`--list`, `--liste` değil) |
| commit iletileri | **İngilizce** | Emir kipinde, tek satırlık özet |
| `Resources/{en,tr}.lproj/*.strings` | **iki dil** | Kaynak dil `en`, çeviri `tr` ve aksanları tam. Yeni bir metin **iki tabloya birden** girer. *(Katalog `004`'te geliyor; o zamana kadar arayüz metni geçici ve İngilizce.)* |
| `README.md` / `README.tr.md` | **iki dil** | `README.md` kanonik (İngilizce), `.tr` onun çevirisi. İkisi **birlikte** güncellenir. *(Henüz yok.)* |
| `ROADMAP.md` · `AGENTS.md` · `.tasks/` · `.claude/` | **Türkçe** | Kod değil, defter |

Kestirme ölçüt: **derleyici ya da kullanıcı görüyorsa İngilizce, yalnız biz
okuyorsak Türkçe.** Tek istisna katalogdur — kullanıcıya bakar ama tanımı gereği
iki dillidir.

v1 Türkçe yorumluydu; v2 değil. v1'den kod portlarken yorumlar **çevrilir**,
kopyalanmaz.

**3. İzin istemeyen tasarım.** Erişilebilirlik, Ekran Kaydı, Apple Events,
bildirim — hiçbiri. Yeni bir izin **mimari karardır**: dur ve sor. Sentetik tık
(`CGEvent`) ile test yazmak da bu kuralı bozar.

**4. Bağımlılık yok.** `Package.swift` → `dependencies` boş. Eklemek mimari
karardır: dur ve sor.

**5. Panel odak çalmaz.** `NSPanel` + `.nonactivatingPanel` + `canBecomeKey ==
false`. Bara tıklayınca kullanıcının terminali arkaya düşerse ürün biter.
`PanelConfigTests` bunun makineyle sınanabilen yarısını tutuyor.

**6. Boşta çizim durur.** Canlı bir şey yoksa animasyon view ağacından **çıkar**
(`if` ile, `.hidden()` ile değil). Gizlenen bir görünüm kare üretmeye devam eder.

**7. Ölçülmemiş sayı yazılmaz.** "Daha akıcı", "CPU düştü" ya ölçülür ya
cümleden düşer. Komut `proje.md` → Doğrulama'da.

**8. Kullanıcıya görünen metin katalogda durur.** Katalog `004`'te geliyor;
o zamana kadar yeni metin **eklenmez**, eklenirse borç olarak yazılır.

---

## İş akışı

```
/rfc  →  /plan-review  →  /implement  →  /ship
üretir    sınar            yürütür        teslim eder
```

- **Phase = tek commit.** Kod, checklist, `plan.md → ## Durum`'un ✅'ü birlikte
  girer.
- **`/code-review` teslimde değil, set sonunda** koşar — `/audit` ile birlikte,
  zorunlu, bir kez. `/ship` yalnız kapının koşup koşmadığını kontrol eder.
- **Gözle doğrulanamayan kapı "yapıldı" diye işaretlenmez.** Checklist'te
  `[~] gözle: kullanıcı doğrulayacak — {ne}` olur ve `teslim.md`'nin sabah
  listesine düşer.

---

## Bu depoya özgü tuzaklar

`001` sırasında gerçekten yakalananlar. Hepsi sessizce bozulan türden.

**`~/.claude/sessions/*.json` belgelenmemiş bir formattır.** `Fidelity`
`.derived`. Tanınmayan `status`, okunamayan `updatedAt` ve ayrıştırılamayan
kayıt **sayılır ve görünür kalır** — çünkü alan adı değişirse liste sessizce
boşalır ve teşhis "sağlıklı boş makine" der.

**PID geri dönüşümü.** Oturum kayıtları aylarca duruyor, macOS PID'leri yeniden
dağıtıyor. Yalnız canlılığa bakan bir kontrol hayalet oturum gösterir; kaydın
`startedAt`'i sürecin gerçek başlangıcıyla karşılaştırılır.

**Sürekli SwiftUI animasyonu pahalı.** Bu makinede ölçüldü: teknikten bağımsız
olarak ~%7 CPU. Maskot bu yüzden **atımlarla** canlanır — kısa bir kırpma ya da
seyrek bir nefes, arada durgun. Sürekli döngüye dönerse ürünün CPU bütçesi gider.

**`private let` struct `View`'da kalıcı depolama değildir.** SwiftUI görünümü her
ebeveyn güncellemesinde yeniden kurar. Orada saklanan bir `Timer` publisher'ı her
seferinde yeniden doğar ve zamanlayıcı hiç tamamlanmaz. `@State` ya da `static`.

**`@Published`'a her olayda yazma.** Fare hareketi ekran tazeleme hızında gelir;
ölü bant yoksa barın tamamı o hızda yeniden değerlendirilir. Yazmadan önce
değişiklik var mı diye bak.

**`ps -Axo … -p PID` yanlış satır döndürür** — `-A` filtreyi eziyor. Ölçümde
`-A` olmadan yaz.

**Ölçümün düşmesi her zaman iyi haber değil.** `001`'de CPU 0.0%'e indi ve bu bir
kazanç sanıldı; meğer hiç animasyon yapmayan bir maskot ölçülüyormuş. Sayıyı
okumadan önce **neyin** ölçüldüğünü sor.

---

## Sırada ne var

| set | ne |
|---|---|
| **002** | Hook sunucusu, `LocalAPI`, `POST /signal`. `waiting` buradan gelir. `Registry`'ye TTL/budama, iki kaynağın `sessionId` üstünden birleşmesi |
| **003** | Barın geri kalanı: dört kenar geometrisi, oturum göstergeleri, hover'da açılan panel, popover, **oturuma git** |
| **004** | Ayarlar, i18n, hook kurulum akışı, paketleme/imzalama |

Sonra: `kind: .usage` sağlayıcıları · görev paneli · Windows portu.
