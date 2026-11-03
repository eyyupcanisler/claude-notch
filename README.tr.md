# ClaudeNotch

[English](README.md) · **Türkçe**

![ClaudeNotch demo](docs/demo.gif)

MacBook çentiğinde (notch) yaşayan, menü çubuğunda ikonu olmayan (`LSUIElement`) bir macOS
uygulaması. Claude Code oturumlarının durumunu gösterir (çalışıyor / bitti / girdi bekliyor /
hata) ve terminalde olmasanız bile izin isteklerini çentikten **İzin ver / Her zaman / Reddet**
ile yanıtlamanızı sağlar.

## Nasıl çalışır

```
Claude Code ──hook──> hooks/claude-notch-hook.sh ──curl──> Unix soketi ──> ClaudeNotch.app
                                                    ~/Library/Application Support/ClaudeNotch/notch.sock
```

- Soket dizini `0700`, soket dosyası `0600`. TCP portu **yoktur**.
- `PermissionRequest` hook'u terminaldeki izin penceresiyle **eş zamanlı** çalışır. Çentikten
  yanıt verirseniz pencere kapanır ve araç çalışır; terminalde yanıtlarsanız kart, ilgili
  `PostToolUse` olayıyla (yaklaşık 1-2 sn içinde) otomatik kaybolur.
- Uygulama kapalıysa ya da soket yoksa hook sessizce çıkar (çıktı yok, `exit 0`); terminaldeki
  normal izin akışı etkilenmez. Köprü hiçbir zaman varsayılan olarak "izin ver" demez.

## Google Takvim (doğrudan bağlantı)

ClaudeNotch Google'a kendi OAuth istemcinle bağlanır (yalnız okuma). Bir kez:

1. <https://console.cloud.google.com> → yeni bir proje (ör. "ClaudeNotch").
2. **APIs & Services → Library** → "Google Calendar API" → **Enable**.
3. **APIs & Services → OAuth consent screen** (Google Auth Platform):
   - Google Workspace hesabıysan **Internal** seç: doğrulama gerekmez, oturum kalıcıdır.
   - Kişisel Gmail ise **External** + kendini **Test users**'a ekle. "Testing" durumunda
     Google oturumu 7 günde bir sona erdirir; kalıcı olsun istersen yayın durumunu
     "In production" yap (doğrulanmamış uygulama uyarısını bir kez geçmen gerekir).
   - Scope: `.../auth/calendar.readonly`.
4. **Credentials → Create credentials → OAuth client ID → Application type: Desktop app**
   → oluştur → **Download JSON** (`client_secret_….json`).
5. ClaudeNotch Ayarları → Modüller → Takvim → Kaynak: **Google Takvim** → **İstemci
   dosyasını seç…** → indirdiğin JSON → **Google ile bağlan** → tarayıcıda izin ver.

İstemci bilgisi ve jetonlar yalnız senin okuyabildiğin bir dosyada tutulur
(`~/Library/Application Support/ClaudeNotch/google.json`, `0600`); JSON dosyasını depoya koyma. Toplantının Meet / Zoom
bağlantısı varsa ada ve takvim kartı başlangıçtan 15 dk önce **Katıl** düğmesi gösterir.

## Derleme

```sh
scripts/make-signing-identity.sh  # bir kez: kendi anahtar zincirine "ClaudeNotch Dev"
scripts/build-app.sh              # build.noindex/ClaudeNotch.app üretir (release)
scripts/install-app.sh            # ~/Applications'a kopyalar ve başlatır
swift test                        # birim testleri
```

- Uygulamanın Dock simgesi ve penceresi yoktur; arayüzü çentiktir. Çalışırken Spotlight'tan
  (ya da Finder/Launchpad'den) yeniden açmak **Ayarlar**'ı getirir. Ayarlar'a ayrıca panel
  bandındaki dişliden ve çentiğe sağ tıklayarak da ulaşılır.

- `make-signing-identity.sh` kimliği oturum açma anahtar zincirine değil, ayrı bir anahtar
  zincirine koyar: `~/Library/Keychains/claude-notch-signing.keychain-db` (rastgele parolası
  `~/Library/Application Support/ClaudeNotch/signing-keychain.pass`, izin 0600). Parolayı
  bildiği için codesign erişimini (`set-key-partition-list`) penceresiz ayarlar; oturum açma
  parolası gerekmez. Tekrar çalıştırılabilir; güven ayarı eklemez.
- `build-app.sh`, `CLAUDE_NOTCH_SIGN_ID` (varsayılan `ClaudeNotch Dev`) kimliğiyle bu anahtar
  zincirinden imzalar (zinciri yalnızca imza süresince arama listesine ekler, sonra listeyi
  geri yükler); o zincir yoksa aynı adlı başka bir kimliği, o da yoksa ad-hoc imzayı dener.
  Kalıcı kimlikle tasarım gereksinimi `certificate leaf = H"…"` olur (cdhash değil); bu yüzden
  Otomasyon izni (ClaudeNotch → Ghostty) bir kez verilince yeniden derlemelerde korunur.
  Ad-hoc imzada her derlemeden sonra izin yeniden istenir.

Gereksinimler: macOS 14+, Swift 6 araç zinciri, `jq` ve `curl`.

## Hook kurulumu

```sh
scripts/install-hooks.sh                       # ~/.claude/settings.json içine ekler
scripts/install-hooks.sh --print               # yazmadan hook JSON'unu gösterir
scripts/install-hooks.sh --settings ./test.json  # başka bir ayar dosyasını hedefler
scripts/install-hooks.sh --uninstall           # ClaudeNotch hook'larını kaldırır
```

- Yazmadan önce `settings.json.bak.<zaman damgası>.<rastgele>` yedeği alınır, diğer tüm anahtarlar korunur.
- Betik tekrar çalıştırılabilir (idempotent): önceki ClaudeNotch kayıtları silinip yeniden eklenir.
- Kaydedilen hook'lar: `PermissionRequest` (bloklayan, 600 sn) ve async olay hook'ları
  `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `Stop`,
  `StopFailure`, `Notification`, `SessionEnd`.
- Hook betiğinin yolu mutlaktır; proje klasörünü taşırsanız kurulumu yeniden çalıştırın.

## Kullanım

- **Kapalı:** oturum yoksa yalnızca donanım çentiği görünür, hiçbir şey çizilmez. Oturum varsa
  çentiğin hemen altında (2 pt boşluk) ortalı, 3 pt'lik bir **durum çizgisi** belirir: çentik
  genişliğinin iki yanından 24 pt içeride, oturum başına bir parça (en çok 6, sabit sırada).
  Turuncu ışıltı: çalışıyor; amber nefes: sizi bekliyor (izin / soru / plan / girdi); yeşil:
  görülmemiş "bitti" (gelişte bir kez parlar); kırmızı: hata; soluk beyaz: boşta. Hareketi
  azalt açıkken renkler durağandır. Çizgi menü çubuğu bandına hiç taşmaz; bandın çentik
  dışındaki kısmında tıklamalar her zaman arkadaki menülere gider.
- **Göz atma (peek):** izin, soru, bitti ve hata olayları çentikten aşağı doğru düz siyah bir
  ada olarak düşer: bant içinde tam çentik genişliğinde, bandın hemen altında küçük iç bükey
  kavislerle genişler (bitti / hata ~300 pt tek satır, izin ~380 pt iki satır + küçük
  düğmeler). "Bitti" 2,5 sn kalır; izin isteği aşağıdaki [izin akışına](#izin-akışı-ve-kısayollar)
  göre kalır. Üzerindeyken kapanmaz, sonra çizgiye geri döner (amber parça nefes almaya devam
  eder). Metin tek satıra sığmıyorsa İzin ver yerine **Tümünü gör** çıkar. 1,5 sn içindeki
  "bitti"ler birleştirilir ("2 oturum bitti").
- **Panel:** yalnızca siz açtığınızda: çentik ya da çizgi üzerinde ~300 ms beklemek (hızlı
  geçişler yok sayılır), çentiğe tıklamak ya da ⌃⌥Space. 600 pt genişliğinde, ortalıdır ve açık
  kaldığı sürece kendi genişliği boyunca menü çubuğu bandını alır: çentiğin solunda iğne
  (sabitle), dişli (ayarlar) ve Ghostty izni eksikse kilit simgesi; sağında "N izin" ve
  "N çalışıyor" çipleri. Gövde gerçek buzlu cam (Saydamlığı azalt açıkken düz koyu); kartlar
  ve satırlar düz, yükseltilmiş bir katmandadır. İmleç çıkınca kapanır (sabitliyse ya da
  klavyeyle açıldıysa kapanmaz).
- **Liste ve kartlar:** sıra sabittir (sizi bekleyenler, bitenler, çalışanlar, sessiz, boşta) ve
  imleç paneldeyken değişmez; "Kartı göster" bir satırı karta taşıyınca karttan çıkan oturum
  onun yerine geçer, diğer satırlar kıpırdamaz. Birden çok kart 1/N sayfalayıcıyla gezilir.
  Reddet solda, İzin ver sağda, "Her zaman" ⋯ altında kuralıyla. Riskli komutlarda (rm -rf,
  sudo, curl | sh, chmod -R, git push --force, > /dev/…; ayrıca veri sızdırma biçimleri: curl /
  wget ile dosya gönderme `-d @dosya`, `--data-binary @`, `-F x=@`, `-T`, `--upload-file`,
  `--post-file`; uzak sunucuya scp / rsync / sftp; nc / ncat; ~/.ssh, ~/.aws, .env, *.pem,
  *.key içeriğinin bir yere aktarılması) İzin ver basılı tutulmalı (600 ms) ya da ⌘⏎
  kullanılmalı.
- **Klavye (panel ⌃⌥Space ile açılınca):** ⌘⏎ İzin ver, ⌘⇧⏎ Her zaman, ⌘⌫ Reddet, ←/→
  istekler, ↑/↓ oturumlar, Boşluk tüm metni aç / sonraki sayfa, ⏎ terminale git, Esc kapat.
  Her karar yeni bir tuş basışı ister: basılı tutulan ⌘⏎ (tuş tekrarı) yalnızca bir kartı
  onaylar, sonraki karar için tuşun bırakılması gerekir. ⌘⇧⏎ önce kuralı gösterir; kural en az
  0,8 sn ekranda kaldıktan sonra ikinci, ayrı bir basış kaydeder. Fare tıklamaları odağı çalmaz.
- **Oturum keşfi:** hook'lar kurulmadan önce başlamış ya da o zamandan beri hiç olay
  göndermemiş oturumlar da listede görünür. Uygulama açılışta ve her ~5 sn'de süreçleri kendi
  içinde tarar (libproc / sysctl; `ps` çalıştırmaz): adı / yolu `claude` olan (bu makinede
  `~/.local/share/claude/versions/<sürüm>`, `claude` olarak başlatılır; npm kurulumunda
  `node …/@anthropic-ai/claude-code/cli.js`), bir terminali (tty) olan ve üst süreci (aradaki
  kabuklar atlanarak) başka bir claude olmayan her süreç. Bir hook oturumunun sahip olmadığı her
  tty için bir satır açılır (arayüzde yalnızca **Boşta** görünür): proje = çalışma dizininin son parçası, durum
  **Boşta** (sahte etkinlik yok), terminal TERM_PROGRAM'dan. Aynı tty / pid'den ilk hook olayı
  gelince satır o hook oturumuna dönüşür (session_id hook'unki olur, çizgideki yeri değişmez,
  çift satır olmaz). Keşfedilen satırlar sürecin gerçek başlama zamanına göre sıralanır. Süreç
  çıkınca satır kalkar. `SessionEnd`'den sonraki 10 sn yeniden
  keşfedilmez (/clear).
- **Sekme adı (Ghostty):** Ghostty için Otomasyon izni **zaten verilmişse** (uygulama izni
  kendiliğinden sormaz) panel açılınca ve oturum varken ~15 sn'de bir tek bir AppleScript
  çağrısıyla (`tty` ve `name of every terminal`) sekme adları okunur. Ad satırın ikincil
  metni olur ve aynı projedeki oturumları ayırt eder (ad da aynıysa dal / tty eki eklenir).
  Kontrol, çift yönlü ve görünmez karakterler atılır, Claude Code'un baştaki dönen / durum
  simgesi (⠂ ◐ ✳) silinir, uzun adın ortası kısaltılır. İzin yoksa eski ayırt edici (dal, tty
  eki) kullanılır.
- Satıra tıklamak o oturumun **sekmesini** öne getirir (Ghostty, Terminal, iTerm2 için tty ile;
  diğer terminallerde yalnızca uygulama). Satır üzerindeki düğmeler: Odakla, Okundu, Son mesajı
  kopyala. İlk odaklamada macOS Otomasyon izni ister.
- **Ghostty iznini ver:** Otomasyon izni henüz sorulmadıysa ya da reddedildiyse panel bandında
  amber kilit simgesi ve sağ tık menüsünde "Ghostty iznini ver…" görünür. Tıklamak macOS izin
  penceresini açar (arka planda; çentik donmaz). Daha önce reddedildiyse Sistem Ayarları >
  Gizlilik ve Güvenlik > Otomasyon açılır.
- **Birden çok ekran / çentiksiz ekran:** tam arayüz çentikli ekrandadır; çalıştığınız ekran
  başkaysa onun menü çubuğunun ortasında 180 pt'lik siyah bir yapay çentik görünür ve aynı model
  geçerlidir (altında durum çizgisi, peek ondan düşer, panel onun bandını alır). Ayarlar > Ekran: Otomatik / Sadece
  çentikli / Tümü.
- Sağ tık: gerekiyorsa **Ghostty iznini ver**, **Ayarlar** (ekran, satır yoğunluğu,
  kısayollar, izin isteğinin görünür kalma süresi, olay başına sesler, oturum açılışında
  başlat), **Hook kurulumunu göster**, **Çık**.

## İzin akışı ve kısayollar

**İstek gelince:** ses (Ayarlar > Bildirim sesleri) ve çentikten izin adası düşer: araç,
proje, tek satır komut, kalan süre halkası (hook'un ~590 sn'lik süresine doğru boşalır; son 2
dakikada süre de yazılır), **Reddet ⌃⌥N** ve **İzin ver ⌃⌥Y** düğmeleri (düğmedeki tuşlar
sizin ayarladığınız kısayollardır; kaydedilemeyen kısayolun tuşu gösterilmez). İlk kullanıma
kadar adanın altında bir kez "⌃⌥Y izin ver · ⌃⌥N reddet" satırı görünür; kısayollardan biri ilk
kez işe yarayınca kaybolur.

**Ne kadar kalır:** yanıtlanmayan istek Ayarlar > Bildirim > "İzin isteği görünür kalsın"
kadar kalır: **8 sn / 15 sn (varsayılan) / 30 sn / Yanıtlanana kadar**. İmleç üzerindeyken
kapanmaz. Süre dolunca ada çizgiye geri çekilir, istek **bekler**: çizgideki parçası amber
nefes alır, panelde kartı durur. İstek, siz çentikten ya da terminalden yanıtlayana veya
hook'un ~590 sn'lik süresi dolana kadar yaşar (süre dolarsa terminaldeki pencere geçerli
kalır; köprü hiçbir zaman kendiliğinden izin vermez). "Yanıtlanana kadar" seçiliyken açık bir
izin adası, o sırada gelen "bitti" adalarını bekletir (çizgide yine görünürler).

**Global kısayollar** (Carbon `RegisterEventHotKey`; Erişilebilirlik izni gerekmez): her
uygulamadan çalışır, odağı almaz, ClaudeNotch'u öne getirmez.

| Kısayol | Varsayılan | Ne yapar |
| --- | --- | --- |
| Paneli aç | ⌃⌥Space | Paneli klavye kipinde açar / kapatır (aşağıdaki ⌘ tuşları) |
| İzin ver | ⌃⌥Y | Ekranda gösterilen isteğe izin verir |
| Reddet | ⌃⌥N | Ekranda gösterilen isteği reddeder |

Kurallar (tıklamalarla aynı tek karar yolunda uygulanır, yalnızca görünümde değil):

- Yalnızca **ekranda gösterilen** isteğe uygulanır: adadaki istek ya da açık paneldeki kart.
  Hiçbir istek gösterilmiyorsa (ada çizgiye dönmüşse) ilk ⌃⌥Y / ⌃⌥N en eski bekleyen isteğin
  adasını geri getirir ve **başka hiçbir şey yapmaz**; karar, bekleme süresinden sonraki
  basışta verilir.
- Gösterilen metin tamamı görünmüyorsa (adada tek satıra sığmıyor, kartta "Tümünü göster"
  kapalı ya da sonuna kadar okunmamış) ⌃⌥Y izin vermez, **tüm metni açar**: adadan panel o
  kartla açılır (anahtar pencere olmaz, imleç gelene kadar kapanmaz; imleç hiç gelmezse
  görünür kalma süresi sonunda kapanır), kartta metin açılır; açık ama okunmamış metinde ⌃⌥Y
  bir sayfa kaydırır. Metnin sonunu gösteren sayfadan sonra 0,8 sn beklenir; izin ancak ondan
  sonraki ayrı bir basışla verilir (sayfalama ve izin aynı tuş ritmine düşmez). **Write / Edit /
  MultiEdit / NotebookEdit** isteklerinde yazılacak içerik ya da eski/yeni metin de bu "tüm
  metne" dahildir: adada yalnızca dosya yolu görünse bile ⌃⌥Y önce içeriği açar. ⌃⌥N
  kısaltılmış istekte de reddeder (reddetmek güvenlidir), ama yine yalnızca gösterilende.
- **Riskli komutta** (yukarıdaki liste) ⌃⌥Y **0,6 sn basılı tutulmalıdır**: İzin ver
  düğmesindeki halka dolar, tuş bırakılınca dolmadan iptal olur. Kısa basış yalnızca düğmeyi
  "Basılı tutun" diye vurgular. ⌃⌥N basılı tutma istemez.
- Tuş tekrarı yok sayılır: basılı tutulan kısayol bir kez karar verir, sonraki karar için tuş
  bırakılmalıdır. Bekleme süreleri geçerlidir: yeni ya da geri getirilen istek 0,8 sn, bir kart
  kalkınca ~0,5 sn kısayolları da kabul etmez. Panel açıldığında (⌃⌥Space, üzerine gelme ya da
  tıklama) karttaki istek de yeni gösterilmiş sayılır ve 0,8 sn bekler; adadan açılan panel
  adadaki isteği gösterir, başka birini değil.
- Adadan verilen bir karardan sonra sıradaki bekleyen istek ~0,5 sn sonra düşer (aynı basışın
  altına hiçbir zaman anında gelmez) ve yine 0,8 sn bekler.
- **"Her zaman"ın global kısayolu yoktur** (yalnızca tıklama ya da panel klavye kipinde ⌘⇧⏎).

**Ayarlar > Kısayollar:** üç kısayol kaydedici (Paneli aç, İzin ver, Reddet). Düğmeye tıklayıp
yeni tuş bileşimine basın (en az ⌃, ⌥ ya da ⌘ gerekir; Esc vazgeçer). **İzin ver** ve
**Reddet** her uygulamadan çalıştığı için yazılan ya da uygulama kısayolu olan bir bileşim
olamaz: ⌃ ile birlikte bir değiştirici daha (⌃⌥, ⌃⇧, ⌃⌘) ya da ⌘⌥ gerekir; tek ⌥ / ⌥⇧
(karakter yazar, ör. ⌥Q = @), tek ⌘ / ⌘⇧ (⌘V, ⌘⇧Z…) ve tek ⌃ (terminalde ⌃C…) reddedilir.
Aynı anda yalnızca bir kaydedici dinler (birine tıklamak diğerini durdurur) ve kayıt
sırasında ClaudeNotch kendi kısayollarını geçici olarak bırakır. Diğer iki kısayoldan biriyle çakışırsa,
macOS'un açık bir kısayoluysa (Spotlight, ekran görüntüsü…) ya da kayıt başarısız olursa Türkçe
hata gösterilir ve önceki kısayol korunur. Not: macOS başka bir uygulamanın aynı bileşimi
kullandığını bildirmez; o durumda kısayolu değiştirin. **Varsayılana dön** üçünü sıfırlar.
Değişiklikler UserDefaults'a yazılır ve hemen yeniden kaydedilir. Varsayılan Y / N tuşları
geçerli klavye düzenine göre bulunur.

## Notlar ve sınırlar

- `auto` izin modunda `PermissionRequest` nadiren tetiklenir; bu yüzden onay kartları çoğunlukla
  `default` / `acceptEdits` oturumlarında görünür. "Bitti" ve "girdi bekliyor" bildirimleri her
  modda çalışır. Terminalde yanıtlamak her zaman mümkündür.
- **Sessiz mod** (panel bandındaki 🔔): yalnız izin istekleri ve sorular adaya düşer ve ses
  çıkarır. macOS Odak durumunu yalnızca Apple'ın yetki verdiği uygulamalara paylaştığı için
  Odak modu otomatik izlenmez; bu düğme onun yerine geçer.
- `AskUserQuestion` çentikten yanıtlanabilir: `PreToolUse` kancası (eşleşen araç
  `AskUserQuestion`) soruyu bekletir, çentikte seçenekler düğme olarak çıkar; seçip **Gönder**
  dendiğinde yanıt `updatedInput.answers` ile Claude Code'a döner (çoklu seçimde etiketler
  ", " ile birleşir). Düğmeler soru göründükten 0,8 sn sonra etkinleşir. **Terminalde yanıtla**,
  o oturumun Ghostty sekmesine geçmek, uygulamanın kapanması ya da 10 dk zaman aşımı soruyu
  terminale bırakır (boş yanıt). Serbest metin ("Diğer") terminalde kalır. Bu kanca
  `scripts/install-hooks.sh` yeniden çalıştırılınca eklenir.
- `ExitPlanMode` (plan onayı) terminalde kalır: çentikte "Plan onayı bekliyor" görünür.
- İzni terminalde **reddederseniz** `PostToolUse` gelmez; kart, aynı oturumdaki (ve aynı
  alt ajandaki) farklı bir `PreToolUse` (1,5 sn'den sonra), `UserPromptSubmit`, `Stop`,
  `StopFailure`, `SessionEnd` ya da `idle_prompt` bildirimiyle temizlenir. Aynı çağrı yeniden
  istenirse eski kart yenisiyle değiştirilir. Ana ajanın `Stop` olayı alt ajan kartlarını silmez.
- Kartta komut/yol/URL uzunsa baş ve son kısmı gösterilir, ortası "[N karakter gizli]" olarak
  işaretlenir; **İzin ver** ve **Her zaman** düğmeleri (ve ⌘⏎) "Tümünü göster" açılıp metin
  sonuna kadar kaydırılana kadar kapalıdır ("Sonuna kadar kaydırın"; klavyede Boşluk sayfa
  sayfa ilerler).
  Satır sonu, sekme, kontrol, çift yönlü ve sıfır genişlikli karakterler `\n`, `\u{202E}` gibi
  görünür hale getirilir. MCP argümanları kartta; Write/Edit içeriği tüm metin görünümünde
  (yol kısa olsa da İzin ver içerik sonuna kadar okunana kadar kapalıdır).
- Yeni kartın düğmeleri (Reddet dahil) ~0,8 sn, bir kart kalkınca diğerleri sistemin çift
  tıklama süresi + 0,1 sn (en az 0,45 sn; varsayılan 0,5 sn ile 0,6 sn), sayfalayıcıyla kart
  değişince ~0,8 sn devre dışıdır: bir çift tıklamanın ikinci tıklaması yerine kayan karta
  inmez. "Her zaman" ⋯ açıldıktan ~0,8 sn sonra etkinleşir.
- Oturumun claude süreci çıkınca (kill -9, sekme kapandı; süreç henüz toplanmamış bir zombi
  olsa bile) satır ve kartları hemen kalkar; 10 sn'lik yoklama yedek olarak çalışır.
  Peek durağan imlecin altında açılırsa imleç hareket edene
  kadar tıklamaları arkadaki pencereye geçirir.
- Çentiksiz ekranda ve gösterecek bir şey yokken panel görünmezdir ve fareyi yakalamaz.
- "Oturum açılışında başlat" ad-hoc imzalı uygulamalarda hata verebilir; uygulamayı
  `/Applications` altına taşıyın.

## Hata ayıklama

`/debug/*` uçları kartları onaylayabildiği için **varsayılan olarak kapalıdır** (404). Yalnızca
`CLAUDE_NOTCH_DEBUG=1` ile başlatılan uygulamada açılır (soket yine yalnızca sizin kullanıcınıza
açıktır):

```sh
open -n --env CLAUDE_NOTCH_DEBUG=1 build.noindex/ClaudeNotch.app
SOCK=~/Library/Application\ Support/ClaudeNotch/notch.sock
curl -s --unix-socket "$SOCK" http://localhost/debug/state | jq
curl -s --unix-socket "$SOCK" -d '{"id":"<kart id>","decision":"allow"}' http://localhost/debug/decide
# decision: allow | always | deny (isteğe bağlı "message")
scripts/shot.sh out.png                        # panelin PNG görüntüsü
```

Debug modda `POST /debug/ui` (`{"mode":"expanded","freeze":true}`, `active_display`,
`select_card`, `more_card`, `density`, `display_mode`, `pin`) ve `POST /debug/key`
(`{"hotkey":true}`, `{"key":"right"}`; paneli anahtar pencere yapmadan klavye kipi için
`{"key_mode":true}`; `"phase":"down"|"up"` ve `"repeat":true` tuş basılı tutmayı taklit eder)
görsel testler içindir. `POST /debug/key {"global": "allow"|"deny"|"panel", "phase":
"down"|"up"|"press"}` global kısayolu Carbon olayıyla aynı yoldan taklit eder (`down` ile
`up` arası basılı tutmaktır). `POST /debug/ui` ayrıca `{"shortcut_hint": true}` (ilk kullanım
satırını geri getirir), `{"peek_duration": "8"|"15"|"30"|"answered"}`, `{"set_shortcut":
{"role": "allow", "keys": [tuş kodu, Carbon değiştiricileri]}}`, `{"reset_shortcuts": true}`,
`{"open_settings": true}` / `{"close_settings": true}` alır. `POST /debug/discover` hemen bir
süreç taraması yapar ve oturumları döndürür. `POST /debug/focus` (`{"session_id": "…", "dry_run": true}`) odaklama betiğini ve
Otomasyon durumunu döndürür; `dry_run` olmadan gerçekten odaklar.

Uçtan uca testler: `python3 -I Tests/e2e/drive.py <allow|deny|terminal|stop|esc|no|noapp|identity>
<settings.json> <çalışma dizini> <test dizini>` (`noapp` için uygulama kapalı olmalı; diğerleri için
debug modda açık olmalı). Test için `scripts/install-hooks.sh --settings <dosya>` ile ayrı bir
ayar dosyası üretin.
